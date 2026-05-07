# lab/scenarios/smoke-prepared-image.sh - verify the golden proxy image
# before any domain or backend operation.
#
# This scenario should run against a freshly reverted `golden-image` checkpoint.
# It verifies that prepare-image.sh produced a clean, unprovisioned proxy
# base: tools installed, smbd not enabled yet, no smb.conf, no backend cifs
# mount, no creds file, no NIC roles confirmed, and no deployment-specific
# realm/time configuration baked into the image.

run_scenario() {
    # Nothing to mutate. The runner has already reverted the VM and pushed
    # the current scripts, so verification can inspect the prepared image
    # directly.
    ssh_vm 'hostname; ip -4 addr show scope global | head -6'
}

verify() {
    local rc=0 out

    say "smbproxy-sconfig is installed"
    ssh_vm 'test -x /usr/local/sbin/smbproxy-sconfig && sudo /usr/local/sbin/smbproxy-sconfig --help | head -20' || rc=1

    say "required appliance tools are present"
    # Outer single quotes preserve the literal $c through ssh; the \$c
    # below survives the remote shell's parsing of the double-quoted
    # bash -lc argument and is only expanded by bash -lc's loop.
    out=$(ssh_vm 'sudo bash -lc "for c in samba smbd winbindd smbclient mount.cifs net wbinfo kinit klist nft chronyd dig whiptail; do printf \"%s \" \"\$c\"; command -v \"\$c\" || exit 1; done"' 2>&1 || true)
    echo "$out"
    if grep -qi 'not found' <<< "$out" || ! grep -q 'smbd' <<< "$out"; then
        rc=1
    fi

    say "samba-ad-dc is NOT installed (proxy is a member server only)"
    out=$(ssh_vm 'dpkg -l samba-ad-dc 2>&1' || true)
    grep -qE '^(rc|ii)\s+samba-ad-dc' <<< "$out" && { say "samba-ad-dc unexpectedly present"; rc=1; }

    say "no /etc/samba/smb.conf yet (sconfig writes it at frontend-configure time)"
    ssh_vm 'test ! -f /etc/samba/smb.conf' || rc=1

    say "smbd / winbind / nmbd are NOT enabled yet"
    out=$(ssh_vm 'for svc in smbd nmbd winbind; do printf "%s: " "$svc"; systemctl is-enabled "$svc" 2>/dev/null || true; done' 2>&1 || true)
    echo "$out"
    if grep -qE ': enabled$' <<< "$out"; then
        rc=1
    fi

    say "Kerberos and chrony are deployment-neutral skeletons"
    ssh_vm 'grep -q "YOURREALM.LAN" /etc/krb5.conf' || rc=1
    out=$(ssh_vm 'grep -E "^(server|pool) " /etc/chrony/chrony.conf || true' 2>&1 || true)
    echo "$out"
    if grep -qE 'time\.cloudflare|time\.google|debian\.pool|^server |^pool ' <<< "$out"; then
        say "chrony.conf has a deployment-specific time source baked in"
        rc=1
    fi

    say "no backend cifs creds file in the image"
    # Multi-share lays creds at /etc/samba/.creds-<safe>; legacy
    # singleton path /etc/samba/.legacy_creds and the original
    # sketch's /etc/samba/.legacy_creds is also checked for
    # belt-and-suspenders.
    ssh_vm 'sudo bash -c "shopt -s nullglob; f=(/etc/samba/.creds-* /etc/samba/.legacy_creds); [[ \${#f[@]} -eq 0 ]]"' || { say "credential file present in golden image"; rc=1; }

    say "no backend cifs mount active"
    out=$(ssh_vm 'mount | grep -E "type cifs " || true' 2>&1 || true)
    echo "$out"
    [[ -z "$out" ]] || { say "stray cifs mount in golden image"; rc=1; }

    say "smbproxy-firstboot has run (golden image is the post-firstboot snapshot)"
    ssh_vm 'test -f /var/lib/smbproxy-firstboot.done' || rc=1

    say "smbproxy-init has NOT been completed (operator hasn't logged in yet)"
    ssh_vm 'test ! -f /var/lib/smbproxy-init.done' || rc=1

    say "NIC role mapping is empty (operator picks via wizard)"
    # The roles file may exist as a header-only skeleton or not exist at
    # all, but DOMAIN_NIC_NAME / LEGACY_NIC_NAME must be unset.
    out=$(ssh_vm 'sudo bash -c "test -f /etc/smbproxy/nic-roles.env && cat /etc/smbproxy/nic-roles.env || echo MISSING"' 2>&1 || true)
    echo "$out"
    if grep -qE '^(DOMAIN_NIC_NAME|LEGACY_NIC_NAME)=[^"]*"[^"]+"' <<< "$out"; then
        say "NIC roles look pre-assigned in the golden image"; rc=1
    fi

    say "domain NIC has the dnsmasq-reserved IP $LAB_VM_IP"
    out=$(ssh_vm 'ip -4 -o addr show scope global' 2>&1 || true)
    echo "$out"
    grep -qF " $LAB_VM_IP/" <<< "$out" || { say "expected $LAB_VM_IP not found on any interface"; rc=1; }

    say "legacy NIC link is present (LegacyZone NIC, no IP yet)"
    # Two NICs total expected; cloud-init only gave one an IP. Confirm
    # the second link exists at the kernel level.
    out=$(ssh_vm 'ip -o link show | grep -cE ": e[a-z0-9]+: "' 2>&1 || true)
    echo "interface count: $out"
    if ! [[ "$out" =~ ^[2-9]$ ]]; then
        say "expected >= 2 ethernet interfaces; found $out"; rc=1
    fi

    say "network is alive through the lab router"
    ssh_vm 'ping -c 1 -W 2 10.10.10.1 >/dev/null' || rc=1

    return "$rc"
}
