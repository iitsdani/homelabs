{ nixos-hardware, ... }:

{ lib, ... }:

{
  # NOTE: overrides the Tailnet hostname target, only to be used if on LAN
  # and Tailscale is giving problems.
  #
  # deployment.targetHost = "10.0.1.3";
  deployment.targetUser = "root";
  deployment.tags = [ "type-server" "k8s-server" "zone-home" ];

  nixpkgs.system = "x86_64-linux";

  networking.hostName = "nl-k8s-03";
  networking.domain = "home.arpa";

  time.timeZone = "Europe/Amsterdam";

  services.k3s.extraFlags = lib.mkAfter [
    "--node-label media.transcoding.gpu=medium"
    "--node-label cianfr.one/gpu.transcoding.speed=medium"
    "--node-label cianfr.one/networking.linkspeed=1000Mbits"
    "--node-ip=10.0.1.3,fd00:cafe::1:3"
  ];

  imports = [
    nixos-hardware.nixosModules.common-pc-ssd
    nixos-hardware.nixosModules.common-cpu-intel
    nixos-hardware.nixosModules.common-gpu-intel
    ../../modules/server.nix
    ../../modules/intel-gpu-hwaccel.nix
    ../../modules/k3s/server-join.nix
    ./disko.nix
    ./networking.nix
    ./hardware-configuration.nix
    ./tailscale.nix
  ];
}
