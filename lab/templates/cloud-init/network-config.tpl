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
    # Force a MAC-based DHCP client-id instead of systemd-networkd's
    # default DUID. Without this, dnsmasq sees the DUID as the
    # client-id and refuses to match the MAC-only `dhcp-host=`
    # reservation, handing out a dynamic-pool address instead of the
    # reserved one. Affects build-time only — at deploy time the
    # operator typically picks a static IP via the smbproxy-init
    # wizard, but leaving this here keeps DHCP-friendly deployments
    # behaving deterministically against any reservation-aware
    # server.
    dhcp-identifier: mac
