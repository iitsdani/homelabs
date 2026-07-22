# Agents Description

This repo contains the Infrastructure as Code (IaC) configuration for my personal home server cluster and Kubernetes cluster.

Refer to [README.md](./README.md) for more details.

In short:
- Home servers are either running NixOS baremetal (e.g. `nl-k8s-01` and `nl-k8s-04`) or NixOS VMs on Proxmox VE baremetal machines (e.g. `nl-k8s-02` on `nl-pve-01` and `nl-k8s-03` on `nl-pve-02`),
- Kubernetes cluster uses k3s, which is installed through Nixpkgs and configured through a dedicated Nix module
- Apps deployed on the Kubernetes cluster through GitOps with ArgoCD, looking at the `kube/` folder.

## Interacting with the home servers

When debugging or investigating issues or current status of the home servers, you should access the machine through SSH:

```sh
# Example for nl-k8s-01
ssh root@nl-k8s-01
```

This works both when connected to the home network LAN, and remotely through Tailscale.

## Interacting with the Kubernetes cluster

When debugging or investigating issues on the Kubernetes cluster (e.g. specific apps), use kubectl using the `nl` context:

```
kubectl --context=nl
```

When this doesn't work (for whatever reason), you can fallback to SSH in directly in one of the Kubernetes nodes and run kubectl from there:

```
# Example with nl-k8s-01, should work with any node
ssh root@nl-k8s-01 'kubectl ...'
```

### GitOps deployment rule

Never manually apply, delete, patch, scale, restart, or otherwise mutate Kubernetes resources managed by this repository. Make changes in Git and let ArgoCD reconcile them. Use `kubectl` only for read-only inspection unless the user explicitly overrides this rule.

## Kubernetes apps structure

Apps and workloads deployed on Kubernetes follow this structure:

```
kube/
  {namespace}/
    kustomization.yaml
    namespace.yaml
    {app}/
      kustomization.yaml
      values.yaml
```

Both `{namespace}` and `{app}` will be treated by ArgoCD as a dynamically-generated Application (through ApplicationSet).

`{namespace}` contains:
- The definition of the `Namespace` Kubernetes resource in `namespace.yaml`, referenced in `kustomization.yaml`
- Each app deployed as an `{app}` subfolder

`{app}` contains:
- A `values-*.yaml` file that defines the configuration of a specific Helm chart (referenced in `kustomization.yaml` under `helmCharts`)
- (Optional) One or more Kubernetes resources manifests (e.g. `my-app-data.yaml` for a `my-app-data` PersistentVolumeClaim), to be imported under `kustomization.yaml` in `resources`
- (Optional) A `ksops.yaml` file that references any `*.enc.yaml` file, which should be `Secret` resources encrypted using SOPS, and the `ksops.yaml` should be imported in `kustomization.yaml` under `generators`.

## Adding apps and workloads to Kubernetes

When adding apps and workloads to Kubernetes, you could use <https://kubesearch.dev> to research `HelmRelease` resources from open-source, home clusters on GitHub.

You can then use those examples to map it into the format used in this repository.
