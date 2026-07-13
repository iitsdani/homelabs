# Envoy Gateway Migration

Status: Accepted

## Context and Problem Statement

The `home` cluster currently uses ingress-nginx for public HTTP ingress and Cilium for the cluster network, kube-proxy replacement, LoadBalancer IPAM, and BGP advertisement.

The Kubernetes project retired ingress-nginx in March 2026. The controller reached its final release and no longer receives releases, bug fixes, or security fixes. Existing installations continue to run, but keeping an Internet-facing retired controller creates increasing operational and security risk. The Kubernetes `Ingress` API itself remains stable but frozen; new service-networking capabilities are developed through Gateway API.

The first replacement attempt used Cilium Gateway API because Cilium was already installed and could provide a `GatewayClass` without another controller. A production migration was attempted and reverted after requests reached Cilium Envoy but all upstream backend connections returned HTTP 503. A smaller canary reproduced the same failure without changing production ingress.

The investigation tested Cilium 1.19.4 and 1.19.5 with:

- native routing and kube-proxy replacement;
- standalone and embedded Cilium Envoy;
- BPF and legacy host routing;
- local-node and remote-node Pod backends;
- Tailscale running and stopped;
- NixOS netfilter reverse-path exceptions and kernel `rp_filter` disabled;
- direct Gateway NodePort traffic, excluding RouterOS, BGP, and LoadBalancer IPAM.

In every case Envoy created an upstream socket from the reserved Cilium ingress endpoint, the backend returned SYN-ACK, and Envoy remained in `SYN-SENT` until its connection timeout. `pwru` showed the reply re-entering through `cilium_host` and `cilium_net`, following `ip_forward`, and ending with `SKB_DROP_REASON_IP_INHDR` instead of being delivered to the Envoy socket. This matches the failure class tracked by [Cilium issue #46798](https://github.com/cilium/cilium/issues/46798).

The problem is therefore not the Gateway or HTTPRoute manifests, application readiness, BGP, RouterOS, Tailscale, or the NixOS firewall. It is the Cilium Gateway transparent-proxy datapath on this cluster. Continuing to tune unrelated node networking would add risk without evidence of a viable fix.

Five public applications still depend on ingress-nginx:

| Application | Hostname            | Special requirements            |
| ----------- | ------------------- | ------------------------------- |
| Authelia    | `idp.cianfr.one`    | OIDC provider availability      |
| Immich      | `photos.cianfr.one` | Large uploads, long requests    |
| Jellyfin    | `media.cianfr.one`  | Streaming and WebSocket traffic |
| OpenCloud   | `drive.cianfr.one`  | Large uploads, long requests    |
| Vaultwarden | `vault.cianfr.one`  | WebSocket and OIDC flows        |

Ingresses managed by the Tailscale Kubernetes operator are independent and remain out of scope.

## Decision Drivers

- Replace the retired ingress-nginx controller before future unpatched vulnerabilities accumulate.
- Adopt the actively developed Gateway API instead of replacing ingress-nginx with another Ingress-only controller.
- Avoid Cilium Gateway's confirmed transparent-proxy failure path.
- Preserve Cilium as the CNI, kube-proxy replacement, LB-IPAM implementation, and BGP control plane.
- Preserve source addresses at the Envoy data plane where practical.
- Support TLS termination, redirects, long-running requests, large uploads, WebSockets, and OIDC callbacks.
- Permit a parallel migration with deterministic validation and fast rollback.
- Keep Gateway, routing, certificate, DNS, and proxy ownership explicit in Git.

## Considered Options

1. **Keep ingress-nginx** - rejected. The controller is retired and receives no security fixes.
2. **Use another Ingress controller** - rejected. This removes the immediate ingress-nginx risk but keeps the cluster on the frozen Ingress API and defers the Gateway API migration.
3. **Use Cilium Gateway API** - rejected. The controller integrates well with Cilium policy and networking, but its data path is non-functional on this cluster after extensive testing across supported configurations.
4. **Wait for a Cilium fix** - rejected as the migration strategy. ingress-nginx is already retired, and Cilium issue #46798 has no released fix or committed resolution date. The canary may be retained only as evidence until Cilium Gateway is disabled.
5. **Use Envoy Gateway** - chosen. Envoy Gateway is a dedicated Gateway API implementation whose Envoy data plane runs as ordinary Kubernetes workloads behind a LoadBalancer Service. This avoids the failing Cilium TPROXY path while retaining Cilium LB-IPAM and BGP.

## Decision Outcome

Chosen option: **Envoy Gateway**.

Envoy Gateway owns Gateway API reconciliation and the L7 data plane. Cilium no longer owns Gateway API resources, but continues to provide cluster networking and advertise the Envoy Gateway LoadBalancer Service.

### Responsibility split

| Concern                                     | Owner                                |
| ------------------------------------------- | ------------------------------------ |
| Pod networking                              | Cilium CNI                           |
| Kubernetes Service handling                 | Cilium kube-proxy replacement        |
| LoadBalancer address allocation             | Cilium LB-IPAM                       |
| LoadBalancer route advertisement            | Cilium BGP Control Plane             |
| Gateway API reconciliation                  | Envoy Gateway                        |
| HTTP/TLS proxying                           | Envoy Proxy managed by Envoy Gateway |
| Public certificates                         | cert-manager                         |
| Public DNS records                          | external-dns                         |
| Public IPv4 forwarding and IPv6 firewalling | RouterOS                             |

### Controller and API ownership

- Envoy Gateway is pinned to version `v1.8.2`.
- The shared public `GatewayClass` is named `envoy` and uses controller `gateway.envoyproxy.io/gatewayclass-controller`.
- The cluster keeps a single owner for upstream Gateway API CRDs. The existing k3s bootstrap manifest owns Gateway API v1.6.0 CRDs.
- Envoy Gateway-specific CRDs are installed separately from the controller chart. The controller chart must not replace or downgrade upstream Gateway API CRDs.
- Cilium `gatewayAPI.enabled` is disabled and the failed Cilium `external-gw` is deleted before the Envoy Gateway resource is created. This releases `10.0.3.10` and avoids competing controllers or resources with the same Gateway name.

### Data-plane architecture

```text
Internet
  -> RouterOS IPv4 forwarding / IPv6 firewall
  -> Cilium-advertised LoadBalancer VIP
  -> Envoy Gateway managed LoadBalancer Service
  -> Envoy Proxy replicas
  -> HTTPRoute backend Services
  -> application Pods
```

One shared public Gateway in namespace `networking` terminates TLS for `*.cianfr.one`. An explicit wildcard `Certificate` is preferred over controller-specific certificate automation. HTTP redirects to HTTPS through a dedicated HTTPRoute.

The Envoy data plane runs two replicas spread across nodes. Its Service uses `externalTrafficPolicy: Local`, allowing Cilium BGP to advertise the VIP only from nodes with ready Envoy endpoints and preserving the client source address delivered to Envoy.

Envoy Gateway uses `10.0.3.10`, released by deleting the failed Cilium Gateway canary. This remains parallel to ingress-nginx on `10.0.3.1`. Production ingress-nginx remains active until all Envoy routes pass functional testing and public routing is deliberately switched.

## Consequences

### Positive

- Removes the retired Internet-facing ingress-nginx controller.
- Uses Gateway API as the durable service-networking API.
- Avoids the confirmed Cilium Gateway transparent-proxy defect.
- Retains working Cilium CNI, LB-IPAM, and BGP components.
- Supports side-by-side validation without taking production ingress offline.
- Separates L3/L4 networking ownership from L7 proxy ownership, making failures easier to isolate.
- Envoy Gateway has explicit APIs for proxy deployment, Service behavior, graceful shutdown, and backend traffic policy.

### Negative

- Adds a dedicated controller and CRDs to the cluster.
- Requires independent Envoy Gateway upgrades and release tracking.
- Adds another reconciliation boundary between Gateway API resources and generated Envoy workloads.
- Envoy Gateway v1.8.2 is compiled against Gateway API v1.5.1 while this cluster installs v1.6.0 CRDs; compatibility must be tested and monitored.
- Standard Gateway API does not translate every ingress-nginx annotation exactly. Long requests, uploads, streaming, WebSockets, and OIDC flows require explicit application testing.
- Public cutover still spans Kubernetes, RouterOS, Cloudflare DNS, and certificate state.

### Neutral

- Cilium remains a critical networking component; this decision removes only its Gateway API responsibility.
- Tailscale-managed Ingress resources remain unchanged because they belong to the Tailscale operator, not ingress-nginx.
- A shared wildcard certificate remains acceptable for the homelab's public applications.

## Follow-up Decisions

- Whether Envoy Gateway remains on `10.0.3.10` or later reclaims `10.0.3.1` after ingress-nginx removal.
- Whether Envoy Gateway metrics use native VictoriaMetrics scrape resources or Prometheus-compatible ServiceMonitor/PodMonitor resources.
- Whether future internal services receive a separate Gateway and certificate boundary.

## References

- [ingress-nginx retirement announcement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
- [Kubernetes Steering and Security Response Committee statement](https://kubernetes.io/blog/2026/01/29/ingress-nginx-statement/)
- [Ingress documentation](https://kubernetes.io/docs/concepts/services-networking/ingress/)
- [Envoy Gateway v1.8.2](https://github.com/envoyproxy/gateway/releases/tag/v1.8.2)
- [Envoy Gateway Helm installation](https://gateway.envoyproxy.io/docs/install/install-helm/)
- [Envoy Gateway deployment modes](https://gateway.envoyproxy.io/docs/tasks/operations/deployment-mode/)
- [EnvoyProxy customization](https://gateway.envoyproxy.io/docs/tasks/operations/customize-envoyproxy/)
- [Cilium LB-IPAM](https://docs.cilium.io/en/stable/network/lb-ipam/)
- [Cilium BGP Control Plane](https://docs.cilium.io/en/stable/network/bgp-control-plane/)
- [Cilium issue #46798](https://github.com/cilium/cilium/issues/46798)
- [Gateway API migration guide](https://gateway-api.sigs.k8s.io/guides/getting-started/migrating-from-ingress/)
- [ADR-004 - Cilium CNI Migration](./ADR-004-cilium-cni-migration.md)
