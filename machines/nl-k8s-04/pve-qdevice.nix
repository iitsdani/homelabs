{ pkgs, ... }:

{
  environment.systemPackages = with pkgs; [
    corosync-qdevice
    nss.tools
  ];

  networking.firewall.allowedTCPPorts = [ 5403 ];

  users.groups.coroqnetd = { };
  users.users.coroqnetd.isSystemUser = true;
  users.users.coroqnetd.group = "coroqnetd";

  systemd.tmpfiles.rules = [ "d /etc/corosync/qnetd 0770 root coroqnetd -" ];

  systemd.services.corosync-qnetd = {
    description = "Corosync QDevice network arbitrator";
    wantedBy = [ "multi-user.target" ];
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];

    path = with pkgs; [
      corosync-qdevice
      nss.tools
      procps
      coreutils
    ];

    preStart = ''
      if [ ! -f /etc/corosync/qnetd/nssdb/cert9.db ]; then
        corosync-qnetd-certutil -i
      fi
    '';

    serviceConfig = {
      Type = "notify";
      User = "coroqnetd";
      Group = "coroqnetd";
      PermissionsStartOnly = true;
      RuntimeDirectory = "corosync-qnetd";
      RuntimeDirectoryMode = "0770";
      ExecStart = "${pkgs.corosync-qdevice}/bin/corosync-qnetd -f -l 10.0.1.4";
      Restart = "on-failure";
    };
  };
}
