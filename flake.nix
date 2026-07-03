{
  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    nixos-hardware.url = "github:NixOS/nixos-hardware/master";

    disko.url = "github:nix-community/disko";
    disko.inputs.nixpkgs.follows = "nixpkgs";

    sops-nix.url = "github:Mic92/sops-nix";
    sops-nix.inputs.nixpkgs.follows = "nixpkgs";

    colmena.url = "github:zhaofengli/colmena";
    colmena.inputs.nixpkgs.follows = "nixpkgs";
    colmena.inputs.flake-utils.follows = "flake-utils";

    devshell.url = "github:numtide/devshell";
    devshell.inputs.nixpkgs.follows = "nixpkgs";
  };

  outputs = inputs@{ nixpkgs, flake-utils, colmena, devshell, self, ... }:
    {
      colmena = import ./machines inputs;
      colmenaHive = colmena.lib.makeHive self.outputs.colmena;
      nixosConfigurations = self.outputs.colmenaHive.nodes;
    } // flake-utils.lib.eachDefaultSystem
      (system:
        let
          overlays = [
            devshell.overlays.default
          ];

          pkgs = import nixpkgs {
            inherit system overlays;
            config.allowUnfree = true;
          };
        in
        {
          devShell = with pkgs; pkgs.devshell.mkShell {
            packages = [
              nixpkgs-fmt
              nixd
              gnumake
              git-crypt
              opentofu
              terragrunt
              kubectl
              k9s
              stern
              kubernetes-helm
              tfk8s
              ssh-to-age
              sops
              inetutils
              immich-go # For bulk imports.
              q-text-as-data # For querying CSV/TSV files.
              garage # Management of garage system.
              argocd # CLI for interacting with ArgoCD.
              kustomize
              cilium-cli # Cilium CLI
              hubble
              fluxcd
            ] ++
            # Go packages for tool development.
            [
              go
              ko
              golangci-lint
              gopls
              delve
              go-outline
              gopkgs
            ];

            env = [
              {
                name = "KUBECONFIG";
                eval = "$PRJ_ROOT/kube/config.yaml";
              }
              {
                name = "TG_TF_PATH";
                eval = "tofu";
              }
            ];
          };
        }
      );
}
