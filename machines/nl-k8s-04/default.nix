{ nixos-hardware, ... }:

{ lib, ... }:

{
  # NOTE: overrides the Tailnet hostname target, only to be used if on LAN
  # and Tailscale is giving problems.
  #
  # deployment.targetHost = "10.0.1.4";
  deployment.targetUser = "root";
  deployment.tags = [ "type-server" "k8s-agent" "zone-home" ];

  nixpkgs.system = "x86_64-linux";

  networking.hostName = "nl-k8s-04";
  networking.domain = "home.arpa";

  time.timeZone = "Europe/Amsterdam";

  services.k3s.extraFlags = lib.mkAfter [
    "--node-label media.transcoding.gpu=medium"
    "--node-label cianfr.one/gpu.transcoding.speed=medium"
    "--node-label cianfr.one/networking.linkspeed=1000Mbits"
    "--node-ip=10.0.1.4,fd00:cafe::1:4"
  ];

  imports = [
    nixos-hardware.nixosModules.lenovo-thinkpad-x270
    ../../modules/server.nix
    ../../modules/aarch64-cross-compile.nix
    ../../modules/intel-gpu-hwaccel.nix
    ../../modules/k3s/server-join.nix
    ./disable-docked-sleep.nix
    ./disko.nix
    ./hardware-configuration.nix
    ./networking.nix
    ./power-management.nix
    ./tailscale.nix
  ];
}
