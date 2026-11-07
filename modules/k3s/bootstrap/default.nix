{ lib, pkgs, ... }:

let
  manifests = builtins.attrNames (builtins.readDir ./manifests);

  cleanupBootstrapManifests = lib.concatMapStringsSep "\n"
    (name: "${pkgs.coreutils}/bin/rm -f /var/lib/rancher/k3s/server/manifests/${lib.removeSuffix ".yaml" name}.yaml")
    manifests;

  bootstrap = pkgs.writeShellApplication {
    name = "k3s-bootstrap-charts";
    runtimeInputs = with pkgs; [ kubectl coreutils yq-go jq ];
    text = builtins.readFile ./bootstrap-charts.sh;
  };
in
{
  # Removing a tmpfiles rule does not remove its previously published symlink.
  system.activationScripts.k3s-bootstrap-manifests.text = cleanupBootstrapManifests;
  systemd.services.k3s.preStart = lib.mkBefore cleanupBootstrapManifests;

  systemd.services.k3s-bootstrap-charts = {
    description = "Create missing bootstrap charts and CRDs";
    wantedBy = [ "multi-user.target" ];
    wants = [ "k3s.service" ];
    after = [ "k3s.service" ];
    environment.KUBECONFIG = "/etc/rancher/k3s/k3s.yaml";
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      Restart = "on-failure";
      RestartSec = "15s";
      TimeoutStartSec = "10min";
    };

    preStart = cleanupBootstrapManifests;

    script = "${bootstrap}/bin/k3s-bootstrap-charts " + lib.escapeShellArgs
      (map (name: "${./manifests + "/${name}"}") manifests);
  };
}
