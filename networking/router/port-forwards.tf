locals {
  port_forwards = {
    "envoy-gateway" = {
      ipv4             = "10.0.3.10"
      ipv6_gua         = "2a02:a469:9060:3::10" # FIXME(ar3s3ru): Hardcoded KPN GUA, update on ISP move.
      ports            = [80, 443]
      hairpin          = true
      guest_accessible = true
    }
    "slskd" = {
      ipv4             = "10.0.3.2"
      ipv6_gua         = "2a02:a469:9060:3::2" # FIXME(ar3s3ru): Hardcoded KPN GUA, update on ISP move.
      ports            = [50429]
      hairpin          = false
      guest_accessible = false
    }
    "qbittorrent" = {
      ipv4             = "10.0.3.3"
      ipv6_gua         = "2a02:a469:9060:3::3" # FIXME(ar3s3ru): Hardcoded KPN GUA, update on ISP move.
      ports            = [30963]
      hairpin          = false
      guest_accessible = false
    }
  }

  port_forwards_with_hairpin = {
    for k, v in local.port_forwards : k => v if v.hairpin
  }
  port_forwards_with_guest = {
    for k, v in local.port_forwards : k => v if v.guest_accessible
  }
}

resource "routeros_ip_firewall_addr_list" "service_v4" {
  for_each = local.port_forwards
  list     = "ipv4-${each.key}"
  address  = each.value.ipv4
  comment  = "k8s: ${each.key} LAN IPv4"
}

resource "routeros_ipv6_firewall_addr_list" "service_v6" {
  for_each = local.port_forwards
  list     = "ipv6-${each.key}"
  address  = each.value.ipv6_gua
  comment  = "k8s: ${each.key} GUA"
}

resource "routeros_ip_firewall_filter" "service_forward_v4_wan" {
  for_each          = local.port_forwards
  chain             = "forward"
  action            = "accept"
  connection_state  = "new"
  protocol          = "tcp"
  in_interface_list = "WAN"
  dst_address_list  = routeros_ip_firewall_addr_list.service_v4[each.key].list
  dst_port          = join(",", each.value.ports)
  log               = false
  log_prefix        = ""
  comment           = "allow port forwarding to ${each.key}"
}

resource "routeros_ip_firewall_filter" "service_forward_v4_guest" {
  for_each          = local.port_forwards_with_guest
  chain             = "forward"
  action            = "accept"
  protocol          = "tcp"
  in_interface_list = "GUEST"
  dst_address_list  = routeros_ip_firewall_addr_list.service_v4[each.key].list
  dst_port          = join(",", each.value.ports)
  comment           = "allow guest to ${each.key}"
}

resource "routeros_ipv6_firewall_filter" "service_forward_v6_wan" {
  for_each          = local.port_forwards
  chain             = "forward"
  action            = "accept"
  protocol          = "tcp"
  in_interface_list = "WAN"
  dst_address_list  = routeros_ipv6_firewall_addr_list.service_v6[each.key].list
  dst_port          = join(",", each.value.ports)
  comment           = "allow port forwarding to ${each.key} (IPv6)"
}

resource "routeros_ip_firewall_nat" "service_dstnat" {
  for_each          = local.port_forwards
  chain             = "dstnat"
  action            = "dst-nat"
  protocol          = "tcp"
  dst_address_type  = "local"
  in_interface_list = "all"
  dst_port          = join(",", each.value.ports)
  to_addresses      = each.value.ipv4
  # to_ports is only set for single-port services. For multi-port (e.g. 80,443),
  # RouterOS rejects port lists in to_ports and the original port is preserved
  # at the new address by omitting it.
  to_ports   = length(each.value.ports) == 1 ? tostring(each.value.ports[0]) : null
  log        = false
  log_prefix = ""
  comment    = "port forward ${each.key}"
}

resource "routeros_ip_firewall_nat" "service_srcnat_hairpin" {
  for_each         = local.port_forwards_with_hairpin
  chain            = "srcnat"
  action           = "masquerade"
  protocol         = "tcp"
  src_address_list = "ipv4-local"
  dst_address_list = routeros_ip_firewall_addr_list.service_v4[each.key].list
  dst_port         = join(",", each.value.ports)
  log              = false
  log_prefix       = ""
  comment          = "hairpin NAT ${each.key}"
}
