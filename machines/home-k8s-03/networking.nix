let
  iface = "ens18";
in
{
  # Static IP address for IPv4 and IPv6 ULA, SLAAC for GUA.
  networking.useDHCP = false;
  networking.nameservers = [ "10.0.0.1" ];

  networking.interfaces.${iface} = {
    ipv4.addresses = [{
      address = "10.0.1.3";
      prefixLength = 22;
    }];

    ipv6.addresses = [{
      address = "fd00:cafe::1:3";
      prefixLength = 128;
    }];
  };

  networking.defaultGateway = {
    address = "10.0.0.1";
    interface = iface;
  };

  boot.kernel.sysctl = {
    "net.ipv6.conf.${iface}.accept_ra" = 2;
    "net.ipv6.conf.${iface}.autoconf" = 1;
  };
}
