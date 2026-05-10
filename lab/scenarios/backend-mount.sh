# shellcheck shell=bash
# lab/scenarios/backend-mount.sh — configure ONE proxied share's
# backend half via `smbproxy-sconfig --configure-share` (without
# --group, so smb.conf is not touched), and verify the cifs mount
# comes up with the locking-correct options (vers=1.0, nobrl,
# cache=none, serverino).
#
# Sourced by lab/run-scenario.sh. Has access to ssh_host / ssh_vm /
# scp_to_vm / say / step helpers and the LAB_HV_* / LAB_VM_* variables.
#
# pre_hook: bootstrap_network — assigns NIC roles and brings up the
# legacy NIC IP. Backend mount is independent of AD join (cifs uses
# username/password creds, not Kerberos), so this scenario does not
# require the proxy to be domain-joined and deliberately omits
# --group from --configure-share to test that "backend-only" path.
#
# Backend credentials handling:
#   - SC_BACKEND_PASS must be set in the runner's environment.
#   - lab/run-scenario.sh sources lab/backend-creds.env (gitignored
#     by *creds* in .gitignore) before running, so dropping a
#     `SC_BACKEND_PASS='...'` line into that file is the recommended
#     local workflow.
#   - This scenario file MUST NOT contain the password. The sketch
#     in docs/sketch-smb1-smb3-proxy.sh has the original placeholder.
#
# Overridable via env (defaults track the sketch):
#   SC_SHARE_NAME         the canonical share name (used at both ends)
#   SC_BACKEND_IP, SC_BACKEND_USER, SC_BACKEND_DOMAIN, SC_BACKEND_MOUNT
#   SC_FORCE_USER         local Linux account; defaults to SC_BACKEND_USER
#   SC_BACKEND_PASS       cifs password (required, not defaulted here)

source "$(dirname "${BASH_SOURCE[0]}")/bootstrap-network.sh"

SC_SHARE_NAME="${SC_SHARE_NAME:-Engineering\$}"
SC_BACKEND_IP="${SC_BACKEND_IP:-172.29.137.1}"
SC_BACKEND_USER="${SC_BACKEND_USER:-engineering_user}"
SC_BACKEND_DOMAIN="${SC_BACKEND_DOMAIN:-LEGACY}"
SC_BACKEND_MOUNT="${SC_BACKEND_MOUNT:-/mnt/legacy/Engineering_}"
SC_FORCE_USER="${SC_FORCE_USER:-engineering_user}"

# Safe-name derivation matching share_safe_name() in smbproxy-sconfig.
# Used to predict the on-disk creds file path for the verify checks.
sanitize() { printf '%s' "${1//[^A-Za-z0-9_]/_}"; }

require_backend_pass() {
    if [[ -z "${SC_BACKEND_PASS:-}" ]]; then
        say "ERROR: SC_BACKEND_PASS is unset"
        say "  Drop  SC_BACKEND_PASS='...'  into lab/backend-creds.env (gitignored),"
        say "  or pass --backend-creds /some/other/file to lab/run-scenario.sh."
        say "  See docs/sketch-smb1-smb3-proxy.sh for the original legacy SMB1 backend credential."
        return 1
    fi
}

# Action function — also called by downstream scenarios (frontend-share,
# end-to-end, multi-share) that source this file. Configures the
# backend half WITHOUT publishing the smb.conf section (no --group).
# Override SC_GROUP from a downstream scenario to also publish.
do_configure_backend() {
    local extra=""
    if [[ -n "${SC_GROUP:-}" ]]; then
        # Pass --group through too — used by frontend-share / end-to-end /
        # multi-share scenarios that want a fully-published share rather
        # than just the cifs mount.
        extra="--group '$SC_GROUP'"
    fi
    # SC_SHARE_NAME may contain a literal '$' (e.g. Engineering$). Quote
    # everything single so the local shell doesn't expand it before ssh;
    # ssh_vm wraps the whole thing in another layer of quoting.
    # shellcheck disable=SC2086
    ssh_vm "echo '$SC_BACKEND_PASS' | sudo smbproxy-sconfig --configure-share \
        --name '$SC_SHARE_NAME' \
        --backend-ip '$SC_BACKEND_IP' \
        --backend-user '$SC_BACKEND_USER' \
        --backend-domain '$SC_BACKEND_DOMAIN' \
        --mount '$SC_BACKEND_MOUNT' \
        --force-user '$SC_FORCE_USER' \
        $extra \
        --pass-stdin"

    say "trigger automount by accessing the mount point"
    # The fstab entry uses x-systemd.automount; touching the mount path
    # fires the automount unit and brings the cifs mount up. Tolerate
    # the first access taking a moment.
    ssh_vm "sudo bash -c 'ls $SC_BACKEND_MOUNT >/dev/null 2>&1 || sleep 2; ls $SC_BACKEND_MOUNT'" || true
}

pre_hook() {
    step "bootstrap network (NIC roles + legacy IP)"
    bootstrap_network
    require_backend_pass
}

run_scenario() {
    do_configure_backend
}

verify() {
    local rc=0 out
    local safe; safe=$(sanitize "$SC_SHARE_NAME")
    local creds="/etc/samba/.creds-${safe}"
    local state="/var/lib/smbproxy/shares/${safe}.env"

    say "creds file is mode 0600 root:root and contains the right username/domain"
    out=$(ssh_vm "sudo stat -c '%a %U %G' '$creds'" 2>&1 || true)
    echo "$out"
    grep -qE '^600 root root' <<< "$out" || { say "wrong perms on $creds"; rc=1; }
    # Inspect the file's username/domain lines but NEVER print the password.
    out=$(ssh_vm "sudo grep -E '^(username|domain)=' '$creds'" 2>&1 || true)
    echo "$out"
    grep -qF "username=${SC_BACKEND_USER}" <<< "$out" || { say "creds username wrong"; rc=1; }
    grep -qF "domain=${SC_BACKEND_DOMAIN}"  <<< "$out" || { say "creds domain wrong"; rc=1; }

    say "fstab line was written with the locking-correct options"
    out=$(ssh_vm "sudo grep -F ' ${SC_BACKEND_MOUNT} cifs ' /etc/fstab" 2>&1 || true)
    echo "$out"
    grep -qF "vers=1.0"     <<< "$out" || { say "fstab missing vers=1.0";    rc=1; }
    grep -qF "nobrl"        <<< "$out" || { say "fstab missing nobrl";       rc=1; }
    grep -qF "cache=none"   <<< "$out" || { say "fstab missing cache=none";  rc=1; }
    grep -qF "serverino"    <<< "$out" || { say "fstab missing serverino";   rc=1; }
    # nosharesock forces a separate TCP/SMB session per cifs mount so
    # multi-share configs against the same backend don't multiplex onto
    # one session and reuse the first share's creds. Hit on production
    # 2026-05-05 — non-optional.
    grep -qF "nosharesock"  <<< "$out" || { say "fstab missing nosharesock"; rc=1; }
    grep -qF "x-systemd.automount" <<< "$out" || { say "fstab missing automount"; rc=1; }
    grep -qF "credentials=${creds}" <<< "$out" || { say "fstab points at the wrong creds file"; rc=1; }
    # Numeric uid=/gid= in the fstab line — the configure_share rewrite
    # resolves to the LOCAL /etc/passwd UID at config time so the
    # "winbind use default domain = yes" NSS-name ambiguity can't
    # silently steer the mount at an AD account by the same name.
    grep -qE 'uid=[0-9]+,gid=[0-9]+' <<< "$out" || { say "fstab uid=/gid= not numeric"; rc=1; }

    say "force-user account exists with nologin shell"
    out=$(ssh_vm "getent passwd '$SC_FORCE_USER'" 2>&1 || true)
    echo "$out"
    grep -qE ':/usr/sbin/nologin$' <<< "$out" || { say "$SC_FORCE_USER missing or has a login shell"; rc=1; }

    say "cifs mount is live with vers=1.0, nobrl, cache=none, serverino, nosharesock"
    out=$(ssh_vm 'mount | grep "type cifs "' 2>&1 || true)
    echo "$out"
    grep -qF " on ${SC_BACKEND_MOUNT} " <<< "$out" || { say "no cifs mount at ${SC_BACKEND_MOUNT}"; rc=1; }
    grep -qE 'vers=1\.0' <<< "$out" || { say "live mount not vers=1.0"; rc=1; }
    grep -qF "nobrl"     <<< "$out" || { say "live mount missing nobrl"; rc=1; }
    grep -qF "cache=none" <<< "$out" || { say "live mount missing cache=none"; rc=1; }
    # The kernel tends to print this as `nosharesock` in /proc/mounts.
    grep -qF "nosharesock" <<< "$out" || { say "live mount missing nosharesock"; rc=1; }

    say "mount point is readable and contains at least one entry"
    out=$(ssh_vm "sudo ls '$SC_BACKEND_MOUNT' 2>&1 | head -10" || true)
    echo "$out"
    if grep -qiE 'permission denied|i/o error|cannot access|no such file' <<< "$out"; then
        say "ls reported an error — mount is up but not readable"; rc=1
    fi
    if [[ -z "$out" ]]; then
        say "  warning: mount is empty (legitimate for a fresh share, suspicious otherwise)"
    fi

    say "smbstatus shows no remote leases for the cifs mount"
    # The proxy itself doesn't run smbd on the backend side; smbstatus
    # is from the *Samba* point of view (frontend). At this stage smbd
    # may not even be running yet — that's fine. We only run smbstatus
    # if smbd is active so the test isn't noisy.
    if ssh_vm 'sudo systemctl is-active --quiet smbd' 2>/dev/null; then
        ssh_vm 'sudo smbstatus -L 2>&1 | head -20' || true
    else
        say "  smbd not running yet (frontend-share scenario starts it); skipping smbstatus"
    fi

    say "per-share state file persisted the backend coordinates"
    out=$(ssh_vm "sudo cat '$state'" 2>&1 || true)
    echo "$out"
    grep -qF "SHARE_NAME=\"${SC_SHARE_NAME}\""       <<< "$out" || { say "SHARE_NAME wrong"; rc=1; }
    grep -qF "BACKEND_IP=\"${SC_BACKEND_IP}\""       <<< "$out" || { say "BACKEND_IP wrong"; rc=1; }
    grep -qF "BACKEND_USER=\"${SC_BACKEND_USER}\""   <<< "$out" || { say "BACKEND_USER wrong"; rc=1; }
    grep -qF "BACKEND_MOUNT=\"${SC_BACKEND_MOUNT}\"" <<< "$out" || { say "BACKEND_MOUNT wrong"; rc=1; }

    return "$rc"
}
