{
  imports = [
    ./server.nix
    ./argocd.nix
    ./tailscale.nix
  ];

  services.k3s.role = "server";
  services.k3s.clusterInit = true;
  services.k3s.manifests =
    let
      dir = ./manifests;
      files = builtins.attrNames (builtins.readDir dir);
    in
    builtins.listToAttrs (map
      (filename: {
        name = builtins.replaceStrings [ ".yaml" ] [ "" ] filename; # Strips the suffix.
        value = { enable = true; source = ./. + "/manifests/${filename}"; };
      })
      files);
}
