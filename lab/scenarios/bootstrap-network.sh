# lab/scenarios/bootstrap-network.sh — headless equivalent of the
# smbproxy-init wizard's "assign NIC roles + bring up legacy NIC"
# step. Without this, every other scenario (join-domain,
# backend-mount, frontend-share) fails because there's no roles file
# and the legacy NIC has no IP.
#
# What it does:
#   - Identifies the domain NIC as the one currently holding LAB_VM_IP.
#   - Identifies the legacy NIC as the other (and only other) ethernet.
#   - Writes /etc/smbproxy/nic-roles.env (matches the wizard's format).
#   - Writes /etc/netplan/60-smbproxy-init.yaml with the legacy NIC
#     pinned to SC_LEGACY_CIDR (default 172.29.137.10/24, gateway-less,
#     DNS-less). The domain NIC stanza keeps DHCP — the wizard's
#     "static after join" step is a separate concern.
#   - netplan apply, then verifies LegacyZone reachability.
#
# This scenario is also used as a pre_hook by join-domain,
# backend-mount, and frontend-share.
#
# Overridable via env:
#   SC_LEGACY_CIDR   default 172.29.137.10/24

SC_LEGACY_CIDR="${SC_LEGACY_CIDR:-172.29.137.10/24}"
SC_LEGACY_GW_IP="${SC_LEGACY_GW_IP:-172.29.137.1}"

# Idempotent helper: does the role assignment + netplan write + apply.
# Designed to be safe to call multiple times (the wizard equivalent is
# also idempotent). Other scenarios call this from their pre_hook.
bootstrap_network() {
    say "discovering NICs by IP/MAC"
    local discovery
    discovery=$(ssh_vm "bash -s" <<REMOTE
set -e
dom_iface=\$(ip -4 -o addr show scope global \\
              | awk -v ip="$LAB_VM_IP" '\$4 ~ "^"ip"/" {print \$2; exit}')
[[ -n "\$dom_iface" ]] || { echo "ERROR: no iface with $LAB_VM_IP" >&2; exit 1; }
dom_mac=\$(cat "/sys/class/net/\$dom_iface/address")

# Pick the legacy NIC: the only other ethernet (type 1) that isn't the
# domain NIC and isn't loopback.
leg_iface=""
for n in \$(ls -1 /sys/class/net | grep -v '^lo$'); do
    [[ "\$n" == "\$dom_iface" ]] && continue
    typ=\$(cat "/sys/class/net/\$n/type" 2>/dev/null || echo 0)
    [[ "\$typ" == "1" ]] || continue
    leg_iface=\$n
    break
done
[[ -n "\$leg_iface" ]] || { echo "ERROR: no second ethernet interface" >&2; exit 1; }
leg_mac=\$(cat "/sys/class/net/\$leg_iface/address")

printf 'DOMAIN_IFACE=%s\nDOMAIN_MAC=%s\nLEGACY_IFACE=%s\nLEGACY_MAC=%s\n' \\
    "\$dom_iface" "\$dom_mac" "\$leg_iface" "\$leg_mac"
REMOTE
)
    echo "$discovery"
    eval "$discovery"

    say "writing /etc/smbproxy/nic-roles.env"
    ssh_vm "sudo install -d -m 0755 /etc/smbproxy && sudo tee /etc/smbproxy/nic-roles.env >/dev/null <<EOF
DOMAIN_NIC_NAME=\"$DOMAIN_IFACE\"
DOMAIN_NIC_MAC=\"$DOMAIN_MAC\"
LEGACY_NIC_NAME=\"$LEGACY_IFACE\"
LEGACY_NIC_MAC=\"$LEGACY_MAC\"
EOF
sudo chmod 0644 /etc/smbproxy/nic-roles.env"

    say "writing /etc/netplan/60-smbproxy-init.yaml (domain DHCP, legacy $SC_LEGACY_CIDR)"
    # Match the wizard's exact format so the live config and the
    # operator path stay byte-for-byte equivalent.
    ssh_vm "sudo tee /etc/netplan/60-smbproxy-init.yaml >/dev/null <<EOF
network:
  version: 2
  ethernets:
    ${DOMAIN_IFACE}:
      match:
        macaddress: \"$DOMAIN_MAC\"
      set-name: ${DOMAIN_IFACE}
      dhcp4: true
      dhcp6: false
    ${LEGACY_IFACE}:
      match:
        macaddress: \"$LEGACY_MAC\"
      set-name: ${LEGACY_IFACE}
      dhcp4: false
      dhcp6: false
      addresses: [${SC_LEGACY_CIDR}]
EOF
sudo chmod 0600 /etc/netplan/60-smbproxy-init.yaml"

    say "netplan apply"
    ssh_vm 'sudo netplan apply 2>&1 | sed "s/^/  /"'
}

run_scenario() {
    bootstrap_network
}

verify() {
    local rc=0 out

    say "nic-roles.env populated"
    out=$(ssh_vm 'sudo cat /etc/smbproxy/nic-roles.env' 2>&1 || true)
    echo "$out"
    grep -qE '^DOMAIN_NIC_NAME="[^"]+"' <<< "$out" || { say "DOMAIN_NIC_NAME unset"; rc=1; }
    grep -qE '^LEGACY_NIC_NAME="[^"]+"' <<< "$out" || { say "LEGACY_NIC_NAME unset"; rc=1; }
    grep -qE '^DOMAIN_NIC_MAC="[0-9a-f:]{17}"' <<< "$out" || { say "DOMAIN_NIC_MAC malformed"; rc=1; }
    grep -qE '^LEGACY_NIC_MAC="[0-9a-f:]{17}"' <<< "$out" || { say "LEGACY_NIC_MAC malformed"; rc=1; }

    say "netplan file present and 0600"
    ssh_vm 'sudo test -f /etc/netplan/60-smbproxy-init.yaml' || rc=1
    out=$(ssh_vm 'sudo stat -c "%a %U %G" /etc/netplan/60-smbproxy-init.yaml' 2>&1 || true)
    echo "$out"
    grep -qE '^600 root root' <<< "$out" || { say "wrong perms on netplan file"; rc=1; }

    say "domain NIC still has $LAB_VM_IP"
    ssh_vm "ip -4 -o addr show scope global | grep -qF ' ${LAB_VM_IP}/'" || rc=1

    say "legacy NIC has the configured CIDR"
    out=$(ssh_vm 'ip -4 -o addr show scope global' 2>&1 || true)
    echo "$out"
    local leg_ip="${SC_LEGACY_CIDR%/*}"
    grep -qF " ${leg_ip}/" <<< "$out" || { say "legacy NIC missing $leg_ip"; rc=1; }

    say "LegacyZone reachable: ping $SC_LEGACY_GW_IP (the WS2008 backend)"
    # ICMP from the proxy out the legacy NIC. The WS2008 firewall may
    # or may not reply — treat unreachable as informational since the
    # real test is the cifs mount in the next scenario, not ping.
    if ssh_vm "ping -c 2 -W 2 -I '$leg_ip' '$SC_LEGACY_GW_IP' >/dev/null 2>&1"; then
        say "  ping succeeded"
    else
        say "  ping failed (informational; WS2008 may drop ICMP — backend-mount scenario tests SMB1 directly)"
    fi

    say "default route did NOT leak onto the legacy NIC"
    out=$(ssh_vm 'ip -4 route show default' 2>&1 || true)
    echo "$out"
    if [[ -n "${LEGACY_IFACE:-}" ]] && grep -qE "dev[[:space:]]+${LEGACY_IFACE}\b" <<< "$out"; then
        say "default route is via the legacy NIC — netplan stanza is wrong"; rc=1
    fi

    return "$rc"
}
