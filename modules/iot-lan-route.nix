{ pkgs, ... }:

{
  systemd.services.iot-lan-route = {
    description = "Prefer LAN routing for the IoT subnet";
    wantedBy = [ "multi-user.target" "tailscaled.service" ];
    after = [ "tailscaled.service" ];
    partOf = [ "tailscaled.service" ];
    path = [ pkgs.iproute2 ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
    };
    # Tailscale's table 52 lookup has priority 5270; retain its other subnet routes.
    script = ''
      ip -4 rule del to 10.90.0.0/24 lookup main priority 5260 2>/dev/null || true
      ip -4 rule add to 10.90.0.0/24 lookup main priority 5260
    '';
    preStop = ''
      ip -4 rule del to 10.90.0.0/24 lookup main priority 5260 2>/dev/null || true
    '';
  };
}
