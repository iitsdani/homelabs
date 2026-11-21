# Proxmox QDevice

The `nl-pve` cluster uses an external Corosync QDevice to maintain quorum when
one Proxmox node is unavailable.

| Host | Address | Role |
| --- | --- | --- |
| `nl-pve-01` | `10.0.2.1` | Proxmox node, one vote |
| `nl-pve-02` | `10.0.2.2` | Proxmox node, one vote |
| `nl-k8s-04` | `10.0.1.4` | QNetd arbitrator, one vote |

Quorum requires two of three votes. Either Proxmox node can retain quorum with
QNetd available. If QNetd is unavailable, both Proxmox nodes must remain online.
QNetd grants its vote to only one partition during a network split.

## QNetd configuration

`machines/nl-k8s-04/pve-qdevice.nix`, imported by the node's `default.nix`,
configures QNetd:

- Installs `corosync-qdevice` and NSS tools.
- Runs `corosync-qnetd` as the unprivileged `coroqnetd` user.
- Initializes the certificate database under `/etc/corosync/qnetd/nssdb` if absent.
- Listens on `10.0.1.4:5403` and opens TCP port 5403 in the NixOS firewall.
- Enables the service at boot.

Deploy NixOS changes with:

```sh
nix run github:nix-community/colmena -- apply --on nl-k8s-04
```

The QNetd certificate database is persistent state. Preserve it when rebuilding
`nl-k8s-04`; regenerating it changes the CA and requires reconfiguring the
Proxmox QDevice clients.

## Initial cluster setup

Both Proxmox nodes must be online and quorate. Confirm both can reach
`10.0.1.4:5403`, then install the client package on each:

```sh
apt-get install corosync-qdevice
```

From `nl-pve-01`, configure the arbitrator:

```sh
pvecm qdevice setup 10.0.1.4
```

The setup command uses SSH as root to initialize and sign certificates on
`nl-k8s-04`. Verify its SSH host-key fingerprint and provide temporary access
for the Proxmox root public key. Remove temporary authorization after setup.
Both `corosync-qnetd-certutil` and NSS `certutil` must be available in the remote
root user's PATH; the NixOS configuration provides them.

The command initializes client certificates on both Proxmox nodes, signs the
cluster certificate, updates cluster configuration, and enables and starts the
clients. If NixOS already initialized the QNetd database, the command reports that
the database already exists and continues with the existing CA.

## Verification

On either Proxmox node:

```sh
pvecm status
corosync-qdevice-tool -s
```

Expected: `Quorate: Yes`, three expected votes, quorum of two, one QDevice vote,
and QDevice state `Connected`. With both nodes online, total votes should be
three. `A,V,NMW` indicates QDevice is alive and voting.

On `nl-k8s-04`:

```sh
systemctl status corosync-qnetd
corosync-qnetd-tool -s
```

Expected: service active, two connected clients, and one connected cluster.
Failover by shutting down a Proxmox node has not yet been tested.

## Troubleshooting

- Check `systemctl status corosync-qnetd` and `journalctl -u corosync-qnetd` on
  `nl-k8s-04`, and `systemctl status corosync-qdevice` on each Proxmox node.
- Verify TCP port 5403 is reachable from both Proxmox nodes and that
  `nl-k8s-04` has address `10.0.1.4`.
- Do not force quorum on both sides of a network partition.

See the [Proxmox QDevice documentation](https://pve.proxmox.com/pve-docs/pvecm.1.html#_corosync_external_vote_support)
for setup, status flags, and node membership changes.
