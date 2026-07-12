{ lib, ... }:

{
  imports = [
    ./k3s.nix
  ];

  # Kubernetes through K3S.
  services.k3s.role = "server";
  services.k3s.extraFlags = lib.mkBefore [
    # Using ingress-nginx and Cilium Gateway API instead.
    "--disable=traefik"
    # Using Cilium LB-IPAM + BGP Control Plane instead. Klipper-LB silently
    # masks MetalLB/Cilium allocation failures by binding host ports.
    "--disable=servicelb"
    # Using Cilium CNI instead of Flannel.
    "--flannel-backend=none"
    "--disable-network-policy"
    "--disable-kube-proxy"
    # Dual-stacking it - it's 2025, let's use IPv6.
    "--cluster-cidr=10.42.0.0/16,fd00:cafe:42::/48"
    "--service-cidr=10.43.0.0/16,fd00:cafe:43::/112"
  ];
}
