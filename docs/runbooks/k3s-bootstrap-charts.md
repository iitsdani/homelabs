# Bootstrap charts and CRDs

The bootstrap server runs `k3s-bootstrap-charts.service` after K3s starts. It waits
for the local API and HelmChart CRD, then loads every input discovered under
`modules/k3s/bootstrap/manifests/`, in filename order. YAML files contain chart or
CRD resources; directories contain Kustomizations rendered before creation.
Existing resources are never updated. ArgoCD manages subsequent ArgoCD,
Tailscale, and Cilium chart changes through the Kustomizations under `kube/home/`.

Ordinary manifests remain in `modules/k3s/manifests/` and are published by
`server-main.nix`. Chart and CRD bootstrap inputs are not published to K3s's
watched directory. NixOS activation and service startup remove legacy published
copies without deleting cluster resources.

The service derives resource identity and namespaces from rendered YAML. Charts
can declare space-separated secret prerequisites with the
`bootstrap.homelabs/required-secrets` annotation; these secrets must exist in the
chart's target namespace. CRDs are processed individually and awaited until
established, so a partially bootstrapped CRD bundle can be resumed.

## Verify a deployment

On the bootstrap server:

```sh
systemctl status k3s-bootstrap-charts.service
journalctl -u k3s-bootstrap-charts.service
test ! -e /var/lib/rancher/k3s/server/manifests/02-tailscale-operator.yaml
test ! -e /var/lib/rancher/k3s/server/manifests/04-argocd.yaml
test ! -e /var/lib/rancher/k3s/server/manifests/03-cilium.yaml
test ! -e /var/lib/rancher/k3s/server/manifests/01-gateway-api-crds.yaml
test ! -e /var/lib/rancher/k3s/server/manifests/02-prometheus-operator-crds.yaml
kubectl -n kube-system get helmcharts argocd tailscale-operator cilium
kubectl -n argo-system get applications app-argocd app-tailscale-operator app-cilium
```

The service retries failures every 15 seconds. A successful run means bootstrap
declarations exist; Helm installation and ArgoCD reconciliation may still be
running.

## Recovery

When restoring missing bootstrap charts, rerun the service on the bootstrap server:

```sh
systemctl restart k3s-bootstrap-charts.service
```

This creates only missing resources, using the deployed NixOS generation's
definitions. Existing charts remain untouched. ArgoCD reconciles the current Git
revision after becoming available. The service is not a continuous watcher:
intentional chart deletion is only reversed when the service next runs.
