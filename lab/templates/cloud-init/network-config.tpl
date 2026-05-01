version: 2
ethernets:
  # The proxy has TWO NICs:
  #   - the domain NIC (Lab-NAT switch, MAC pinned to @@DOMAIN_MAC_COLON@@
  #     by New-SmbProxyTestVM.ps1, dnsmasq hands it @@DOMAIN_IP@@)
  #   - the legacy NIC (LegacyZone switch, no DHCP, no gateway)
  #
  # Cloud-init only needs to bring the domain NIC up so the build host can
  # reach the appliance over SSH and run prepare-image.sh. The legacy NIC
  # is intentionally NOT listed below: with no entry, netplan emits no
  # networkd config for it and systemd-networkd treats the link as
  # unmanaged. That's correct for a NIC that has no DHCP server upstream
  # — smbproxy-init's NIC role wizard sets its static IP later, after the
  # operator confirms which physical interface is which.
  #
  # The MAC-pinned match below is what makes the dnsmasq reservation
  # (@@DOMAIN_MAC_COLON@@ -> @@DOMAIN_IP@@) deterministic regardless of
  # which kernel-predictable name (eth0 / enp1s0 / ens3) the host
  # assigns at boot.
  domain:
    match:
      macaddress: "@@DOMAIN_MAC_COLON@@"
    dhcp4: true
    dhcp6: false
