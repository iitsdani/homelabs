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

  services.k3s.autoDeployCharts.tailscale-operator = rec {
    name = "tailscale-operator";
    repo = "https://pkgs.tailscale.com/helmcharts";
    version = "1.98.3";
    hash = "sha256-p0E+sM6RWB/2b8caF9oM8Zoagi7XqE+0tSeGzrFwZaA=";
    targetNamespace = "networking";
    extraFieldDefinitions = {
      spec = {
        inherit version;
      };
    };
    values = {
      operatorConfig.hostname = "nl-k8s";
      apiServerProxyConfig.mode = "true";
    };
  };
}
