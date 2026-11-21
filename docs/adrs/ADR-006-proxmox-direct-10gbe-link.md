# Direct 10GbE Link Between Proxmox Nodes

## Context and Problem Statement

The `nl-pve` cluster consists of two Proxmox VE nodes:

| Host          | Address    | Notes                                                                                 |
| ------------- | ---------- | ------------------------------------------------------------------------------------- |
| `nl-pve-01`   | `10.0.2.1` | Houses `nl-k8s-02`, `ap-01`, `powermaster`                                            |
| `home-pve-02` | `10.0.2.2` | Renamed from `nl-pve-02`; no guests                                                   |
| `nl-k8s-04`   | `10.0.1.4` | External Corosync QDevice (see the [QDevice runbook](../runbooks/proxmox-qdevice.md)) |

All host-to-host traffic — Proxmox cluster communication, migration, and management — currently traverses the shared LAN. `nl-pve-01` connects at **2.5 Gb/s** and `home-pve-02` at **1 Gb/s** over twisted pair. Hostnames follow the internal naming decision in [ADR-003](./ADR-003-static-ip-mdns-resolution.md).

Several hosts already have 10GbE-capable ports: `nl-pve-01` has an Intel X710 dual-port SFP+ adapter, `home-pve-02` received a Mellanox ConnectX-3, and the TrueNAS host has 10GbE as well. There is **no SFP+ switch** yet, so those ports cannot form a shared 10G fabric across the rack. Until one arrives, the only 10G path available is a direct cable between exactly two hosts — and of the possible pairs, `nl-pve-01` ↔ `home-pve-02` is the one that carries Proxmox cluster traffic.

That shared LAN path is a poor fit for two workloads with opposing requirements:

1. **Live migration** is bandwidth-hungry and bursty. A 20 GiB guest migration can saturate a 1–2.5 Gb/s link for minutes, which is exactly when the cluster needs predictable latency.
2. **Corosync** needs very low, consistent latency but almost no bandwidth. Proxmox explicitly recommends keeping cluster communication away from high-traffic networks such as storage and live migration.

The hardware for a better path was therefore already available, if only point to point: a 1 m passive DAC (`SFP-H10GB-CU1M`) now links one X710 port directly to the Mellanox port, with no switch in between. The remaining 10G ports on both hosts, and the TrueNAS 10GbE ports, stay unused until the switch arrives.

### Key questions

- Should the direct link be a routed point-to-point subnet, or bridged into the existing LAN?
- Should Proxmox migration traffic use the direct link?
- Should Corosync use the direct link as the primary path, as a redundant fallback, or not at all?
- Should Kubernetes/Longhorn traffic use the direct link now, given that a shared 10G fabric is not possible until the SFP+ switch arrives?

## Decision Drivers

- **Keep failure domains separate.** A direct cable can fail or be unplugged; existing LAN connectivity must remain sufficient for the cluster to operate.
- **Protect Corosync latency** from migration-driven saturation.
- **Bounded blast radius.** Changes must be reversible with the cluster staying quorate, and must not require guest downtime.
- **No new addressing plan.** The link should not require RouterOS changes, DHCP, or DNS.
- **Room to grow.** The link should be usable later for Longhorn or guest traffic without re-cabling or re-addressing, and the addressing scheme should stay valid once an SFP+ switch turns the point-to-point link into part of a shared 10G fabric.

## Considered Options

1. **Bridged into `vmbr0`** — simplest for guests, but merges the 10G path into the LAN bridge. Requires care with STP/loop avoidance, shares the LAN L2 domain, and does not isolate migration traffic from management.
2. **Dedicated point-to-point `/30`, used for migration and as a Corosync fallback.** ✅ Chosen.
3. **Dedicated point-to-point `/30`, used for migration only.** Rejected: leaves the link idle whenever no migration runs, and forgoes a free second Corosync path.
4. **Dedicated point-to-point `/30`, used as Corosync primary.** Rejected: Corosync would then share the link with migration traffic, reintroducing the latency contention the change is meant to remove. It would also make cluster communication depend on a single unswitched cable.
5. **Route Kubernetes/Longhorn traffic over the link now.** Deferred: requires VM-facing bridges, guest addressing, and Longhorn/Cilium data-path changes, and a point-to-point cable only reaches these two hosts — not the bare-metal k3s nodes or TrueNAS. Worth revisiting as an interim measure for guests on these two hosts while the SFP+ switch is pending, but out of scope for this ADR.

## Decision Outcome

Chosen option: **Option 2** — a dedicated, unbridged point-to-point subnet that carries Proxmox migration traffic, with Corosync configured to use the existing LAN as its primary link and the direct link as an automatic fallback.

Scope is deliberately narrow: **migration and Corosync only**, for now. Longhorn and guest traffic wait for the SFP+ switch, because a point-to-point cable reaches only these two hosts and the storage fabric needs to span the Proxmox nodes, the bare-metal k3s nodes, and TrueNAS. The addressing chosen here is small, but it does not paint us into a corner: moving to a switch changes the prefix, the routing, and where the interfaces plug in, while the host-level interface model — one dedicated, unbridged 10G interface per host — carries over unchanged.

### Link configuration

| Item      | `nl-pve-01`           | `home-pve-02`                 |
| --------- | --------------------- | ----------------------------- |
| Adapter   | Intel X710 10GbE SFP+ | Mellanox ConnectX-3 (MT27500) |
| Interface | `enp2s0f1np1`         | `nic1`                        |
| Address   | `172.31.254.1/30`     | `172.31.254.2/30`             |
| MTU       | 1500                  | 1500                          |
| Gateway   | none                  | none                          |
| Cable     | 1 m passive DAC       | 1 m passive DAC               |

The `/30` yields exactly two usable addresses — one per node — which is also what Proxmox requires for its migration network setting: each node must have exactly one address inside the configured CIDR.

Configuration lives in the node-local `/etc/network/interfaces` on each host, applied with `ifup`/`ifreload`. It is not part of `vmbr0`, so it cannot leak into the LAN L2 domain and cannot be reached by guests. No RouterOS or DNS changes were needed.

### Proxmox migration network

The datacenter option is set cluster-wide:

```text
migration: type=secure, network=172.31.254.0/30
```

Migration transport remains `secure` (SSH tunnel). The bandwidth gain is on the network path; the encryption overhead remains, which is intentional for a link that terminates on hosts with root-equivalent access.

### Corosync redundancy

`corosync.conf` now declares two links, with `config_version` bumped:

```text
nodelist {
  node {
    name: nl-pve-01
    nodeid: 1
    quorum_votes: 1
    ring0_addr: 10.0.2.1
    ring1_addr: 172.31.254.1
  }
  node {
    name: home-pve-02
    nodeid: 2
    quorum_votes: 1
    ring0_addr: 10.0.2.2
    ring1_addr: 172.31.254.2
  }
}

totem {
  interface {
    linknumber: 0
  }
  interface {
    linknumber: 1
  }
}
```

No `knet_link_priority` is set, so links are used in numeric order: `link0` (LAN) is primary and `link1` (direct cable) is fallback. knet confirms this by reporting `best link: 0`.

The QDevice remains on `10.0.1.4` and is still reached over the LAN. Redundant Corosync links protect against failure of one node-to-node path, not against loss of both hosts’ LAN access or loss of the QDevice.

## Verification

Baseline performed immediately after configuring the link:

| Check                                            | Result                                             |
| ------------------------------------------------ | -------------------------------------------------- |
| `ethtool` speed/link, both ends                  | 10,000 Mb/s, link detected                         |
| `ping` across `172.31.254.0/30`, both directions | 0% loss, ~0.1–0.3 ms                               |
| `iperf3 -P 4`, `nl-pve-01` → `home-pve-02`       | 9.39 Gbit/s                                        |
| `iperf3 -P 4`, `home-pve-02` → `nl-pve-01`       | 9.43 Gbit/s                                        |
| `corosync-cfgtool -s`                            | `link0` and `link1` connected on both nodes        |
| `pvecm status`                                   | quorate, 3 expected votes, 3 total, QDevice active |

Commands to re-check after any change:

```sh
ip -brief address show enp2s0f1np1   # on nl-pve-01
ip -brief address show nic1          # on home-pve-02
ethtool enp2s0f1np1 | grep -E 'Speed|Link detected'
corosync-cfgtool -s
pvecm status
pvesh get /cluster/options
```

## Consequences

### Positive

- Migration traffic no longer competes with cluster communication or management on the shared LAN.
- Migration between the two Proxmox hosts gains a path with measured ~9.4 Gbit/s throughput instead of the shared 1–2.5 Gb/s uplink.
- A single cable, NIC, or LAN-path failure no longer partitions Corosync, provided the other path survives.
- The link is unbridged, so no guest or LAN device can accidentally consume it.
- All changes are host-local and reversible; no guest downtime was required.

### Negative

- Corosync `link1` shares its medium with migration traffic whenever `link0` is down. Sustained migration saturation can raise Corosync latency precisely when the cluster is degraded. Migration bandwidth limits should be considered before relying on this fallback during heavy migrations.
- Two links and two addresses add configuration surface that must be reproduced on any future node rebuild.
- The direct link is a point-to-point single cable: no redundancy within that path itself.
- MTU stays at 1500, so jumbo-frame benefits are not realized.

### Neutral

- The QDevice remains LAN-dependent; this decision does not change quorum behaviour.
- Guest and Longhorn traffic are explicitly unaffected. `vmbr0` remains the only bridged network.
- `home-pve-02`’s interface names (`nic0`/`nic1`) differ from Proxmox defaults; the addressing is tied to those names.
- `nl-pve-01`’s `/etc/network/interfaces` contained stale `enp3s0*` stanzas referring to interfaces that no longer exist. These were corrected to `enp2s0*` while adding the new stanza.

## Follow-up Decisions

- **Test the fallback path** in a maintenance window: verify the cluster remains quorate with `link0` down, and that management access survives. This requires out-of-band access, since dropping the LAN link also affects the QDevice path and SSH.
- **Validate live migration** end-to-end once a guest that fits `home-pve-02`’s storage is available. Current guests are unsuitable: VM 101 is larger than the target thin pool, and VM 102 and CT 104 have passthrough devices.
- **Consider migration bandwidth limits** (`bwlimit.migration`) so a fallback-link migration cannot starve Corosync.
- **Decide on Longhorn/Kubernetes use** of the 10G path as a separate ADR: it requires a dedicated bridge and guest networking, plus a data-path decision in Longhorn v2 and Cilium. The intended end state is Longhorn replica traffic on a shared 10G fabric once the SFP+ switch connects `nl-pve-01`, `home-pve-02`, and TrueNAS; an interim variant limited to guests on these two hosts could be evaluated before then.
- **Revisit the addressing scheme when the SFP+ switch arrives.** `172.31.254.0/30` is sized for exactly two endpoints. Moving to a switched fabric with three or more 10G hosts needs a larger prefix, a router or bridge on that segment, and a decision on whether that fabric is routed or L2-extended to the LAN.
- **Decide on jumbo frames** only after confirming MTU agreement across all consumers of the link, and preferably after the switch defines the shared fabric.

## References

- [Proxmox VE cluster manager: adding redundant links](https://pve.proxmox.com/pve-docs/pvecm.1.html#_adding_redundant_links_to_an_existing_cluster)
- [Proxmox VE cluster manager: migration network](https://pve.proxmox.com/pve-docs/pvecm.1.html#pvecm_migration_network)
- [Proxmox VE cluster manager: editing `corosync.conf`](https://pve.proxmox.com/pve-docs/pvecm.1.html#pvecm_edit_corosync_conf)
- [Proxmox QDevice runbook](../runbooks/proxmox-qdevice.md)
