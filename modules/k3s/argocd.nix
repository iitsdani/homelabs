{
  sops.secrets."argocd-ksops-age-keys" = {
    key = "";
    format = "yaml";
    sopsFile = ./secrets/09-argocd-ksops-age-keys.yaml;
    path = "/var/lib/rancher/k3s/server/manifests/09-argocd-ksops-age-keys.yaml";
  };

  sops.secrets."argocd-homelab-repo" = {
    key = "";
    format = "yaml";
    sopsFile = ./secrets/10-argocd-homelab-repo.yaml;
    path = "/var/lib/rancher/k3s/server/manifests/10-argocd-homelab-repo.yaml";
  };

  services.k3s.autoDeployCharts.argocd = {
    name = "argo-cd";
    repo = "https://argoproj.github.io/argo-helm";
    version = "9.5.15";
    hash = "sha256-lVAr6oVuLh6b+7elq5DTCZcLT/0Jj/Pa25kYg1B2i54=";
    targetNamespace = "argo-system";
    createNamespace = true;
    values = {
      redis-ha = {
        enabled = true;
      };
      controller = {
        replicas = 1;
      };
      server = rec {
        autoscaling = {
          enabled = true;
          minReplicas = 2;
        };
        ingress = {
          enabled = true;
          ingressClassName = "tailscale";
          hostname = "nl-argocd";
          tls = true;
        };
        ingressGrpc = ingress // {
          hostname = "nl-argocd-grpc";
        };
      };
      applicationSet = {
        replicas = 2;
      };
      configs = {
        cm = {
          # Kustomize build options:
          # --enable-helm: Enabling Helm chart rendering with Kustomize
          # --load-restrictor LoadRestrictionsNone: Local kustomizations may load files from outside their root
          #
          # For viaduct-ai/kustomize-sops:
          # --enable-alpha-plugins: Enable the use of alpha plugins, which are not yet considered stable
          # --enable-exec: Enable the use of exec plugins
          "kustomize.buildOptions" = "--enable-helm --load-restrictor LoadRestrictionsNone --enable-alpha-plugins --enable-exec";
          # Exclude certain resources from ArgoCD management
          # https://argo-cd.readthedocs.io/en/stable/operator-manual/declarative-setup/#resource-exclusioninclusion
          # Ignore VolumeSnapshot and VolumeSnapshotContent: Created by backup processes.
          "resource.exclusions" = ''
            - apiGroups:
                - snapshot.storage.k8s.io
              kinds:
                - VolumeSnapshot
                - VolumeSnapshotContent
              clusters:
                - "*"
            - apiGroups:
                - cilium.io
              kinds:
                - CiliumIdentity
              clusters:
                - "*"
          '';
        };
      };
      # kustomize-sops integration source:
      # https://github.com/viaduct-ai/kustomize-sops?tab=readme-ov-file#argocdgitops-operator-w-ksopsagekey-in-okd4ocp4
      repoServer = {
        autoscaling = {
          enabled = true;
          minReplicas = 2;
        };

        # Use init containers to configure custom tooling
        # https://argoproj.github.io/argo-cd/operator-manual/custom_tools/
        volumes = [
          {
            name = "custom-tools";
            emptyDir = { };
          }
          {
            name = "sops-age";
            secret = { secretName = "argocd-ksops-age-keys"; };
          }
        ];

        env = [
          {
            name = "XDG_CONFIG_HOME";
            value = "/.config";
          }
          {
            name = "SOPS_AGE_KEY_FILE";
            value = "/.config/sops/age/keys.txt";
          }
        ];

        initContainers = [
          {
            name = "install-ksops";
            image = "alpine:latest";
            command = [ "/bin/sh" "-c" ];
            # FIXME: there was a breaking change in 4.4.0
            # Source: https://github.com/viaduct-ai/kustomize-sops/issues/300
            args = [
              ''
                set -eux

                apk add --no-cache ca-certificates curl tar
                case "$(uname -m)" in
                  x86_64|amd64) ARCH="x86_64" ;;
                  aarch64|arm64) ARCH="arm64" ;;
                  *) echo "unsupported arch: $(uname -m)"; exit 1 ;;
                esac

                VERSION="v4.4.0"
                VERSION_RAW="''${VERSION#v}"
                URL="https://github.com/viaduct-ai/kustomize-sops/releases/download/''${VERSION}/ksops_''${VERSION_RAW}_Linux_''${ARCH}.tar.gz"

                curl -fsSL -o ksops.tar.gz "$URL"
                tar -C /custom-tools -xzf ksops.tar.gz ksops
                chmod +x /custom-tools/ksops
              ''
            ];
            volumeMounts = [
              {
                mountPath = "/custom-tools";
                name = "custom-tools";
              }
            ];
          }
        ];

        volumeMounts = [
          {
            mountPath = "/usr/local/bin/ksops";
            name = "custom-tools";
            subPath = "ksops";
          }
          {
            mountPath = "/.config/sops/age";
            name = "sops-age";
          }
        ];
      };
    };
  };
}
