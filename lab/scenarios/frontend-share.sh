# shellcheck shell=bash
# lab/scenarios/frontend-share.sh — publish ONE proxied share end to
# end via `smbproxy-sconfig --configure-share` WITH --group, then
# apply the firewall. Verifies the smb.conf section has the strict-
# locking semantics required by .TPS files, that smbd is listening on
# 445/tcp, and that an SMB3 + Kerberos client can list the share.
#
# With the multi-share refactor (B1-B3) the appliance no longer has
# separate "configure backend" and "configure frontend" steps — one
# `--configure-share --group ...` does both in one shot. This scenario
# is now a thin wrapper over backend-mount.sh that sets SC_GROUP so
# the underlying do_configure_backend() also publishes the smb.conf
# section.
#
# Sourced by lab/run-scenario.sh. Has access to ssh_host / ssh_vm /
# scp_to_vm / say / step helpers and the LAB_HV_* / LAB_VM_* variables.
#
# pre_hook (in order, each idempotent):
#   1. bootstrap_network          (NIC roles + legacy IP)
#   2. do_ad_cleanup_proxy        (remove smbproxy-1 from AD)
#   3. require_backend_pass       (fail fast if SC_BACKEND_PASS unset)
#   4. do_join_domain             (smbproxy-sconfig --join-domain)
#
# run_scenario:
#   - smbproxy-sconfig --configure-share (with --group)
#   - smbproxy-sconfig --apply-firewall
#
# Verification covers smb.conf locking semantics, testparm cleanliness,
# smbd listening on 445/tcp of the domain NIC, and a Kerberos-
# authenticated smbclient -k roundtrip from the proxy itself (a true
# cross-host SMB3 test from samba-dc1 or WS2025-DC1 belongs in a
# future Verify-FrontendShare.ps1 helper).
#
# Overridable via env (defaults track the sketch + lab.test):
#   SC_GROUP   default LAB\Domain Users  (zero-setup choice; every joined user)
# Plus everything inherited from join-domain.sh and backend-mount.sh
# (SC_SHARE_NAME, SC_BACKEND_*, SC_FORCE_USER, SC_REALM, SC_PASS, ...).

source "$(dirname "${BASH_SOURCE[0]}")/join-domain.sh"
source "$(dirname "${BASH_SOURCE[0]}")/backend-mount.sh"

# Setting SC_GROUP makes backend-mount.sh's do_configure_backend()
# pass --group through to --configure-share, which in turn writes
# the per-share smb.conf section.
SC_GROUP="${SC_GROUP:-LAB\\Domain Users}"

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
}

run_scenario() {
    step "configure share [$SC_SHARE_NAME] (backend + frontend)"
    do_configure_backend

    step "apply nftables ruleset"
    do_apply_firewall
}

verify() {
    local rc=0 out
    local safe; safe=$(sanitize "$SC_SHARE_NAME")
    local state="/var/lib/smbproxy/shares/${safe}.env"

    say "smb.conf has the [$SC_SHARE_NAME] section"
    out=$(ssh_vm "sudo grep -n \"^\\[$SC_SHARE_NAME\\]\" /etc/samba/smb.conf" 2>&1 || true)
    echo "$out"
    [[ -n "$out" ]] || { say "share section missing"; rc=1; }

    say "share has the strict-locking + oplocks-off + force-user stanza"
    # Extract only the [share] block so the param greps below can't
    # match a same-named directive in another section.
    out=$(ssh_vm "sudo awk -v s='[$SC_SHARE_NAME]' 'BEGIN{p=0} \$0==s{p=1; print; next} /^\\[/{p=0} p' /etc/samba/smb.conf" 2>&1 || true)
    echo "$out"
    grep -qE 'oplocks[[:space:]]*=[[:space:]]*no'         <<< "$out" || { say "oplocks != no";        rc=1; }
    grep -qE 'level2 oplocks[[:space:]]*=[[:space:]]*no'  <<< "$out" || { say "level2 oplocks != no"; rc=1; }
    grep -qE 'strict locking[[:space:]]*=[[:space:]]*yes' <<< "$out" || { say "strict locking != yes"; rc=1; }
    grep -qE 'kernel oplocks[[:space:]]*=[[:space:]]*no'  <<< "$out" || { say "kernel oplocks != no"; rc=1; }
    grep -qE 'posix locking[[:space:]]*=[[:space:]]*yes'  <<< "$out" || { say "posix locking != yes"; rc=1; }
    grep -qF "path = ${SC_BACKEND_MOUNT}"                  <<< "$out" || { say "path wrong";          rc=1; }
    # force user / force group are written as the LOCAL username
    # (NOT a numeric UID — Samba resolves these via getpwnam(), and
    # numeric strings don't resolve there even though getpwuid()
    # would). The default-domain ambiguity defense lives elsewhere:
    #   1. NSS files-first ordering on the appliance (passwd: files winbind)
    #      so the local account always wins over a same-named AD one.
    #   2. AD-collision check at configure_share write time.
    # valid users stays as a SID for an unrelated ambiguity defense
    # (winbind use default domain = yes parsing quirk).
    grep -qE '^[[:space:]]*force user[[:space:]]*=[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*$'  <<< "$out" \
        || { say "force user not a username";  rc=1; }
    grep -qE '^[[:space:]]*force group[[:space:]]*=[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*$' <<< "$out" \
        || { say "force group not a username"; rc=1; }
    # Belt-and-suspenders: assert numeric force user is REJECTED.
    # The previous numeric form would silently break tree-connect.
    grep -qE '^[[:space:]]*force user[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$' <<< "$out" \
        && { say "force user is numeric (Samba getpwnam() would fail)"; rc=1; }
    grep -qE '^[[:space:]]*valid users[[:space:]]*=[[:space:]]*S-1-' <<< "$out" \
        || { say "valid users not a SID"; rc=1; }

    # Cross-check that the username smb.conf names matches the saved
    # FRONT_FORCE_USER state and that /etc/passwd (files-only, the
    # configured NSS source) resolves it to a real UID. Catches a
    # stale section pointing at an account that's been removed.
    local fu_user_smb fu_uid_file
    fu_user_smb=$(grep -oE 'force user[[:space:]]*=[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*' <<< "$out" \
        | sed -E 's/^force user[[:space:]]*=[[:space:]]*//' | head -1)
    if [[ -n "$fu_user_smb" && "$fu_user_smb" != "${SC_FORCE_USER}" ]]; then
        say "force user '$fu_user_smb' in smb.conf does not match SC_FORCE_USER '${SC_FORCE_USER}'"; rc=1
    fi
    if [[ -n "$fu_user_smb" ]]; then
        fu_uid_file=$(ssh_vm "awk -F: -v u='${fu_user_smb}' '\$1==u {print \$3; exit}' /etc/passwd" 2>&1 || true)
        if [[ -z "$fu_uid_file" ]]; then
            say "force user '$fu_user_smb' has no /etc/passwd entry on the proxy"; rc=1
        fi
    fi
    # Cross-check that the SID in valid users resolves back to the
    # AD group the operator named.
    local sid_in_smb sid_resolved
    sid_in_smb=$(grep -oE 'valid users[[:space:]]*=[[:space:]]*S-1-[0-9-]+' <<< "$out" | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}')
    if [[ -n "$sid_in_smb" ]]; then
        sid_resolved=$(ssh_vm "sudo wbinfo --sid-to-name='$sid_in_smb' 2>/dev/null | awk '{print \$1}'" || true)
        if [[ -n "$sid_resolved" ]] && ! grep -qiF "${SC_GROUP##*\\\\}" <<< "$sid_resolved"; then
            say "SID $sid_in_smb resolved to '$sid_resolved' which does not look like ${SC_GROUP}"
            rc=1
        fi
    fi

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
    grep -qF "$SC_SHARE_NAME" <<< "$out" || { say "advertised share list does not include $SC_SHARE_NAME"; rc=1; }

    say "per-share state file persisted the frontend coordinates"
    out=$(ssh_vm "sudo cat '$state'" 2>&1 || true)
    echo "$out"
    grep -qF "SHARE_NAME=\"${SC_SHARE_NAME}\""   <<< "$out" || { say "SHARE_NAME wrong"; rc=1; }
    grep -qF "FRONT_GROUP=\"${SC_GROUP}\""        <<< "$out" || { say "FRONT_GROUP wrong"; rc=1; }
    grep -qF "FRONT_FORCE_USER=\"${SC_FORCE_USER}\"" <<< "$out" || { say "FRONT_FORCE_USER wrong"; rc=1; }

    # End-to-end coverage of the --check-share diagnostic. After a
    # successful configure_share + apply_firewall, --check-share for
    # this share MUST return rc=0 (everything aligned). Catches a
    # whole class of "configure_share said OK but the live state
    # diverged" bugs that no individual assertion above would notice.
    say "smbproxy-sconfig --check-share reports clean for this share"
    out=$(ssh_vm "sudo smbproxy-sconfig --check-share --name '${SC_SHARE_NAME}'" 2>&1)
    check_rc=$?
    echo "$out"
    if [[ "$check_rc" -ne 0 ]]; then
        say "  --check-share returned rc=${check_rc} on a freshly-configured share"
        rc=1
    fi
    # Also assert --check-share for a non-existent share returns rc=3
    # — the documented "no such share" code. Cheap regression test for
    # the CLI exit-code contract.
    ssh_vm "sudo smbproxy-sconfig --check-share --name '__definitely_not_a_share__'" >/dev/null 2>&1
    check_missing_rc=$?
    if [[ "$check_missing_rc" -ne 3 ]]; then
        say "  --check-share for missing share returned rc=${check_missing_rc} (expected 3)"
        rc=1
    fi

    # AD-name-collision is now a REFUSAL (rc=9) at configure time, so
    # there is no "WARN + local-shadow-user + UID-comparison" branch
    # to exercise here — the configure_share short-circuit prevents
    # any of those artifacts from existing for a colliding name. The
    # negative path lives in lab/scenarios/collision-refused.sh,
    # which asserts rc=9 and verifies no creds/fstab/smb.conf/share-
    # state/passwd entries leaked from the refused attempt. This
    # scenario only exercises ACCEPT paths (default profile +
    # adversarial-positive); a colliding force-user under those
    # profiles would itself be a misconfiguration, not a regression.

    return "$rc"
}
