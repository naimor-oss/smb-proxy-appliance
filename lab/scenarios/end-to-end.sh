# shellcheck shell=bash
# lab/scenarios/end-to-end.sh — single-shot release-gate test that
# walks the whole appliance through a green-field deployment:
#
#   bootstrap network → AD cleanup → join lab.test → publish one
#   proxied share via --configure-share + apply firewall → roundtrip
#   access.
#
# Sourced by lab/run-scenario.sh. Has access to ssh_host / ssh_vm /
# scp_to_vm / say / step helpers and the LAB_HV_* / LAB_VM_* variables.
#
# Composes the upstream scenarios. Source order matters —
# frontend-share sources join-domain and backend-mount, which in turn
# source bootstrap-network. All do_* helpers are then in scope here,
# and we just call them sequentially in run_scenario.
#
# Verification: the full frontend-share verify() (renamed before
# redefining, so we can reuse it) plus a per-share status check via
# the new --status output, plus an opt-in legacy SMB1 backend read/write roundtrip
# through the proxy.
#
# Overridable via env (see upstream scenarios for the full list):
#   SC_REALM, SC_NETBIOS, SC_DC, SC_PASS, SC_ADMIN
#   SC_BACKEND_PASS (must be set; see backend-mount.sh)
#   SC_SHARE_NAME (canonical share name — same at both ends)
#   SC_BACKEND_IP/USER/DOMAIN/MOUNT, SC_FORCE_USER, SC_GROUP
#   SC_WRITE_ROUNDTRIP=1     opt-in: write a uniquely-named test file
#                            through the proxy, read it back, delete.
#                            Off by default to keep the shared legacy SMB1 backend
#                            backend strictly read-only during tests.

source "$(dirname "${BASH_SOURCE[0]}")/frontend-share.sh"

# Capture the upstream verify() before we redefine our own, so we can
# call it as part of the end-to-end check. The eval/declare/sed dance
# is the standard bash idiom for "rename a function".
eval "$(declare -f verify | sed '1s/^verify/_frontend_verify/')"

pre_hook() {
    step "bootstrap network (NIC roles + legacy IP)"
    bootstrap_network
    do_ad_cleanup_proxy
    require_backend_pass
}

run_scenario() {
    step "1/3 join domain ($SC_REALM via $SC_DC)"
    do_join_domain

    step "2/3 configure proxied share [$SC_SHARE_NAME] (backend + frontend)"
    do_configure_backend

    step "3/3 apply nftables ruleset"
    do_apply_firewall
}

verify() {
    local rc=0

    step "frontend verification (smb.conf, testparm, ss, nft, smbclient -L)"
    _frontend_verify || rc=1

    say "smbproxy-sconfig --status reflects fully provisioned state"
    local out
    out=$(ssh_vm 'sudo smbproxy-sconfig --status' 2>&1 || true)
    echo "$out"
    grep -qE '^joined:[[:space:]]+yes'                 <<< "$out" || rc=1
    grep -qE '^smbd:[[:space:]]+(active|running)'      <<< "$out" || rc=1
    grep -qE '^winbind:[[:space:]]+(active|running)'   <<< "$out" || rc=1
    # Per-share section in --status output: confirms our share is
    # listed AND its mount is active AND its smb.conf section is present.
    grep -qF "  - ${SC_SHARE_NAME}"                    <<< "$out" || { say "--status missing share entry"; rc=1; }
    grep -qE "active=yes"                              <<< "$out" || { say "--status missing active=yes"; rc=1; }
    grep -qE "smb_section:[[:space:]]+yes"             <<< "$out" || { say "--status missing smb_section:yes"; rc=1; }

    say "backend mount path is readable through the proxy's local view"
    out=$(ssh_vm "sudo ls '$SC_BACKEND_MOUNT' 2>&1 | head -10" || true)
    echo "$out"
    if grep -qiE 'permission denied|i/o error|cannot access' <<< "$out"; then
        say "backend mount is up but not readable"; rc=1
    fi

    if [[ "${SC_WRITE_ROUNDTRIP:-0}" == "1" ]]; then
        say "legacy SMB1 backend write roundtrip (opt-in via SC_WRITE_ROUNDTRIP=1)"
        # Unique filename so concurrent runs don't collide and so it's
        # obviously a test artifact if cleanup is interrupted. The proxy
        # mount uses uid=$SC_FORCE_USER so writes go out as that user.
        local probe=".smb-proxy-roundtrip-$(date -u +%Y%m%dT%H%M%SZ)-$$.tmp"
        out=$(ssh_vm "sudo bash -c '
            set -e
            f=\"$SC_BACKEND_MOUNT/$probe\"
            echo proxy-end-to-end-marker > \"\$f\"
            cat \"\$f\"
            rm -f \"\$f\"
            echo OK
        '" 2>&1 || true)
        echo "$out"
        grep -qE '^OK$' <<< "$out" || { say "write roundtrip did not complete"; rc=1; }
    else
        say "legacy SMB1 backend write roundtrip skipped (set SC_WRITE_ROUNDTRIP=1 to enable)"
    fi

    return "$rc"
}
