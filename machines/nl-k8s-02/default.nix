{ nixos-hardware, ... }:

{ lib, ... }:

{
  # NOTE: overrides the Tailnet hostname target, only to be used if on LAN
  # and Tailscale is giving problems.
  #
  # deployment.targetHost = "10.0.1.2";
  deployment.targetUser = "root";
  deployment.tags = [ "type-server" "k8s-server" "region-nl" ];

  nixpkgs.system = "x86_64-linux";

  networking.hostName = "nl-k8s-02";
  networking.domain = "home.arpa";

  time.timeZone = "Europe/Amsterdam";

  services.k3s.extraFlags = lib.mkAfter [
    "--node-label media.transcoding.gpu=fast"
    "--node-label cianfr.one/gpu.transcoding.speed=fast"
    "--node-label cianfr.one/networking.linkspeed=2500Mbits"
    "--node-ip=10.0.1.2,fd00:cafe::1:2"
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
