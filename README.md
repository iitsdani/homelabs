# homelabs

GitOps configuration for my personal servers and Kubernetes clusters.

## Features

Physical server machines are managed through either [Nix][nix] or [NixOS][nixos], and changes deployed through [Colmena][colmena].

Kubernetes clusters are managed through [Helm][helm] charts, applied using [Terragrunt][terragrunt].

Secrets are managed through [SOPS][sops], for both Kubernetes secrets (still thanks to Terragrunt decrypting support) and Nix/NixOS through [sops-nix].

## Useful tips

### Run `colmena`

Since `colmena` is imported as a flake (due to compatibility with `nixosConfiguration` for [nixos-anywhere]), it cannot be included in the `devShell` for some reason.

To run it, use the following command, replacing `{nodes}` with the target machines:

```
nix run github:nix-community/colmena -- apply --on "{nodes}"
```

### Fast node provisioning with `nixos-anywhere`

When needing to provision a new node, use [nixos-anywhere].

After adding the configuration in `machines` using [colmena] notation, the [compatibility layer](./flake.nix#L22) ensures the notation is compatible with `nixosConfiguration`, which `nixos-anywhere` requires.

Run the following command for building the configuration:

```
nix run github:nix-community/nixos-anywhere -- --flake .#{node} {user}@{addr}
```

replacing:

- `{node}` with the name of the configuration node,
- `{user}` with the name of the user, typically `root`,
- `{addr}` with the address of the node.

## Project structure

This repository uses the following structure:

- `clusters`: contains the configuration and deployment manifests of all Kubernetes clusters,
  - `clusters/<region>`: represents one cluster in a specific region,
  - `clusters/<region>/<namespace>`: contains the namespace configuration,
  - `clusters/<region>/<namespace>/<app>`: contains the deployment manifests and configuration of a specific application,
- `docs`: contains all useful documentation for the repository,
  - `docs/runbooks`: contains all the runbooks to solve specific issues with the clusters or servers,
- `machines`: contains the configuration of all the physical servers,
  - `machines/<machine-name>`: contains the configuration of a specific server,
- `modules`: contains all reusable, support modules

<!-- links -->

[nix]: https://nixos.org/
[nixos]: https://nixos.org/
[colmena]: https://colmena.cli.rs
[helm]: https://helm.sh/
[terragrunt]: https://terragrunt.gruntwork.io/
[sops]: https://getsops.io/
[sops-nix]: https://github.com/Mic92/sops-nix
[nixos-anywhere]: https://github.com/nix-community/nixos-anywhere
