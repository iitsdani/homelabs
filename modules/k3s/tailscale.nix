{ config, ... }:

{
  sops.secrets."tailscale/oauth-client-id".sopsFile = ./secrets.yaml;
  sops.secrets."tailscale/oauth-client-secret".sopsFile = ./secrets.yaml;

  sops.templates.tailscale-operator-oauth = {
    path = "/var/lib/rancher/k3s/server/manifests/01-tailscale-operator-oauth.json";
    content = builtins.toJSON {
      apiVersion = "v1";
      kind = "Secret";
      metadata = {
        name = "operator-oauth";
        namespace = "networking";
      };
      stringData = {
        "client_id" = config.sops.placeholder."tailscale/oauth-client-id";
        "client_secret" = config.sops.placeholder."tailscale/oauth-client-secret";
      };
    };
  };

  # bootstrap/default.nix creates the HelmChart only when absent; ArgoCD then tracks
  # bootstrap/manifests/02-tailscale-operator.yaml.
}
