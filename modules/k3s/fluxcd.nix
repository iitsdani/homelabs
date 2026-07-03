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

  # Flux operator is deployed via a static HelmChart manifest in
  # manifests/04-flux-operator.yaml with bootstrap=true.
}