{ config, ... }:

{
  sops.secrets."fluxcd/ssh-auth" = {
    key = "";
    format = "yaml";
    sopsFile = ./secrets/11-flux-ssh-auth.yaml;
    path = "/var/lib/rancher/k3s/server/manifests/11-flux-ssh-auth.yaml";
  };

  sops.secrets."fluxcd/sops-age-key" = {
    key = "";
    format = "yaml";
    sopsFile = ./secrets/12-flux-sops-age-key.yaml;
    path = "/var/lib/rancher/k3s/server/manifests/12-flux-sops-age-key.yaml";
  };

  services.k3s.autoDeployCharts.flux-operator = {
    name = "flux-operator";
    repo = "oci://ghcr.io/controlplaneio-fluxcd/charts";
    version = "0.53.0";
    hash = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
    targetNamespace = "flux-system";
    createNamespace = true;
    values = {
      installCRDs = true;
      serviceMonitor = {
        create = true;
      };
    };
  };
}

