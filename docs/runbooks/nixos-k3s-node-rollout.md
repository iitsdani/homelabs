# Staged NixOS/k3s Node Rollout

This runbook covers staged NixOS package, kernel, and k3s version updates across the
Kubernetes nodes.

All nodes run k3s as servers and are etcd members. The rollout must preserve etcd
quorum and Longhorn volume availability, so only one node is touched at a time.

Use this runbook for:

- `nix flake update` / nixpkgs updates
- kernel and initrd changes
- k3s version changes bundled in nixpkgs
- node reboots required by the above

Do not use this runbook for Longhorn manager, Cilium, or CNPG version upgrades.

## Golden rules

1. **One node at a time.** Always pass `--on <node>` to Colmena. Plain
   `colmena apply` deploys in parallel.
2. **Never run `k3s-killall.sh` for an upgrade.** It is an uninstall/recovery
   script. Use `colmena switch` or a reboot.
3. **Never use `kubectl drain --disable-eviction`.** Do not delete Longhorn
   instance-manager PDBs manually.
4. **Wait for Longhorn to return to healthy before touching the next node.**
5. **Keep etcd quorum.** At least three of four members must remain healthy.
6. **Leave the k3s init server for last.** It runs with `clusterInit = true`,
   is the k3s `serverAddr` for joining nodes, and is used as Cilium's
   `k8sServiceHost`.
7. **Do not mutate GitOps-managed resources** except ephemeral operations:
   cordon, drain, delete a stuck pod, uncordon. Temporary Longhorn settings must
   be reverted.

## Prerequisites

### 1. Longhorn webhook safety

Longhorn hardcodes `failurePolicy: Fail` on its admission webhooks. The Helm
chart does not expose a value for it. If the webhook has no endpoints while a
node is booting, it can block node updates and deadlock CNI startup. See
INC-0008 and INC-0009.

Verify both webhook configurations:

```sh
kubectl --context=home get validatingwebhookconfiguration longhorn-webhook-validator \
  -o jsonpath='{.webhooks[*].failurePolicy}'; echo
kubectl --context=home get mutatingwebhookconfiguration longhorn-webhook-mutator \
  -o jsonpath='{.webhooks[*].failurePolicy}'; echo
```

Required: `Ignore` / `Ignore`.

Prefer a durable GitOps guard that keeps both configurations at
`failurePolicy: Ignore`. If that is not in place yet, use this break-glass patch
before starting the rollout:

```sh
kubectl --context=home patch validatingwebhookconfiguration longhorn-webhook-validator \
  --type=json -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
kubectl --context=home patch mutatingwebhookconfiguration longhorn-webhook-mutator \
  --type=json -p='[{"op":"replace","path":"/webhooks/0/failurePolicy","value":"Ignore"}]'
```

### 2. Cluster baseline

Run on the k3s init server:

```sh
ssh root@<init-server> 'k3s etcd-snapshot save --name pre-nixos-$(date +%F)'
```

Capture the cluster state:

```sh
kubectl --context=home get nodes -o wide
kubectl --context=home get --raw '/healthz/etcd'
kubectl --context=home get --raw '/readyz?verbose' | tail -5
cilium status --context home --namespace networking --wait=false
kubectl --context=home -n longhorn-system get nodes.longhorn.io
kubectl --context=home -n longhorn-system get volumes.longhorn.io
kubectl --context=home -n longhorn-system get replicas.longhorn.io
kubectl --context=home -n argo-system get applications | grep -vE 'Synced[[:space:]]+Healthy'
```

Record:

- current k3s versions (`kubectl get nodes`)
- current kernel versions (`uname -r`)
- already-detached or degraded Longhorn volumes
- ArgoCD applications that are already non-Healthy before the rollout

### 3. Build once

From macOS, Linux builds must run on the target because there is no Linux remote
builder configured:

```sh
nix flake update nixpkgs
nix flake check
nix run github:nix-community/colmena -- build --on <node> --build-on-target
```

Use `--build-on-target` on every Colmena command that builds or applies.

## Preflight per node

Set the target node:

```sh
NODE=<node>
```

Inspect the node and its Longhorn state:

```sh
kubectl --context=home get node "$NODE" -o wide
kubectl --context=home get pods -A --field-selector spec.nodeName="$NODE" -o wide

kubectl --context=home -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness,NODE:.status.currentNodeID \
  | grep "$NODE"

kubectl --context=home -n longhorn-system get replicas.longhorn.io \
  -o custom-columns=VOLUME:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState \
  | grep "$NODE"

kubectl --context=home get clusters.postgresql.cnpg.io -A -o wide
kubectl --context=home get pods -A -o wide | grep -E 'cnpg-cluster-[0-9]+'
```

Before draining, identify:

- **Single-instance CNPG pods on the target.** Their PDB has
  `minAvailable: 1`, so it can never be satisfied during a drain.
- **Longhorn volumes with `numberOfReplicas: 1` on the target.** These can block
  the drain under `block-if-contains-last-replica`.
- **Detached or unknown volumes with a stopped replica on the target.** These
  block the instance-manager PDB removal after workloads are gone.

## Per-node procedure

### 1. Cordon

```sh
kubectl --context=home cordon "$NODE"
```

Longhorn automatically disables scheduling on the cordoned node.

### 2. Move single-instance CNPG pods

For each CNPG pod on the target whose cluster has `instances: 1`, delete the pod
directly. A direct delete bypasses the CNPG PDB. Because the node is already
cordoned, the operator reschedules the pod on another node.

```sh
kubectl --context=home -n <namespace> delete pod <cnpg-pod>
```

Wait for the replacement pod and for the old Longhorn volume to detach:

```sh
kubectl --context=home -n <namespace> get pods -o wide -w
kubectl --context=home -n longhorn-system get volume <pvc-name>
```

If DB downtime is not acceptable, scale the CNPG cluster to two instances in Git
before draining, wait for the replica to be healthy, drain, and scale back after
the rollout.

### 3. Drain the node

Start with the normal drain:

```sh
kubectl --context=home drain "$NODE" \
  --ignore-daemonsets --delete-emptydir-data --timeout=0
```

Longhorn intentionally blocks the drain if the node holds a last healthy
replica, or if volumes are still attached. This is not a bug.

If the drain stalls on `instance-manager-...` with:

```text
Cannot evict pod as it would violate the pod's disruption budget
```

then:

1. Stop the drain with `Ctrl-C`.
2. Check which volumes are still attached:

   ```sh
   kubectl --context=home -n longhorn-system get volumes.longhorn.io \
     -o custom-columns=NAME:.metadata.name,STATE:.status.state,NODE:.status.currentNodeID \
     | grep "$NODE"
   ```

3. Evict workloads first while excluding the instance-manager:

   ```sh
   kubectl --context=home drain "$NODE" \
     --ignore-daemonsets --delete-emptydir-data \
     --pod-selector='longhorn.io/component!=instance-manager' \
     --timeout=0
   ```

4. Wait until no volumes remain attached to the node.
5. Run the normal drain again:

   ```sh
   kubectl --context=home drain "$NODE" \
     --ignore-daemonsets --delete-emptydir-data --timeout=0
   ```

Do not bypass the PDB. If the drain still blocks, inspect the Longhorn manager:

```sh
kubectl --context=home -n longhorn-system logs \
  -l app=longhorn-manager --tail=100 \
  | grep -iE 'pdb|unschedulable|blocked'
```

### 4. Handle a stopped last replica

If the Longhorn manager log says:

```text
removing <node> PDB is blocked: replica ... has no pdb on another node
```

and that replica is stopped or the volume is detached, temporarily allow
stopped last replicas:

```sh
kubectl --context=home -n longhorn-system patch settings.longhorn.io/node-drain-policy \
  --type=merge -p '{"value":"allow-if-replica-is-stopped"}'
```

Retry the normal drain. After the drain completes, revert the setting:

```sh
kubectl --context=home -n longhorn-system patch settings.longhorn.io/node-drain-policy \
  --type=merge -p '{"value":"block-if-contains-last-replica"}'
```

This policy only works safely for planned maintenance where the node returns. It
permits data loss if the node is permanently removed.

### 5. Verify the drain

```sh
kubectl --context=home get pods -A --field-selector spec.nodeName="$NODE" -o wide
```

Expected: only DaemonSets and other ignored pods remain. There should be no
application pods and no Longhorn instance-manager pod.

### 6. Apply the NixOS update

If the kernel, initrd, or k3s package changed, use `--reboot`:

```sh
nix run github:nix-community/colmena -- apply --on "$NODE" --build-on-target --reboot
```

If only userland packages changed, no reboot is needed:

```sh
nix run github:nix-community/colmena -- apply --on "$NODE" --build-on-target switch
```

`--reboot` uses the `boot` goal, reboots the node, and waits for SSH to return.

### 7. Post-boot verification

```sh
kubectl --context=home get node "$NODE"
ssh root@"$NODE" 'systemctl is-active k3s; uname -r; k3s --version; nixos-version'
cilium status --context home --namespace networking --wait
kubectl --context=home -n longhorn-system get nodes.longhorn.io "$NODE"
kubectl --context=home -n longhorn-system get volumes.longhorn.io
kubectl --context=home get pods -A --field-selector spec.nodeName="$NODE" -o wide
```

Do not uncordon until:

- the node is `Ready`
- k3s is active
- Cilium is healthy
- the Longhorn node is `Ready`
- critical pods are not crash-looping

Then:

```sh
kubectl --context=home uncordon "$NODE"
```

### 8. Gate before the next node

Do not start the next node until:

- all Longhorn volumes are `healthy` again, except known pre-existing detached
  volumes
- no replicas are rebuilding
- ArgoCD applications match the pre-rollout baseline
- workloads have rescheduled

## Verification commands

Cluster-wide:

```sh
kubectl --context=home get nodes -o wide
kubectl --context=home get --raw '/healthz/etcd'
kubectl --context=home get --raw '/readyz?verbose' | tail -5
cilium status --context home --namespace networking --wait
kubectl --context=home -n longhorn-system get volumes.longhorn.io
kubectl --context=home -n longhorn-system get replicas.longhorn.io
kubectl --context=home -n argo-system get applications | grep -vE 'Synced[[:space:]]+Healthy'
```

Target node:

```sh
kubectl --context=home get node "$NODE" -o wide
kubectl --context=home -n longhorn-system get nodes.longhorn.io "$NODE"
kubectl --context=home get pods -A --field-selector spec.nodeName="$NODE" -o wide
ssh root@"$NODE" 'systemctl is-active k3s; uname -r; k3s --version'
```

Longhorn volume gate:

```sh
kubectl --context=home -n longhorn-system get volumes.longhorn.io \
  -o custom-columns=NAME:.metadata.name,STATE:.status.state,ROBUSTNESS:.status.robustness

kubectl --context=home -n longhorn-system get replicas.longhorn.io \
  -o custom-columns=VOLUME:.spec.volumeName,NODE:.spec.nodeID,STATE:.status.currentState
```

## Abort and rollback

Abort the rollout if:

- etcd quorum is at risk
- more than one node is `NotReady`
- Longhorn volumes become `faulted` or unusable
- Cilium is unhealthy
- multiple ArgoCD applications become `Degraded`
- a drain block is not understood

Rollback:

1. Stop the rollout and leave the current node cordoned.
2. If the new generation does not boot, select the previous NixOS generation in
   systemd-boot.
3. If the configuration is wrong, revert the Git commit and re-apply to that one
   node.
4. If `uncordon` fails on the Longhorn webhook, patch both Longhorn webhook
   configurations to `failurePolicy: Ignore`, then persist the fix in Git.
5. If a VM is unreachable, use the Proxmox console. For baremetal, use the
   machine's console or IPMI.

## Known failure signatures

| Symptom                                                                | Cause                                                         | Action                                                                                              |
| ---------------------------------------------------------------------- | ------------------------------------------------------------- | --------------------------------------------------------------------------------------------------- |
| `Cannot evict ... instance-manager ... violation of disruption budget` | Longhorn volumes still attached, or a last replica is stopped | Evict workloads first with `--pod-selector`; use `allow-if-replica-is-stopped` for stopped replicas |
| `Cannot evict ... <app>-cnpg-cluster-...`                              | Single-instance CNPG PDB (`minAvailable: 1`)                  | Delete the CNPG pod after cordon, or scale the cluster to 2 first                                   |
| `no pdb on another node` in Longhorn manager logs                      | Last or only replica on the node                              | Stop the workload, or temporarily use `allow-if-replica-is-stopped`                                 |
| `failed calling webhook "validator.longhorn.io"`                       | Longhorn webhook `failurePolicy: Fail` with no endpoints      | Patch both Longhorn webhooks to `Ignore`; add a durable guard                                       |
| Colmena build fails on `firmware` or `linux-*-modules` from macOS      | Nix tried to build `x86_64-linux` locally                     | Add `--build-on-target`                                                                             |
| `cilium status` reports a missing daemonset                            | Cilium runs in the `networking` namespace                     | Use `cilium status --namespace networking`                                                          |
| Node remains `SchedulingDisabled`                                      | `uncordon` was not run                                        | Run `kubectl uncordon <node>` after verification                                                    |

## Post-rollout

- Confirm all nodes run the same k3s and kernel versions.
- Revert any temporary Longhorn drain policy.
- Scale any deliberately scaled-down workloads back up.
- Remove legacy or unused Longhorn volumes that block future drains, if the data
  is no longer needed.
- Verify Longhorn volumes, replicas, and ArgoCD are healthy.

## References

- `docs/postmortems/INC-0008-flannel-startup-deadlock-longhorn-webhook-after-k3s-1.35-upgrade.md`
- `docs/postmortems/INC-0009-nl-pve-01-memory-overcommit-hang-and-flannel-webhook-deadlock.md`
- `docs/runbooks/longhorn-volumes-attach-detach-loop.md`
- Longhorn node maintenance guide: <https://longhorn.io/docs/1.11.3/maintenance/maintenance/>
