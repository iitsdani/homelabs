# Cilium CNI Migration with BGP Control Plane and Gateway API

## Context and Problem Statement

The `nl` cluster runs k3s-default **Flannel** (VXLAN backend) with **kube-proxy** (iptables-nft) and **MetalLB** (FRR mode) for LoadBalancer advertisement. This stack has proven fragile in the operational history of this cluster:

- **INC-0001** (Nov 13, 2025): Flannel VXLAN failure after k3s upgrade — `flannel.1` interface failed to initialize, breaking all cross-node pod traffic.
- **INC-0008** (Apr 19, 2026): Flannel startup deadlock with Longhorn admission webhooks — all four nodes rebooted simultaneously, Flannel never started because the Longhorn webhook (with a cluster-scoped `v1.Node UPDATE` rule and `failurePolicy: Fail`) blocked k3s's own node bootstrap, creating a circular dependency.

These incidents reveal two structural problems:

1. **Flannel bootstrap is tightly coupled to k3s node lifecycle**. The CNI is gated on node patches that admission webhooks can block. A healthier CNI should not depend on the control plane's ability to patch its own node object.
2. **MetalLB FRR introduces operational complexity** (FRR speaker sidecars, BFD configuration drift, per-node router-id constraints, duplicate speaker processes) that is largely unnecessary when a single Cilium agent on each node can handle both CNI datapath and BGP advertisement.

Additionally, the cluster has **zero network policy enforcement** today (Flannel does not support `NetworkPolicy`). Cilium brings `CiliumNetworkPolicy` (CNP) support without sidecars, enabling future zero-trust segmentation.

### Key questions

- How do we replace Flannel without rebuilding the cluster or re-IPAM-ing the whole pod/service space destructively?
- How do we replace MetalLB BGP with Cilium's BGP Control Plane while keeping the same router peering (iBGP AS 64512 to RouterOS) and the same LoadBalancer IP pools?
- How do we replace kube-proxy with Cilium's eBPF service handling?
- How do we add observability (Hubble) without a new stack?
- How do we adopt Gateway API progressively without forcing every app to migrate from `Ingress`?

## Decision Drivers

- **Resilience**: CNI must survive cold-start even when admission webhooks are unhealthy.
- **Simplification**: single component (Cilium agent) replaces Flannel + kube-proxy + MetalLB speakers.
- **Observability**: Hubble provides per-flow visibility that does not exist today.
- **Policy readiness**: unlock `CiliumNetworkPolicy` for future zero-trust without another migration.
- **Future-proofing**: Gateway API as a parallel path to `Ingress`, non-blocking adoption.
- **Reversibility**: every phase must be individually rollback-able via `colmena apply`.

## Considered Options

1. **Keep status quo** — Flannel + MetalLB + kube-proxy. Rejected: no policy enforcement, no observability, flannel bootstrap remains fragile.
2. **Cilium CNI only** — keep MetalLB and kube-proxy, just swap the CNI. Rejected: leaves the MetalLB operational overhead and kube-proxy iptables churn.
3. **Full Cilium stack** — CNI + kube-proxy replacement + BGP Control Plane + Hubble + Gateway API parallel. ✅ Chosen.
4. **Calico** — alternative CNI with BGP support. Rejected: less integrated eBPF story, no unified BGP + LB-IPAM CRDs to match the MetalLB shape, smaller homelab community.

## Decision Outcome

Chosen option: **Full Cilium stack (Option 3)**. The migration is split into six phases, each reversible.

### Architecture summary

| Layer | Before | After |
|-------|--------|-------|
| CNI | Flannel (VXLAN) | Cilium (VXLAN initially) |
| Service datapath | kube-proxy (iptables-nft) | Cilium eBPF (`kubeProxyReplacement: true`) |
| LB advertisement | MetalLB FRR (8 iBGP sessions) | Cilium BGP Control Plane (8 iBGP sessions) |
| LB IPAM | MetalLB `IPAddressPool` | Cilium `CiliumLoadBalancerIPPool` |
| Observability | None | Hubble Relay + UI (Tailscale ingress) |
| Ingress | ingress-nginx only | ingress-nginx + Cilium Gateway API (hybrid) |
| Network policy | None | CiliumNetworkPolicy (available, opt-in) |
| Pod encryption | None | None (deferred) |

### Constants

- **Cilium version**: 1.19.3
- **Helm chart**: `https://helm.cilium.io/`
- **kube-proxy replacement**: `kubeProxyReplacement: true`
- **IPAM**: `ipam.mode: kubernetes` (honours k3s-allocated per-node PodCIDRs)
- **Routing mode**: `tunnel` (VXLAN) for the initial cutover, matching current Flannel overlay semantics. Native routing (BGP-advertised pod CIDRs) is a future follow-up.
- **BGP**: iBGP AS 64512 on both cluster and router sides. Peers with RouterOS at `10.0.0.1` (IPv4) and `fd00:cafe::1` (IPv6).
- **LoadBalancer pools**: same three ranges as MetalLB today:
  - IPv4: `10.0.3.0/24`
  - IPv6 ULA: `fd00:cafe::3:0/64` (music-assistant, internal)
  - IPv6 GUA: `2a02:a469:9060:3::/64` (public services)

### k3s flag changes

Current `modules/k3s/server.nix` flags (pre-migration):

```nix
[
  "--disable=traefik"
  "--disable=servicelb"
  "--cluster-cidr=10.42.0.0/16,fd00:cafe:42::/48"
  "--service-cidr=10.43.0.0/16,fd00:cafe:43::/112"
  "--flannel-ipv6-masq"
]
```

Post-migration flags:

```nix
[
  "--disable=traefik"
  "--disable=servicelb"
  "--flannel-backend=none"
  "--disable-network-policy"
  "--disable-kube-proxy"
  "--cluster-cidr=10.42.0.0/16,fd00:cafe:42::/48"
  "--service-cidr=10.43.0.0/16,fd00:cafe:43::/112"
]
```

Removed: `--flannel-ipv6-masq` (no flannel). Cilium handles IPv6 masquerade via `bpf.masquerade`.

### BGP design — cluster-wide, no node selectors

All four nodes participate. `CiliumBGPClusterConfig` omits `nodeSelector` entirely → every node gets the BGP instance. This mirrors the current MetalLB design (two cluster-wide `BGPPeer` resources, no `nodeSelectors`).

### Naming conventions

Generic, no `nl-` prefix (cluster identity is implicit):
- `CiliumBGPClusterConfig` → `bgp-cluster-config`
- `CiliumBGPPeerConfig` → `router-v4-peer`, `router-v6-peer`
- `CiliumBGPAdvertisement` → `lb-services-v4`, `lb-services-v6`
- `CiliumLoadBalancerIPPool` → `lb-pool`

### Gateway API — hybrid, parallel

Cilium Gateway API is **enabled** but not made the cluster default. Existing `Ingress` resources continue to use `ingress-nginx`. New applications may opt in to `HTTPRoute` on the `cilium` `GatewayClass`. `external-dns` sources are extended to include `gateway-httproute` so Gateway-based apps receive DNS records.

ArgoCD's own ingress (`ingressClassName: tailscale`) remains on `Ingress` because Tailscale operator does not support Gateway API today.

### Out of scope (deferred to future ADRs)

- **Pod-to-pod encryption** (WireGuard or IPsec) — ADR-006 candidate.
- **Cilium mTLS / SPIFFE** (beta) — ADR-007 candidate when GA.
- **Gateway API migration of existing apps** — ADR-005 candidate.
- **CiliumNetworkPolicy adoption** — ADR-008 candidate; no policies in this change.
- **Cilium native routing** (replacing VXLAN tunnel with BGP-advertised pod CIDRs) — follow-up once BGP is proven stable.

## Implementation Plan

### Phase 0 — Pre-flight safety

1. **Snapshot etcd** via `k3s etcd-snapshot save` on `nl-k8s-01`.
2. **Snapshot current MetalLB state** to a local backup file:
   ```bash
   kubectl get bgppeers,ipaddresspools,bgpadvertisements,bfdprofiles -n metallb-system -o yaml > /tmp/metallb-pre-cilium.yaml
   ```
3. **Pre-fetch Cilium Helm chart hash** via `nix-prefetch-url --unpack` for exact version 1.19.3 and compute the SRI hash for `services.k3s.autoDeployCharts.cilium`.
4. **Verify `ipam.mode: kubernetes` compatibility**: `kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}'` must return four non-empty CIDRs (one per node). If any node lacks a `podCIDR`, the k3s controller-manager has not allocated one — debug before proceeding.
5. **Patch Longhorn webhook to `failurePolicy: Ignore`** as a safety net for the CNI cutover (closes the open action item from INC-0008). See [INC-0008 remediation commands](../postmortems/INC-0008-flannel-startup-deadlock-longhorn-webhook-after-k3s-1.35-upgrade.md).

### Phase 1 — ADR-004 + Cilium chart drop in Nix (no deploy yet)

New/modified files (build-only, no `colmena apply`):

1. **`docs/adrs/ADR-004-cilium-cni-migration.md`** (this file).
2. **`modules/k3s/cilium.nix`** (new): defines `services.k3s.autoDeployCharts.cilium` with:
   - `kubeProxyReplacement: true`
   - `k8sServiceHost`: node IP of `nl-k8s-01` (current cluster init)
   - `k8sServicePort: 6443`
   - `ipam.mode: "kubernetes"`
   - `routingMode: "tunnel"` (VXLAN)
   - `ipv4.enabled: true`, `ipv6.enabled: true`
   - `enableIPv4Masquerade: true`, `enableIPv6Masquerade: true`
   - `bpf.masquerade: true`
   - `bgpControlPlane.enabled: true`
   - `operator.replicas: 2`
   - `hubble.enabled: true`, `relay.enabled: true`, `ui.enabled: true`, `ui.ingress` via Tailscale className
   - `gatewayAPI.enabled: true`
   - Prometheus metrics enabled (for future VictoriaMetrics scraping)
3. **`modules/k3s/server-main.nix`**: import `modules/k3s/cilium.nix`.
4. **`modules/k3s/server.nix`**: add k3s flags (`--flannel-backend=none`, `--disable-network-policy`, `--disable-kube-proxy`) and remove `--flannel-ipv6-masq`.
5. **`modules/k3s/agent.nix`**: add `--node-label=bgp-policy=nl` is **not needed** (no node selector). No changes required.
6. **Open Cilium control-plane ports in NixOS firewall** (`modules/k3s/k3s.nix` `networking.firewall.allowedTCPPorts`). Required for inter-node Cilium control traffic — without these, host-to-host TCP to Cilium ports is silently dropped by `nixos-fw-log-refuse`, breaking Hubble Relay, cilium-health probes, and any pod whose ClusterIP resolves to a remote node's host port.

   Required TCP ports:
   - `4240` — cilium-health (cluster health checker, also requires `networking.firewall.allowPing = true` for ICMP probes)
   - `4244` — Hubble peer service (consumed by hubble-relay across nodes)
   - `4245` — Hubble relay (gRPC API for `hubble` CLI / Hubble UI)
   - `9962` — cilium-agent Prometheus exporter (optional, only if scraped externally)
   - `9963` — cilium-operator Prometheus exporter (optional)
   - `9964` — cilium-envoy Prometheus exporter (optional)

   Port `179` (BGP) is already open for MetalLB and reused by Cilium BGP — no change needed there.

   The `8472/udp` flannel port should remain in `allowedUDPPorts` until Phase 6 cleanup.
7. **Force Cilium pod MTU to 1500** via the `MTU` Helm value (note: uppercase, lowercase `mtu` is silently ignored by the chart).

   Cilium's MTU auto-detection picks the smallest MTU among devices it considers, including `tailscale0` (1280) on hosts running tailscaled. Pod traffic does NOT traverse `tailscale0` — pods route via cilium_host → host LAN NIC (1500) → other node — but Cilium auto-MTU still factors `tailscale0` in and clamps pod eth0 / cilium_host to 1280.

   The downstream effect is brutal: any pod that re-encapsulates traffic (notably the **Tailscale operator-managed Ingress proxy pods**, which run userspace WireGuard via netstack and add ~140 bytes of overhead) ends up with an effective application MTU of ~1140. Backend pods sending normal 1240-byte TCP segments produce packets that silently get dropped by the proxy pod's userspace WG. TCP retransmits. Throughput collapses to ~18 KB/s for any non-trivial response (Grafana dashboards, Longhorn UI, Hubble UI streams, Home Assistant, etc.).

   `MTU = 1500` in `cilium.nix` is the fix. Pod-to-pod traffic uses 1500-byte packets natively on LAN. Tailscale proxies regain ~1360 bytes effective MSS and run at LAN-native speeds (>1 MB/s observed).

   Ref: [tailscale#18565](https://github.com/tailscale/tailscale/issues/18565).
8. **Enable BPF datapath fragment tracking + PMTU discovery** (`fragmentTracking = true`, `pmtuDiscovery.enabled = true`). Defends the datapath when fragmentation does occur (e.g., a transient PMTU mismatch on a Tailscale path) so packets aren't dropped silently. Without these, you'll see large `Fragmented packet` drop counts in `cilium-dbg bpf metrics list`.
9. `nix flake check` must pass.

### Phase 2 — CNI cutover (~30 min window)

**Destructive moment: flannel → Cilium.** All pods get new IPs from Cilium IPAM.

1. `colmena apply switch --on nl-k8s-01` first (init node carries the HelmChart bootstrap manifest).
2. K3s starts with no CNI. The `HelmChart-cilium` manifest is applied by k3s helm-controller. Cilium operator and agents (hostNetwork) start. Agent writes `/etc/cni/net.d/05-cilium.conflist`. eBPF programs load. Pod networking resumes.
3. `colmena apply switch --on nl-k8s-02 nl-k8s-03 nl-k8s-04` in sequence.
4. Validate:
   - `kubectl get nodes` → all Ready
   - `kubectl get pods -A -o wide` → all Running
   - `cilium status --wait` → green (from any node)
   - `cilium status | grep -i "kube-proxy"` → "Disabled (using kube-proxy replacement)"
5. Smoke test: `kubectl exec` into a CoreDNS pod and `nslookup kubernetes.default`.

**Rollback if validation fails**: `git revert` the k3s flag changes, `colmena apply switch`, manually `helm uninstall cilium -n kube-system`, clear CNI conflists, reboot nodes to flush eBPF.

### Phase 3 — BGP cutover (~30 min window)

**MetalLB BGP → Cilium BGP.** Same iBGP AS 64512, same router peer IPs. RouterOS side (`networking/router/bgp.tf`) requires **no changes** because peer addresses and AS match.

1. Create `kube/cilium-bgp/` tree with:
   - `bgp-cluster-config.yaml` — `CiliumBGPClusterConfig`, cluster-wide, no `nodeSelector`
   - `bgp-peer-config-v4.yaml`, `bgp-peer-config-v6.yaml` — `CiliumBGPPeerConfig` for v4 and v6
   - `bgp-advertisement.yaml` — `CiliumBGPAdvertisement` targeting `lb-pool`
   - `lb-pool.yaml` — `CiliumLoadBalancerIPPool` with the three ranges
   - `kustomization.yaml` — references above resources
2. Add `kube/cilium-bgp/` to the top-level `kube/` or reference it via ArgoCD. Since the CNI is now Cilium, ArgoCD can reconcile normally.
3. Apply the Cilium BGP CRs.
4. Verify Cilium BGP sessions: `cilium bgp peers` → 8 Established.
5. Verify RouterOS sessions: SSH to router, `/routing bgp session print` → 8 Established.
6. **Scale MetalLB to zero**: `kubectl scale deployment -n metallb-system metallb-controller --replicas=0`, `kubectl scale daemonset -n metallb-system metallb-speaker --replicas=0`.
7. Validate public reachability (ingress-nginx, slskd, qbittorrent) via IPv4 + IPv6 GUA.
8. **Delete MetalLB resources** via ArgoCD (remove `kube/metallb-system/` tree from repo, push, let ArgoCD reconcile the uninstall).
9. **Remove `metallb-system` namespace**: `kubectl delete ns metallb-system`.

**Rollback if validation fails**: scale MetalLB back to 1, delete Cilium BGP CRs, or revert the directory deletion commit.

### Phase 4 — Hubble validation

1. Verify Hubble Relay pods: `kubectl -n kube-system get pods -l k8s-app=hubble-relay`.
2. Verify Hubble UI Tailscale ingress: `https://nl-hubble.<tailnet>.ts.net` loads.
3. Browse flows in the UI to confirm visibility.

### Phase 5 — Gateway API (parallel)

1. **Pre-install Gateway API CRDs**: upstream `standard-install.yaml` from `kubernetes-sigs/gateway-api`. Added as a k3s manifest or HelmChart bootstrap (via `services.k3s.manifests` or `autoDeployCharts`).
2. **Cilium GatewayClass**: `cilium` class created automatically by Cilium when `gatewayAPI.enabled: true`.
3. **External-DNS**: add `gateway-httproute` to sources in `kube/networking/external-dns/values-cloudflare.yaml`. No other changes.
4. **No app migration in this ADR.** New apps may use Gateway API; existing stay on `Ingress`.

### Phase 6 — Cleanup

1. **Remove Flannel firewall port** (`8472`) from `modules/k3s/k3s.nix`.
2. **Delete `kube/metallb-system/`** directory entirely.
3. **Update AGENTS.md** and `docs/` cross-references to mark Flannel/MetalLB superseded.
4. **Close Longhorn webhook action item** (if not already done in Phase 0).
5. **Add follow-up tasks** to ADR-004 out-of-scope list for tracking.

## Risks and Mitigations

| Risk | Likelihood | Mitigation |
|---|---|---|
| Cilium fails to come up, cluster has no CNI | Medium | Keep SSH + `kubectl` on `nl-k8s-01` ready. Rollback = revert k3s flags + `colmena apply` + `helm uninstall cilium`. |
| Cilium BGP doesn't establish | Medium | No BFD by default. Verify `cilium bgp peers` immediately after CR apply. RouterOS peers unchanged. |
| Longhorn webhook deadlock during CNI cutover | Medium (if not patched) | Patch Longhorn `failurePolicy: Ignore` in Phase 0. If skipped, risk is identical to INC-0008 — same recovery command applies. |
| kube-proxy replacement misconfig → no service routing | Medium | Verify `cilium status` and `netshoot` probe on nl-k8s-01 **before** rolling to other nodes. |
| MetalLB + Cilium both advertising same IPs (transient) | Low | iBGP same AS → router sees ECMP or picks one. MetalLB scaled to zero in Phase 3 before this becomes a real conflict. |
| Hubble TLS auto-gen fails | Low | Use `hubble.tls.auto.method: helm`. If that fails, `cronJob` is fallback. UI is non-critical. |
| podCIDR mismatch between k3s and Cilium | Low | `ipam.mode: kubernetes` reads `Node.spec.podCIDR` directly. Verify allocation in Phase 0 step 4. |
| Tailscale operator interaction with Cilium LB | Low | Tailscale LB class (`tailscale`) is independent. Cilium pool only covers `LoadBalancerIP` Services. |
| ArgoCD tries to recreate MetalLB after deletion | Low | Commit deletion, push, ArgoCD reconciles to MissingResource → Healthy. Manual namespace delete if needed. |
| Longhorn volumes don't reattach after CNI swap | Low | Longhorn uses Service DNS, not pod IPs. Should reattach automatically. Verify before uncordoning. |
| NixOS firewall blocks Cilium control ports → silent failures (Hubble Relay crashloops, cluster health degraded, ClusterIP-to-host-port hangs) | High if missed | Open `4240`, `4244`, `4245` (and optionally `9962-9964`) in `networking.firewall.allowedTCPPorts`, plus `networking.firewall.allowPing = true`. Symptoms are subtle: pod-to-pod cross-node traffic works (uses cilium_host direct routes), but pod-to-ClusterIP that backends to a remote host's port silently times out — looks like Cilium policy/datapath issue. See Phase 1 step 6. |
| Cilium auto-MTU detects `tailscale0` (1280) and clamps pod eth0 / cilium_host to 1280, collapsing throughput through Tailscale-operator-managed Ingress proxy pods to ~18 KB/s (Grafana / Longhorn / Hubble UI / Home Assistant unusable) | High if missed | Set `MTU = 1500` (uppercase!) in cilium Helm values. The chart silently ignores lowercase `mtu`. See Phase 1 step 7. Existing pods need to restart to pick up the new MTU; rolling restart of the cilium DaemonSet plus the Tailscale operator StatefulSets is enough. Ref: [tailscale#18565](https://github.com/tailscale/tailscale/issues/18565). |
| Helm values use schema-incorrect key names (e.g. `mtu` vs `MTU`, `enableIPv4FragmentsTracking` vs `fragmentTracking`) | Medium | The Cilium chart silently ignores unknown top-level keys. Always cross-check against `helm show values cilium/cilium --version <version>` before committing. Symptoms are "config didn't apply" with no error. |

## Rollback Plan

### Phase 2 (CNI cutover) rollback

1. `git revert` k3s flag + `cilium.nix` changes.
2. `colmena apply switch --on <node>` — k3s default flannel returns.
3. `helm uninstall cilium -n kube-system`.
4. Delete `/etc/cni/net.d/05-cilium.conflist` on each node.
5. Reboot to clear eBPF programs.
6. Validate flannel: `/run/flannel/subnet.env`, `flannel.1` interface.

### Phase 3 (BGP cutover) rollback

1. Re-enable MetalLB: scale controller and speaker to `replicas=1`.
2. Delete Cilium BGP CRs (`bgp-cluster-config`, peer configs, advertisement, pool).
3. Commit restoration of `kube/metallb-system/` directory.

### Full rollback to pre-ADR-004

Revert all ADR-004 commits, `colmena apply switch`, validate cluster returns to Flannel + MetalLB + kube-proxy.

## Confirmation

### Phase 2 validation

- `kubectl get nodes` → all Ready
- `kubectl get pods -A -o wide` → all Running
- `cilium status --wait` → green
- `cilium status` shows "kube-proxy: Disabled (using kube-proxy replacement)"
- CoreDNS pod can resolve `kubernetes.default`

### Phase 3 validation

- `cilium bgp peers` → 8 sessions Established
- RouterOS `/routing bgp session print` → 8 sessions Established
- Public reachability for ingress-nginx (IPv4 + IPv6 GUA)
- Public reachability for slskd (IPv4 + IPv6 GUA)
- Public reachability for qbittorrent (IPv4 + IPv6 GUA)
- LAN reachability for music-assistant (IPv4 + IPv6 ULA)

### Phase 4 validation

- `kubectl -n kube-system get pods -l k8s-app=hubble-relay,k8s-app=hubble-ui` → Running
- `nl-hubble` Tailscale ingress loads and shows flows

### Phase 5 validation

- `kubectl get gatewayclass` → `cilium` present and Accepted

### Success criteria

- All ArgoCD apps reconcile to Healthy
- No `flannel`, no `metallb-controller/speaker`, no `kube-proxy` DaemonSet running
- Public services reachable over IPv4 and IPv6 GUA
- Music-assistant reachable over ULA
- Hubble UI accessible over Tailscale

## Pros and Cons of the Options

### Option 1: Keep status quo (Flannel + MetalLB + kube-proxy)

- Good, because zero migration cost.
- Bad, because flannel startup remains fragile (INC-0001, INC-0008).
- Bad, because MetalLB FRR introduces FRR sidecars and BFD/router-id complexity.
- Bad, because no network policy enforcement at all.
- Bad, because no pod flow observability.

### Option 2: Cilium CNI only (keep MetalLB + kube-proxy)

- Good, because fixes the flannel fragility.
- Good, because enables CNPs.
- Bad, because leaves MetalLB and kube-proxy as separate components to maintain.
- Bad, because does not simplify the stack meaningfully.

### Option 3: Full Cilium stack ✅ Chosen

- Good, because single agent replaces three components (Flannel, kube-proxy, MetalLB speakers).
- Good, because eBPF service datapath outperforms iptables at scale.
- Good, because BGP Control Plane is native to the agent, no FRR sidecars.
- Good, because Hubble gives per-flow visibility without a new stack.
- Good, because Gateway API is available for future apps without forcing migration.
- Good, because CiliumNetworkPolicy unlocks zero-trust segmentation.
- Neutral, because adds Helm complexity and eBPF kernel requirements (k3s already on 7.0.0, Cilium 1.19.3 supports it).
- Bad, because CNI swap means all pods restart and get new IPs (non-destructive to data, but requires validation).
- Bad, because 30-minute public service downtime window during BGP cutover.
- Bad, because Gateway API + Cilium Ingress are beta/experimental in some paths.

### Option 4: Calico

- Good, because proven BGP support.
- Bad, because no unified BGP + LB-IPAM CRDs (Calico advertises pod CIDRs, not service IPs).
- Bad, because no eBPF service datapath (iptables-based).
- Bad, because no Hubble equivalent.
- Bad, because smaller homelab community → fewer runbooks/examples.

## Additional Links

- [Cilium BGP Control Plane docs](https://docs.cilium.io/en/stable/network/bgp-control-plane/)
- [Cilium Gateway API docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/)
- [Cilium Helm values reference](https://docs.cilium.io/en/stable/helm-reference/)
- [ADR-001 Network Architecture](./ADR-001-network-architecture.md)
- [ADR-002 DHCP/DNS Strategy](./ADR-002-dhcp-dns-configuration-strategy.md)
- [ADR-003 Static IP + mDNS](./ADR-003-static-ip-mdns-resolution.md)
- [INC-0001 Flannel VXLAN Failure](../postmortems/INC-0001-flannel-vxlan-failure-after-k3s-upgrade.md)
- [INC-0008 Flannel-Longhorn Deadlock](../postmortems/INC-0008-flannel-startup-deadlock-longhorn-webhook-after-k3s-1.35-upgrade.md)
- [Cilium 1.19.3 release notes](https://github.com/cilium/cilium/releases/tag/v1.19.3)
