# lab/scenarios/frontend-share.sh — publish the SMB3 frontend share
# that re-exports the WS2008 backend mount to AD-joined clients with
# the strict-locking semantics required by .TPS files.
#
# Sourced by lab/run-scenario.sh. Has access to ssh_host / ssh_vm /
# scp_to_vm / say / step helpers and the LAB_HV_* / LAB_VM_* variables.
#
# pre_hook (in order, each idempotent):
#   1. bootstrap_network          (NIC roles + legacy IP)
#   2. do_ad_cleanup_proxy        (remove smbproxy-1 from AD)
#   3. require_backend_pass       (fail fast if SC_BACKEND_PASS unset)
#   4. do_join_domain             (smbproxy-sconfig --join-domain)
#   5. do_configure_backend       (smbproxy-sconfig --configure-backend)
#
# run_scenario:
#   - smbproxy-sconfig --configure-frontend
#   - smbproxy-sconfig --apply-firewall
#
# Verification covers smb.conf locking semantics, testparm cleanliness,
# smbd listening on 445/tcp of the domain NIC, and a Kerberos-authenticated
# smbclient -k roundtrip from the proxy itself (a true cross-host SMB3
# test from samba-dc1 or WS2025-DC1 belongs in a future helper script).
#
# Overridable via env (defaults track the sketch + lab.test):
#   SC_FRONT_SHARE       default ProfitFab$  (matches backend share name;
#                                              trailing $ hides it from browse)
#   SC_FRONT_GROUP       default LAB\Domain Users
#                                  (zero-setup choice; every joined user is in it)
#   SC_FRONT_FORCE_USER  default $SC_FORCE_USER (= pfuser)
# Plus everything inherited from join-domain.sh and backend-mount.sh.

source "$(dirname "${BASH_SOURCE[0]}")/join-domain.sh"
source "$(dirname "${BASH_SOURCE[0]}")/backend-mount.sh"

SC_FRONT_SHARE="${SC_FRONT_SHARE:-ProfitFab\$}"
SC_FRONT_GROUP="${SC_FRONT_GROUP:-LAB\\Domain Users}"
SC_FRONT_FORCE_USER="${SC_FRONT_FORCE_USER:-${SC_FORCE_USER}}"

do_configure_frontend() {
    ssh_vm "sudo smbproxy-sconfig --configure-frontend \
        --share-name '$SC_FRONT_SHARE' \
        --group '$SC_FRONT_GROUP' \
        --force-user '$SC_FRONT_FORCE_USER'"
}

do_apply_firewall() {
    ssh_vm 'sudo smbproxy-sconfig --apply-firewall'
}

pre_hook() {
    step "bootstrap network (NIC roles + legacy IP)"
    bootstrap_network
    do_ad_cleanup_proxy
    require_backend_pass

    step "join domain (lab.test via WS2025-DC1)"
    do_join_domain

    step "configure backend cifs mount"
    do_configure_backend
}

run_scenario() {
    step "configure frontend SMB3 share [$SC_FRONT_SHARE]"
    do_configure_frontend

    step "apply nftables ruleset"
    do_apply_firewall
}

verify() {
    local rc=0 out

    say "smb.conf has the [$SC_FRONT_SHARE] section"
    out=$(ssh_vm "sudo grep -n \"^\\[$SC_FRONT_SHARE\\]\" /etc/samba/smb.conf" 2>&1 || true)
    echo "$out"
    [[ -n "$out" ]] || { say "share section missing"; rc=1; }

    say "share has the strict-locking + oplocks-off + force-user stanza"
    # Extract only the [share] block so the param greps below can't
    # match a same-named directive in another section.
    out=$(ssh_vm "sudo awk -v s='[$SC_FRONT_SHARE]' 'BEGIN{p=0} \$0==s{p=1; print; next} /^\\[/{p=0} p' /etc/samba/smb.conf" 2>&1 || true)
    echo "$out"
    grep -qE 'oplocks[[:space:]]*=[[:space:]]*no'         <<< "$out" || { say "oplocks != no";        rc=1; }
    grep -qE 'level2 oplocks[[:space:]]*=[[:space:]]*no'  <<< "$out" || { say "level2 oplocks != no"; rc=1; }
    grep -qE 'strict locking[[:space:]]*=[[:space:]]*yes' <<< "$out" || { say "strict locking != yes"; rc=1; }
    grep -qE 'kernel oplocks[[:space:]]*=[[:space:]]*no'  <<< "$out" || { say "kernel oplocks != no"; rc=1; }
    grep -qE 'posix locking[[:space:]]*=[[:space:]]*yes'  <<< "$out" || { say "posix locking != yes"; rc=1; }
    grep -qF "force user = ${SC_FRONT_FORCE_USER}"        <<< "$out" || { say "force user wrong";    rc=1; }
    grep -qF "path = ${SC_BACKEND_MOUNT}"                  <<< "$out" || { say "path wrong";          rc=1; }
    grep -qF "valid users = @\"${SC_FRONT_GROUP}\""        <<< "$out" || { say "valid users wrong";   rc=1; }

    say "testparm -s reports no warnings"
    out=$(ssh_vm 'sudo testparm -s 2>&1 1>/dev/null' || true)
    echo "$out" | head -20
    if grep -qiE 'WARNING|ERROR' <<< "$out"; then
        say "testparm reported warnings/errors"; rc=1
    fi

    say "smbd is listening on 445/tcp on the domain NIC IP ($LAB_VM_IP)"
    out=$(ssh_vm "sudo ss -tnlp 2>/dev/null | grep ':445'" 2>&1 || true)
    echo "$out"
    # Either a wildcard listen (0.0.0.0:445 / *:445) or the domain IP works.
    grep -qE "(0\.0\.0\.0:445|\*:445|${LAB_VM_IP}:445)" <<< "$out" || { say "smbd not listening on 445"; rc=1; }
    # nmbd should NOT be listening on 137/138 — the proxy disables NetBIOS.
    out=$(ssh_vm "sudo ss -unlp 2>/dev/null | grep -E ':(137|138)'" 2>&1 || true)
    if [[ -n "$out" ]]; then
        echo "$out"
        say "nmbd-style NetBIOS sockets are open — should be disabled"; rc=1
    fi

    say "nftables ruleset is loaded with the proxy chains"
    out=$(ssh_vm 'sudo nft list ruleset 2>&1' || true)
    echo "$out" | head -40
    grep -qE 'table (inet|ip) ' <<< "$out" || { say "no nft tables loaded"; rc=1; }

    say "smbclient -k from the proxy itself can list the share"
    # Localhost-from-proxy: same SMB3 + Kerberos path a Windows client
    # would take, just without crossing a network boundary. A future
    # cross-host check from WS2025-DC1 / samba-dc1 belongs in a
    # Verify-FrontendShare.ps1 helper.
    out=$(ssh_vm "sudo bash -c 'echo \"$SC_PASS\" | kinit \"$SC_ADMIN@$SC_REALM_UC\" && smbclient -k -L //$LAB_VM_IP -m SMB3'" 2>&1 || true)
    echo "$out"
    grep -qE "Sharename|Disk\|" <<< "$out" || { say "smbclient -L returned no shares"; rc=1; }
    grep -qF "$SC_FRONT_SHARE" <<< "$out" || { say "advertised share list does not include $SC_FRONT_SHARE"; rc=1; }

    say "deploy.env persisted the frontend coordinates"
    out=$(ssh_vm "sudo grep -E '^FRONT_(SHARE|GROUP|FORCE_USER)=' /var/lib/smbproxy/deploy.env" 2>&1 || true)
    echo "$out"
    grep -qF "FRONT_SHARE=\"${SC_FRONT_SHARE}\""           <<< "$out" || rc=1
    grep -qF "FRONT_GROUP=\"${SC_FRONT_GROUP}\""           <<< "$out" || rc=1
    grep -qF "FRONT_FORCE_USER=\"${SC_FRONT_FORCE_USER}\"" <<< "$out" || rc=1

    return "$rc"
}
