{
  sops.secrets."argocd/ksops-age-keys" = {
    key = "";
    format = "yaml";
    sopsFile = ./secrets/09-argocd-ksops-age-keys.yaml;
    path = "/var/lib/rancher/k3s/server/manifests/09-argocd-ksops-age-keys.yaml";
  };

  sops.secrets."argocd/homelab-repo" = {
    key = "";
    format = "yaml";
    sopsFile = ./secrets/10-argocd-homelab-repo.yaml;
    path = "/var/lib/rancher/k3s/server/manifests/10-argocd-homelab-repo.yaml";
  };

  # ArgoCD itself is deployed via a static HelmChart manifest in
  # manifests/04-argocd.yaml. The ApplicationSet resources that discover
  # kube/home/* are defined in manifests/11-argocd-homelab-kube-application-set.yaml.
}
