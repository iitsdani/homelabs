{
  services.tailscale.enable = true;
  services.tailscale.openFirewall = true;
  services.tailscale.useRoutingFeatures = "both";
  services.tailscale.extraUpFlags = [
    "--ssh"
    "--accept-dns"
    "--advertise-exit-node"
    "--advertise-tags=tag:vm,tag:region-nl"
  ];
}
