# lab/scenarios/join-domain.sh — join the SMB1<->SMB3 proxy to the
# WS2025 forest the samba-addc-appliance lab already runs (lab.test /
# WS2025-DC1 @ 10.10.10.10) as a member server.
#
# Sourced by lab/run-scenario.sh. Has access to ssh_host / ssh_vm /
# scp_to_vm / say / step helpers and the LAB_HV_* / LAB_VM_* variables.
#
# pre_hook (in order):
#   1. bootstrap_network — assign NIC roles + bring up legacy NIC
#      (sourced from bootstrap-network.sh).
#   2. AD cleanup — remove the smbproxy-1 computer account from
#      WS2025-DC1 so a re-join doesn't hit "object already exists".
#      Respects SC_SKIP_CLEANUP=1 (skip) and SC_DRY_CLEANUP=1
#      (inspect only) the same way the samba sibling's join-dc does.
#
# Overridable via env (run with `SC_REALM=foo ./lab/run-scenario.sh join-domain`):
#   SC_REALM, SC_NETBIOS, SC_DC, SC_PASS, SC_ADMIN

# Pull in bootstrap_network() and its env defaults. We override
# run_scenario / verify below; bootstrap_network() stays available
# for our pre_hook to call.
source "$(dirname "${BASH_SOURCE[0]}")/bootstrap-network.sh"

SC_REALM="${SC_REALM:-lab.test}"
SC_NETBIOS="${SC_NETBIOS:-LAB}"
SC_DC="${SC_DC:-10.10.10.10}"
SC_PASS="${SC_PASS:-P@ssword123456!}"
SC_ADMIN="${SC_ADMIN:-Administrator}"

# Pre-compute upper-case realm once. macOS bash 3.2 doesn't grok ${var^^},
# so keep it portable with tr.
SC_REALM_UC=$(echo "$SC_REALM" | tr '[:lower:]' '[:upper:]')

# Action functions, also called by downstream scenarios
# (frontend-share, end-to-end) that source this file.

do_ad_cleanup_proxy() {
    if [[ "${SC_SKIP_CLEANUP:-0}" == "1" ]]; then
        say "skipping WS2025 cleanup (SC_SKIP_CLEANUP=1)"
        return 0
    fi
    local dry_note=""
    [[ "${SC_DRY_CLEANUP:-0}" == "1" ]] && dry_note=" (dry-run)"
    step "remove smbproxy-1 computer account from WS2025-DC1${dry_note}"
    # A member-server join leaves only the computer account in AD —
    # no NTDS Settings, no replication links, no SYSVOL Policies. The
    # cleanup is correspondingly simpler than the samba sibling's
    # Reset-LabDomainState.ps1.
    if [[ "${SC_DRY_CLEANUP:-0}" == "1" ]]; then
        ssh_host "pwsh -Command \"Get-ADComputer -Identity 'smbproxy-1' -ErrorAction SilentlyContinue | Format-List Name,DistinguishedName,Enabled\""
    else
        ssh_host "pwsh -Command \"Get-ADComputer -Identity 'smbproxy-1' -ErrorAction SilentlyContinue | Remove-ADComputer -Confirm:\\\$false; Write-Host 'cleanup ok'\""
    fi
}

do_join_domain() {
    # Pipe the AD admin password to --pass-stdin so it never appears in
    # ps listings on the VM.
    ssh_vm "echo '$SC_PASS' | sudo smbproxy-sconfig --join-domain \
        --realm '$SC_REALM' --short '$SC_NETBIOS' --dc '$SC_DC' \
        --user '$SC_ADMIN' --pass-stdin"
}

pre_hook() {
    step "bootstrap network (NIC roles + legacy IP)"
    bootstrap_network
    do_ad_cleanup_proxy
}

run_scenario() {
    do_join_domain
}

verify() {
    local rc=0 out

    say "smbproxy-sconfig --status reports joined=yes"
    out=$(ssh_vm 'sudo smbproxy-sconfig --status' 2>&1 || true)
    echo "$out"
    grep -qE '^joined:[[:space:]]+yes' <<< "$out" || { say "--status doesn't show joined=yes"; rc=1; }
    grep -qE "realm:[[:space:]]+${SC_REALM}" <<< "$out" || { say "--status doesn't show realm=$SC_REALM"; rc=1; }

    say "winbind + smbd are active"
    ssh_vm 'sudo systemctl is-active smbd'    || rc=1
    ssh_vm 'sudo systemctl is-active winbind' || rc=1

    say "net ads info reports a live KDC"
    out=$(ssh_vm 'sudo net ads info -P 2>&1' || true)
    echo "$out"
    grep -qiE "Realm:[[:space:]]+${SC_REALM_UC}" <<< "$out" || { say "net ads info realm mismatch"; rc=1; }
    grep -qE "LDAP server name:" <<< "$out" || rc=1

    say "wbinfo reports trust health"
    ssh_vm 'sudo wbinfo -t' || rc=1

    say "wbinfo can enumerate at least Administrator"
    out=$(ssh_vm 'sudo wbinfo -u 2>&1' || true)
    echo "$out" | head -10
    grep -qiE '^(Administrator|administrator)$' <<< "$out" || { say "Administrator not in wbinfo -u"; rc=1; }

    say "kinit + klist work for $SC_ADMIN@$SC_REALM_UC"
    ssh_vm "sudo bash -c 'echo \"$SC_PASS\" | kinit \"$SC_ADMIN@$SC_REALM_UC\"'" || rc=1
    out=$(ssh_vm "sudo klist 2>&1" || true)
    echo "$out"
    grep -qE "krbtgt/${SC_REALM_UC}@${SC_REALM_UC}" <<< "$out" || { say "no krbtgt in cache"; rc=1; }

    say "krb5.conf is no longer the YOURREALM.LAN skeleton"
    out=$(ssh_vm 'sudo cat /etc/krb5.conf' 2>&1 || true)
    if grep -qF 'YOURREALM.LAN' <<< "$out"; then
        say "krb5.conf still has YOURREALM.LAN"; rc=1
    fi
    grep -qiE "default_realm[[:space:]]*=[[:space:]]*${SC_REALM_UC}" <<< "$out" \
        || { say "krb5.conf default_realm != $SC_REALM_UC"; rc=1; }

    say "chrony source is the DC, not a public pool"
    out=$(ssh_vm 'grep -E "^(server|pool) " /etc/chrony/chrony.conf || true' 2>&1 || true)
    echo "$out"
    if grep -qE 'time\.cloudflare|time\.google|debian\.pool' <<< "$out"; then
        say "chrony.conf has a public pool baked in"; rc=1
    fi
    # Allow either the DC IP or its FQDN as an acceptable source.
    if [[ -n "$out" ]] && ! grep -qE "(${SC_DC}\b|WS2025-DC1|dc[0-9]?\.${SC_REALM})" <<< "$out"; then
        say "chrony source is set but doesn't reference the DC ($SC_DC)"; rc=1
    fi

    say "smb.conf reflects the new realm and member-server role"
    out=$(ssh_vm 'sudo grep -E "^\s*(realm|workgroup|security)" /etc/samba/smb.conf' 2>&1 || true)
    echo "$out"
    grep -qiE "realm[[:space:]]*=[[:space:]]*${SC_REALM}" <<< "$out" || { say "smb.conf realm mismatch"; rc=1; }
    grep -qiE "workgroup[[:space:]]*=[[:space:]]*${SC_NETBIOS}" <<< "$out" || { say "smb.conf workgroup mismatch"; rc=1; }
    grep -qiE "security[[:space:]]*=[[:space:]]*ads" <<< "$out" || { say "smb.conf security != ads"; rc=1; }

    say "computer account is visible from WS2025-DC1"
    out=$(ssh_host "pwsh -Command \"Get-ADComputer -Identity 'smbproxy-1' | Format-List Name,DistinguishedName,Enabled\"" 2>&1 || true)
    echo "$out"
    grep -qE 'Name\s*:\s*smbproxy-1' <<< "$out" || { say "computer account not in AD"; rc=1; }

    return "$rc"
}
