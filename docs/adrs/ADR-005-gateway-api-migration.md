# Gateway API Migration — ingress-nginx Retirement

## Context and Problem Statement

In November 2025 the Kubernetes project [announced](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/) that ingress-nginx would retire in March 2026. The successor project (InGate) was also retired. No security patches or bugfixes will be released after EOL.

The `nl` cluster uses ingress-nginx as its sole external ingress controller, serving 4 applications via `Ingress` resources with `ingressClassName: nginx`:

- **immich** (`photos.cianfr.one`) — photo gallery, requires 600s timeouts and unlimited POST body size for uploads.
- **jellyfin** (`media.cianfr.one`) — media streaming, WebSocket.
- **vaultwarden** (`vault.cianfr.one`) — password manager.
- **opencloud** (`drive.cianfr.one`) — file sharing, requires 600s timeouts and unlimited POST body size for uploads.

13 additional applications use `ingressClassName: tailscale` via the Tailscale operator, which does not support Gateway API today. These are out of scope and remain on `Ingress`.

### Key questions

- Do we replace ingress-nginx with another Ingress controller or migrate to Gateway API?
- Which Gateway API implementation?
- How do we preserve the nginx-specific annotations (`proxy-body-size`, `proxy-read-timeout`, `proxy-send-timeout`)?
- Do we need a side-by-side cutover or can we do a straight replacement?
- How does DNS routing work with the new Gateway?

## Decision Drivers

- **Future-proofing**: Gateway API is the SIG-Network successor to Ingress. ingress-nginx is EOL.
- **Cilium integration**: Cilium Gateway API is already enabled (ADR-004) with `gatewayClass/cilium` Accepted. No new component to install.
- **Simplicity**: personal homelab — brief downtime acceptable. No need for weighted DNS canary.
- **Feature parity**: timeouts (GEP-1742 `HTTPRouteRule.timeouts`) and unlimited body size (Envoy default) must match the current nginx configuration.
- **Minimal RouterOS changes**: existing port-forward (WAN 80/443 → 10.0.3.1) and BGP advertisement should remain unchanged.

## Considered Options

1. **Keep ingress-nginx** — rejected: EOL, no security patches.
2. **Migrate to another Ingress controller** (Traefik, HAProxy Kubernetes Ingress) — rejected: same EOL trajectory as ingress-nginx (Ingress API is frozen); doesn't solve the root problem.
3. **Migrate to Cilium Gateway API** — ✅ Chosen. Already enabled, no new component, Gateway API v1.6.0 CRDs installed, `HTTPRoute.spec.rules.timeouts` supported.
4. **Envoy Gateway / Istio Gateway / kgateway** — rejected: would introduce a separate controller alongside Cilium. Cilium Gateway couples the L7 proxy to the CNI, enabling future CiliumNetworkPolicy on ingress traffic.

## Decision Outcome

Chosen option: **Cilium Gateway API (Option 3)**. Straight replacement — no side-by-side.

### Architecture

```
BEFORE:  client → *.cianfr.one → CNAME in.it.cianfr.one → WAN IP → dstnat → 10.0.3.1 (ingress-nginx LB)
AFTER:   client → *.cianfr.one → CNAME gw.it.cianfr.one → WAN IP → dstnat → 10.0.3.1 (Cilium Gateway LB)
```

- **One Gateway** (`external`, namespace `networking`) on `gatewayClassName: cilium`.
- **Addresses**: `10.0.3.1` (IPv4), `fd00:cafe::3:1` (ULA IPv6), `2a02:a469:9060:3::1` (GUA IPv6) — same IPs as the previous ingress-nginx LB Service. No RouterOS port-forward or BGP changes.
- **Listeners**: HTTP:80 (for redirect/future use), HTTPS:443 (TLS Terminate, wildcard `*.cianfr.one` cert).
- **Certificate**: cert-manager `Certificate` for `*.cianfr.one` + `cianfr.one`, issuer `cianfr.one-acme` (DNS-01 Cloudflare), secret `external-gateway-tls`.
- **DNS**: `external-dns` (Cloudflare provider) target changes from `in.it.cianfr.one` to `gw.it.cianfr.one`. The new `gw.it.cianfr.one` CNAME is pre-created manually in Cloudflare, pointing to the same Mikrotik DDNS hostname (`hkj0ardsmwy.sn.mynetname.net`).

### Per-app HTTPRoutes

Each app gets a raw `HTTPRoute` manifest in its own folder (`route.yaml`), referenced in the folder's `kustomization.yaml`. The bjw-s `app-template` chart (v5.0.1) has no native `httproute` values key, so routes are authored as standalone Kubernetes manifests.

| App | Hostname | Service:Port | Timeouts | Notes |
|-----|----------|-------------|----------|-------|
| immich | photos.cianfr.one | immich-server:2283 | request: 600s, backendRequest: 600s | Large uploads |
| jellyfin | media.cianfr.one | jellyfin:8096 | (none) | WebSocket streaming |
| vaultwarden | vault.cianfr.one | vaultwarden:80 | (none) | |
| opencloud | drive.cianfr.one | opencloud:9200 | request: 600s, backendRequest: 600s | Large uploads |

### Timeout and body size parity

- **`proxy-read-timeout: "600"` / `proxy-send-timeout: "600"`** → `HTTPRoute.spec.rules[].timeouts.request: 600s` + `timeouts.backendRequest: 600s`. This is GEP-1742 (Extended support), implemented by Cilium via Envoy's `route_config.request_timeout` / `per_try_timeout`.
- **`proxy-body-size: "0"`** (unlimited) → no configuration needed. Envoy has no default request body limit. nginx's `"0"` meant "unlimited"; Cilium's default is already unlimited.

### Cutover

One-shot straight replacement in a single ArgoCD sync cycle:

1. `kube/home/networking/gateway/` created — Gateway + Certificate.
2. `kube/home/networking/ingress-nginx/` deleted — ArgoCD prunes the Helm release and LB Service, releasing `10.0.3.1` from LB-IPAM.
3. Cilium Gateway acquires `10.0.3.1` → LB Service created → BGP advertises → Envoy programs routes.
4. `ingress:` blocks removed from all 4 app charts; `HTTPRoute` manifests added with `external-dns` annotations pointing to `gw.it.cianfr.one`.
5. external-dns flips Cloudflare CNAMEs from `in.it.cianfr.one` to `gw.it.cianfr.one` within one sync interval (~10s). Both resolve to the same WAN IP — invisible to clients.

Downtime: ~5-10 minutes between step 2 (ingress-nginx LB Service deleted) and step 3 (Gateway LB Service programmed).

### Out of scope (deferred)

- **Internal Gateway** for `*.home.cianfr.one` via Mikrotik external-dns webhook provider — future ADR.
- **Mosquitto TCPRoute** on internal Gateway — future ADR.
- **IoT VLAN90 → internal Gateway firewalling** — future ADR.
- **Tailscale-class Ingresses** (13 apps) — remain on `Ingress`; Tailscale operator does not support Gateway API.

## Consequences

### Positive

- No EOL ingress controller. Gateway API is the forward path with active SIG-Network development.
- Timeout and body size parity preserved. No upload regression for Immich or OpenCloud.
- Zero RouterOS changes (same IP, same port-forward, same BGP).
- Envoy has no default body size limit — strictly better than nginx's annotation-based approach.
- Source IP visibility works regardless of `externalTrafficPolicy` (Cilium TPROXY + `X-Forwarded-For`).
- Future CiliumNetworkPolicy can be applied to ingress traffic (Envoy is a policy enforcement point).

### Negative

- Brief downtime during cutover (~5-10 min). Acceptable for personal homelab.
- `gw.it.cianfr.one` CNAME must be created manually in Cloudflare before cutover.
- Wildcard certificate (`*.cianfr.one`) is shared across all apps on the Gateway. No per-app cert rotation. Acceptable for homelab scale.
- bjw-s `app-template` has no native HTTPRoute support — routes are raw manifests, not chart-managed. Slightly more operational surface.
- `in.it.cianfr.one` Cloudflare record remains orphaned (harmless, can be cleaned up later).

## References

- [ingress-nginx retirement announcement](https://kubernetes.io/blog/2025/11/11/ingress-nginx-retirement/)
- [Gateway API HTTP timeouts guide](https://gateway-api.sigs.k8s.io/guides/user-guides/http-timeouts/)
- [Cilium Gateway API docs](https://docs.cilium.io/en/stable/network/servicemesh/gateway-api/gateway-api/)
- [ADR-004 — Cilium CNI Migration](ADR-004-cilium-cni-migration.md)
- [ingress2gateway](https://github.com/kubernetes-sigs/ingress2gateway) — annotation translation reference