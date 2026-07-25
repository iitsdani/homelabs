{ nixos-hardware, ... }:

{ lib, ... }:

{
  # NOTE: overrides the Tailnet hostname target, only to be used if on LAN
  # and Tailscale is giving problems.
  #
  # deployment.targetHost = "10.0.1.1";
  deployment.targetUser = "root";
  deployment.tags = [ "type-server" "k8s-server" "zone-home" ];

  nixpkgs.system = "x86_64-linux";

  networking.hostName = "nl-k8s-01";
  networking.domain = "home.arpa";

  time.timeZone = "Europe/Amsterdam";

  services.k3s.extraFlags = lib.mkAfter [
    "--node-label media.transcoding.gpu=fast"
    "--node-label cianfr.one/gpu.transcoding.speed=fast"
    "--node-label cianfr.one/networking.linkspeed=2500Mbits"
    "--node-ip=10.0.1.1,fd00:cafe::1:1"
    "--tls-san=nl-k8s-01.home.arpa"
  ];

  imports = [
    nixos-hardware.nixosModules.common-pc-ssd
    nixos-hardware.nixosModules.common-cpu-intel
    nixos-hardware.nixosModules.common-gpu-intel
    ../../modules/server.nix
    ../../modules/aarch64-cross-compile.nix
    ../../modules/intel-gpu-hwaccel.nix
    ../../modules/k3s/server-main.nix
    ./disko.nix
    ./hardware-configuration.nix
    ./networking.nix
    ./tailscale.nix
  ];
}
