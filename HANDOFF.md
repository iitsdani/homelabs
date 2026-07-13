# Envoy Gateway Migration Handoff

This document is the implementation handoff for [ADR-005](docs/adrs/ADR-005-envoy-gateway-migration.md). It is intentionally procedural. Keep ingress-nginx serving production traffic until the Envoy Gateway path passes every acceptance test.

## Target State

- Envoy Gateway `v1.8.2` owns the `envoy` GatewayClass.
- One public Gateway in `networking` uses `10.0.3.10` and `2a02:a469:9060:3::10`, parallel to ingress-nginx on `.1`.
- Two Envoy Proxy replicas run on different nodes behind `externalTrafficPolicy: Local`.
- Cilium supplies CNI, kube-proxy replacement, LB-IPAM, and BGP only.
- Cilium Gateway API is disabled and the failed Cilium `external-gw` is deleted before Envoy Gateway creates its own `external-gw`.
- Five public nginx Ingresses become HTTPRoutes.
- ingress-nginx is removed only after public cutover and soak.
- Tailscale-class Ingresses remain unchanged.

## Current State

At handoff creation:

- Cilium is pinned to `1.19.5` in `modules/k3s/manifests/03-cilium.yaml`.
- `rollOutCiliumPods: true` is enabled.
- The latest embedded-Envoy test sets `envoy.enabled: false`.
- Cilium Gateway API is still enabled.
- `kube/home/networking/cilium-gateway/` contains the failed `external-gw` canary on `10.0.3.10`.
- ingress-nginx serves production on `10.0.3.1` and `2a02:a469:9060:3::1`.
- The worktree may contain staged and unstaged Cilium test changes. Inspect `git status` and `git diff --cached` before starting.

## Non-Goals

- Do not migrate Tailscale-managed Ingresses.
- Do not change Cilium routing mode, masquerading, IPAM, or BGP design.
- Do not reclaim `10.0.3.1` during initial Envoy validation.
- Do not remove ingress-nginx in the same change that installs Envoy Gateway.
- Do not apply generated `ingress2gateway` output without review.

## Proposed Repository Shape

```text
modules/k3s/manifests/
  01-gateway-api-crds.yaml                 # Existing upstream Gateway API CRD owner

kube/home/envoy-gateway-system/
  namespace.yaml
  kustomization.yaml
  envoy-gateway-crds/
    application.yaml
    kustomization.yaml
  envoy-gateway-controller/
    application.yaml
    kustomization.yaml

kube/home/networking/envoy-gateway/
  kustomization.yaml
  gatewayclass.yaml
  envoyproxy.yaml
  gateway.yaml
  certificate.yaml
  redirect.yaml
  canary-deployment.yaml                   # Temporary
  canary-service.yaml                      # Temporary
  canary-route.yaml                        # Temporary
  monitoring.yaml

kube/home/<namespace>/<application>/
  route.yaml                               # Public apps only
```

ApplicationSet names use the directory basename, so keep every app directory basename globally unique. Use `envoy-gateway-crds`, `envoy-gateway-controller`, and `envoy-gateway` exactly or choose equally distinct names.

## Phase 0 - Normalize and Capture Baseline

1. Inspect local state:

   ```sh
   git status --short
   git diff
   git diff --cached
   ```

2. Decide whether the embedded Envoy experiment should remain in history. Final Cilium state should keep `rollOutCiliumPods: true`, disable Cilium Gateway API, and avoid a standalone Cilium Envoy DaemonSet unless another Cilium L7 feature requires it.

3. Capture cluster baseline from `nl-k8s-01`:

   ```sh
   ssh root@nl-k8s-01 'kubectl get nodes -o wide'
   ssh root@nl-k8s-01 'kubectl -n networking get pods,svc -o wide'
   ssh root@nl-k8s-01 'kubectl -n networking exec ds/cilium -- cilium-dbg status --timeout 90s'
   ssh root@nl-k8s-01 'kubectl -n networking exec ds/cilium -- cilium-dbg bgp peers'
   ssh root@nl-k8s-01 'kubectl get ingress -A'
   ssh root@nl-k8s-01 'kubectl get gatewayclass,gateway,httproute -A'
   ```

4. Verify public endpoints through ingress-nginx over IPv4 and IPv6. Record current Cloudflare A, AAAA, and CNAME records plus TTLs for all five public hostnames.

5. Confirm candidate VIPs are unused. Initial recommendation:

   ```text
   IPv4:     10.0.3.10
   IPv6 GUA: 2a02:a469:9060:3::10
   ```

   Do not use `10.0.3.1` or `2a02:a469:9060:3::1` while ingress-nginx exists.

## Phase 1 - Install Envoy Gateway CRDs and Controller

1. Pin Envoy Gateway to `v1.8.2`.

2. Keep `modules/k3s/manifests/01-gateway-api-crds.yaml` as the only owner of upstream Gateway API CRDs. It currently installs v1.6.0.

3. Add the Envoy Gateway CRD chart as its own Argo Application. Configure it to install Envoy Gateway-specific CRDs only:

   ```yaml
   chart: gateway-crds-helm
   targetRevision: v1.8.2
   valuesObject:
     crds:
       gatewayAPI:
         enabled: false
       envoyGateway:
         enabled: true
   ```

   Verify the exact chart name and OCI URL against the v1.8.2 installation documentation while implementing.

4. Add the Envoy Gateway controller Application using OCI chart `oci://docker.io/envoyproxy/gateway-helm`, version `v1.8.2`.

5. Disable CRD installation in the controller chart because CRDs have separate ownership.

6. Run two controller replicas with topology spread and a PodDisruptionBudget. Start with explicit resource requests and conservative limits.

7. Deploy CRDs before controller. Use Argo sync waves on the child Applications or deploy as separate commits if ordering remains ambiguous.

8. Validate:

   ```sh
   ssh root@nl-k8s-01 'kubectl get crd | grep gateway.envoyproxy.io'
   ssh root@nl-k8s-01 'kubectl -n envoy-gateway-system get deploy,pod,svc -o wide'
   ssh root@nl-k8s-01 'kubectl -n envoy-gateway-system logs deploy/envoy-gateway --tail=200'
   ```

9. Stop if the controller reports incompatibility with Gateway API v1.6.0. Do not downgrade shared Gateway API CRDs in place without a separate decision.

Rollback: remove the two Envoy Gateway Application directories. No production traffic uses them yet.

## Phase 2 - Replace Cilium external-gw with Envoy external-gw

1. Delete `kube/home/networking/cilium-gateway/` and let Argo prune the failed Cilium Gateway, HTTPRoute, echo Deployment, and Services.

2. Confirm the Cilium `external-gw`, its generated LoadBalancer Service, and VIP `10.0.3.10` are gone:

   ```sh
   ssh root@nl-k8s-01 'kubectl -n networking get gateway external-gw'
   ssh root@nl-k8s-01 'kubectl -n networking get svc cilium-gateway-external-gw'
   ssh root@nl-k8s-01 'kubectl get svc -A -o wide | grep 10.0.3.10'
   ```

   All commands must return no matching resource before continuing.

3. Update `modules/k3s/manifests/03-cilium.yaml`:

   ```yaml
   gatewayAPI:
     enabled: false
   ```

4. Remove Cilium Gateway-only values:

   - `gatewayAPI.gatewayClass.create`;
   - `gatewayAPI.secretsNamespace`.

5. Keep `rollOutCiliumPods: true` and `envoy.enabled: false`.

6. Deploy and require all Cilium agents Ready, cluster health 4/4, all BGP peers Established, and no controller owning `GatewayClass/cilium`.

7. Create `GatewayClass/envoy`:

   ```yaml
   apiVersion: gateway.networking.k8s.io/v1
   kind: GatewayClass
   metadata:
     name: envoy
   spec:
     controllerName: gateway.envoyproxy.io/gatewayclass-controller
   ```

8. Create an `EnvoyProxy` in `networking` with:

   - Kubernetes provider;
   - two Envoy replicas;
   - topology spread across `kubernetes.io/hostname`;
   - PDB `minAvailable: 1`;
   - graceful shutdown and drain timeout;
   - dual-stack LoadBalancer Service;
   - `externalTrafficPolicy: Local`;
   - Cilium LB-IPAM annotation for `10.0.3.10` and `2a02:a469:9060:3::10`;
   - initial NodePort allocation left at its default for direct per-node testing.

9. Prefer the current Cilium annotation:

   ```yaml
   lbipam.cilium.io/ips: "10.0.3.10,2a02:a469:9060:3::10"
   ```

   Confirm the annotation against the installed Cilium 1.19.5 chart before committing.

10. Create `Gateway/external-gw` with class `envoy`, referencing the EnvoyProxy through `spec.infrastructure.parametersRef`.

11. Configure listeners:

   - HTTP port 80, routes from `networking` only;
   - HTTPS port 443, routes from all namespaces;
   - TLS termination using one wildcard Secret in `networking`.

12. Create an explicit cert-manager `Certificate` for `*.cianfr.one` and `cianfr.one`. Reuse `ClusterIssuer/cianfr.one-acme`.

13. Add an HTTPRoute in `networking` that redirects HTTP to HTTPS with status 308.

14. Add a temporary echo Deployment, Service, and HTTPS HTTPRoute with hostname `envoy-gateway-canary.invalid`.

15. Validate resource status:

   ```sh
   ssh root@nl-k8s-01 'kubectl get gatewayclass envoy -o yaml'
   ssh root@nl-k8s-01 'kubectl -n networking get envoyproxy,gateway,httproute,certificate -o wide'
   ssh root@nl-k8s-01 'kubectl -n networking describe gateway external-gw'
   ssh root@nl-k8s-01 'kubectl -n networking describe httproute envoy-gateway-canary'
   ssh root@nl-k8s-01 'kubectl -n networking get svc -l gateway.envoyproxy.io/owning-gateway-name=external-gw -o wide'
   ```

16. Require:

   - GatewayClass `Accepted=True`;
   - Gateway `Accepted=True` and `Programmed=True`;
   - HTTPRoute `Accepted=True` and `ResolvedRefs=True`;
   - generated Service owns both `.10` addresses;
   - two ready Envoy replicas on different nodes;
   - RouterOS sees `/32` and `/128` BGP routes from only those nodes.

17. Test without DNS or RouterOS NAT changes:

   ```sh
   curl --resolve envoy-gateway-canary.invalid:443:10.0.3.10 \
     https://envoy-gateway-canary.invalid/
   ```

   Use an explicit CA bypass only for the `.invalid` canary if its certificate does not cover that hostname. Prefer adding a temporary `canary.cianfr.one` certificate name when TLS verification itself is under test.

Rollback: delete `kube/home/networking/envoy-gateway/`. ingress-nginx remains untouched. Re-enable Cilium Gateway only for forensic reproduction, not production traffic.

## Phase 3 - Add Public HTTPRoutes in Parallel

Create raw `route.yaml` resources while retaining every nginx Ingress. Do not add external-dns annotations yet; test through `curl --resolve`.

### Route inventory

| Namespace | Route | Hostname | Backend |
|---|---|---|---|
| `auth` | `authelia` | `idp.cianfr.one` | Confirm rendered Authelia Service and port before authoring |
| `media` | `immich` | `photos.cianfr.one` | `immich-server:2283` |
| `media` | `jellyfin` | `media.cianfr.one` | `jellyfin:8096` |
| `opencloud-system` | `opencloud` | `drive.cianfr.one` | `opencloud:9200` |
| `auth` | `vaultwarden` | `vault.cianfr.one` | `vaultwarden:80` |

For each route:

1. Add `route.yaml` to its app directory and reference it from `kustomization.yaml`.
2. Parent it to `networking/external-gw`, section `https`.
3. Use `PathPrefix /`.
4. Wait for `Accepted=True` and `ResolvedRefs=True`.
5. Test against `10.0.3.10` with the real hostname and TLS verification.
6. Keep the existing nginx Ingress active throughout.

### Application-specific acceptance

- **Authelia**: login page, authorization endpoint, token exchange, and one downstream OIDC login.
- **Immich**: UI, WebSocket activity, multi-gigabyte upload, download, and explicit 600-second route timeout.
- **Jellyfin**: UI, WebSocket, direct play, transcoded playback, and range requests.
- **OpenCloud**: UI, OIDC callback, large upload/download, WebDAV if used, and explicit 600-second timeout.
- **Vaultwarden**: web vault, OIDC login, WebSocket notifications, and attachment upload/download.

Do not add request buffering merely to imitate nginx `proxy-body-size: "0"`. Envoy does not impose nginx's default request body limit; buffering would harm streaming and large uploads.

Rollback: remove one HTTPRoute at a time. Its nginx Ingress remains active.

## Phase 4 - Observability and Failure Testing

1. Add controller metrics scrape on port 19001 path `/metrics`.
2. Add Envoy data-plane scrape on port 19001 path `/stats/prometheus`.
3. Prefer native VictoriaMetrics scrape resources if they match repository convention; otherwise use ServiceMonitor/PodMonitor and verify VictoriaMetrics operator conversion.
4. Create dashboards or at minimum verify:

   - downstream request count and response codes;
   - upstream connection failures;
   - active connections;
   - Envoy readiness;
   - controller reconciliation errors.

5. Delete one Envoy Pod during repeated requests. Require:

   - Service endpoint removal before termination;
   - BGP path withdrawal for that node;
   - remaining replica serves new requests;
   - existing connections drain within configured timeout.

6. Reboot or restart one node hosting Envoy. Repeat checks.

Rollback: metrics resources are independent; remove them without affecting proxy traffic.

## Phase 5 - Public Cutover

1. Lower Cloudflare TTLs at least one previous TTL period before cutover.

2. Prepare a dedicated external-dns target such as `gw.it.cianfr.one`:

   - A record resolves to the RouterOS WAN IPv4 path;
   - AAAA record resolves to `2a02:a469:9060:3::10`;
   - verify Cloudflare proxy mode matches current policy.

3. Add external-dns annotations to the five HTTPRoutes only after the target exists:

   ```yaml
   external-dns.alpha.kubernetes.io/hostname: <application>.cianfr.one
   external-dns.alpha.kubernetes.io/target: gw.it.cianfr.one
   ```

4. Update `networking/router/port-forwards.tf` so public HTTP/HTTPS uses Envoy Gateway `.10` addresses instead of ingress-nginx `.1` addresses. Apply RouterOS changes through the normal Terraform workflow.

5. Verify public IPv4 and IPv6 from outside the LAN. Check all five hosts, redirect behavior, TLS chain, and source address headers.

6. Keep ingress-nginx and its Ingress resources installed for rollback. It will no longer receive public traffic but remains reachable by direct `.1` tests.

7. Soak for at least several days. Monitor HTTP 4xx/5xx rates, upstream failures, OIDC callbacks, uploads, streaming, and BGP path stability.

Rollback:

1. Restore RouterOS HTTP/HTTPS addresses to `.1`.
2. Restore external-dns targets to `in.it.cianfr.one` or previous records.
3. Verify public traffic returns to ingress-nginx.

## Phase 6 - Confirm Cilium Gateway Removal

The destructive Cilium Gateway removal happens in Phase 2 before Envoy claims the `external-gw` name and `.10` VIPs. This phase is an audit after public cutover.

1. Confirm `kube/home/networking/cilium-gateway/` does not exist.

2. Confirm `modules/k3s/manifests/03-cilium.yaml` contains:

   ```yaml
   gatewayAPI:
     enabled: false
   ```

3. Confirm Cilium Gateway-only values are absent:

   - `gatewayAPI.gatewayClass.create`;
   - `gatewayAPI.secretsNamespace`.

4. Confirm `rollOutCiliumPods: true` remains enabled.

5. Confirm `envoy.enabled: false` remains unless a separate Cilium L7 policy requirement is introduced.

6. Require:

   - all Cilium agents Ready;
   - Cilium BGP peers Established;
   - Cilium cluster health 4/4;
   - `GatewayClass/cilium` removed or no longer controlled;
   - `GatewayClass/envoy` remains Accepted;
   - Envoy Gateway public requests unaffected.

Do not re-enable Cilium Gateway after Envoy owns `external-gw`.

## Phase 7 - Remove ingress-nginx

After the soak period:

1. Remove nginx Ingress configuration from:

   - `kube/home/auth/authelia/values-authelia.yaml`;
   - `kube/home/auth/vaultwarden/application.yaml`;
   - `kube/home/media/immich/application.yaml`;
   - `kube/home/media/jellyfin/application.yaml`;
   - `kube/home/opencloud-system/opencloud/application.yaml`.

2. Keep each replacement HTTPRoute in its app kustomization.

3. Delete `kube/home/networking/ingress-nginx/` and let Argo prune the Helm release.

4. Remove ingress-nginx admission port `8443` from `modules/k3s/k3s.nix`.

5. Verify `10.0.3.1` and `2a02:a469:9060:3::1` are released by LB-IPAM and withdrawn from BGP.

6. Remove obsolete ingress-specific TLS Secrets and Certificates only after confirming cert-manager ownership and replacement wildcard certificate health.

7. Remove temporary Envoy canary resources.

8. Optionally reclaim `.1` for Envoy Gateway in a separate change. This is not required and creates avoidable Service/VIP churn; keeping `.10` is acceptable.

Rollback after ingress-nginx removal requires restoring its directory and application Ingress blocks, waiting for `.1` VIP allocation/BGP advertisement, then restoring RouterOS and DNS targets.

## Final Acceptance Checklist

- [ ] Envoy Gateway controller has two ready replicas.
- [ ] Envoy Gateway CRDs and upstream Gateway API CRDs have explicit, non-conflicting ownership.
- [ ] `GatewayClass/envoy` is Accepted.
- [ ] `networking/external-gw` is Accepted and Programmed.
- [ ] Envoy proxy has two spread replicas and PDB protection.
- [ ] Envoy Service owns expected IPv4 and GUA IPv6 VIPs.
- [ ] Cilium advertises only ready Envoy nodes for both address families.
- [ ] All five HTTPRoutes are Accepted and ResolvedRefs.
- [ ] HTTP redirects to HTTPS with status 308.
- [ ] TLS wildcard certificate is valid and auto-renewing.
- [ ] Authelia OIDC flows succeed.
- [ ] Immich and OpenCloud large uploads succeed.
- [ ] Jellyfin streaming and WebSockets succeed.
- [ ] Vaultwarden WebSockets and OIDC succeed.
- [ ] Public IPv4 and IPv6 succeed from outside the LAN.
- [ ] Tailscale-managed Ingresses remain healthy.
- [ ] Cilium Gateway is disabled and its canary removed.
- [ ] ingress-nginx is removed after soak.
- [ ] Cilium agents are healthy and all BGP sessions are Established.
- [ ] ArgoCD applications are Synced and Healthy.

## Durable Evidence

If updating Cilium issue #46798, include:

- Cilium 1.19.4 and 1.19.5 both affected;
- internal Pod backend affected, both same-node and remote-node;
- standalone and embedded Cilium Envoy affected;
- BPF and legacy host routing affected;
- Tailscale stopped still affected;
- rpfilter bypass and kernel `rp_filter=0` still affected;
- kernel socket remains `SYN_SENT` despite returned SYN-ACK;
- `pwru` path ends `cilium_net -> ip_forward -> SKB_DROP_REASON_IP_INHDR`.
