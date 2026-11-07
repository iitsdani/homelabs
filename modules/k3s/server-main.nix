{ lib, ... }:

{
  imports = [
    ./server.nix
    ./argocd.nix
    ./tailscale.nix
    ./bootstrap
  ];

  services.k3s.role = "server";
  services.k3s.clusterInit = true;
  services.k3s.manifests = lib.mapAttrs'
    (filename: _: lib.nameValuePair (lib.removeSuffix ".yaml" filename) {
      enable = true;
      source = ./manifests + "/${filename}";
    })
    (builtins.readDir ./manifests);
}
