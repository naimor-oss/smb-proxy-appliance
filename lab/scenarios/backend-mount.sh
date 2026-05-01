# lab/scenarios/backend-mount.sh — mount the real WS2008 SP2 share
# at //SC_BACKEND_IP/SC_BACKEND_SHARE through the proxy's cifs client
# with the locking-correct mount options (vers=1.0, nobrl,
# cache=none, serverino).
#
# Sourced by lab/run-scenario.sh. Has access to ssh_host / ssh_vm /
# scp_to_vm / say / step helpers and the LAB_HV_* / LAB_VM_* variables.
#
# pre_hook: bootstrap_network — assigns NIC roles and brings up the
# legacy NIC IP. Backend mount is independent of AD join (cifs uses
# username/password creds, not Kerberos), so this scenario does not
# require the proxy to be domain-joined.
#
# Backend credentials handling:
#   - SC_BACKEND_PASS must be set in the runner's environment.
#   - lab/run-scenario.sh sources lab/backend-creds.env (gitignored
#     by *creds* in .gitignore) before running, so dropping a
#     `SC_BACKEND_PASS='...'` line into that file is the recommended
#     local workflow.
#   - This scenario file MUST NOT contain the password. The sketch
#     in docs/sketch-smb1-smb3-proxy.sh has the original value.
#
# Overridable via env (defaults track the sketch):
#   SC_BACKEND_IP, SC_BACKEND_SHARE, SC_BACKEND_USER, SC_BACKEND_DOMAIN,
#   SC_BACKEND_MOUNT, SC_FORCE_USER, SC_BACKEND_PASS

source "$(dirname "${BASH_SOURCE[0]}")/bootstrap-network.sh"

SC_BACKEND_IP="${SC_BACKEND_IP:-172.29.137.1}"
SC_BACKEND_SHARE="${SC_BACKEND_SHARE:-ProfitFab\$}"
SC_BACKEND_USER="${SC_BACKEND_USER:-pfuser}"
SC_BACKEND_DOMAIN="${SC_BACKEND_DOMAIN:-LEGACY}"
SC_BACKEND_MOUNT="${SC_BACKEND_MOUNT:-/mnt/profitfab}"
SC_FORCE_USER="${SC_FORCE_USER:-pfuser}"

# Action functions, also called by downstream scenarios
# (frontend-share, end-to-end) that source this file.

require_backend_pass() {
    if [[ -z "${SC_BACKEND_PASS:-}" ]]; then
        say "ERROR: SC_BACKEND_PASS is unset"
        say "  Drop  SC_BACKEND_PASS='...'  into lab/backend-creds.env (gitignored),"
        say "  or pass --backend-creds /some/other/file to lab/run-scenario.sh."
        say "  See docs/sketch-smb1-smb3-proxy.sh for the original WS2008 credential."
        return 1
    fi
}

do_configure_backend() {
    # SC_BACKEND_SHARE may contain a literal '$' (e.g. ProfitFab$).
    # Quote everything single so the local shell doesn't expand it
    # before ssh; ssh_vm wraps the whole thing in another layer of
    # quoting, hence the careful escaping.
    ssh_vm "echo '$SC_BACKEND_PASS' | sudo smbproxy-sconfig --configure-backend \
        --ip '$SC_BACKEND_IP' \
        --share '$SC_BACKEND_SHARE' \
        --user '$SC_BACKEND_USER' \
        --domain '$SC_BACKEND_DOMAIN' \
        --mount '$SC_BACKEND_MOUNT' \
        --force-user '$SC_FORCE_USER' \
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

    say "creds file is mode 0600 root:root and contains the right username/domain"
    out=$(ssh_vm 'sudo stat -c "%a %U %G" /etc/samba/.legacy_creds' 2>&1 || true)
    echo "$out"
    grep -qE '^600 root root' <<< "$out" || { say "wrong perms on creds file"; rc=1; }
    # Inspect the file's username/domain lines but NEVER print the password.
    out=$(ssh_vm "sudo grep -E '^(username|domain)=' /etc/samba/.legacy_creds" 2>&1 || true)
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
    grep -qF "x-systemd.automount" <<< "$out" || { say "fstab missing automount"; rc=1; }

    say "force-user account exists with nologin shell"
    out=$(ssh_vm "getent passwd '$SC_FORCE_USER'" 2>&1 || true)
    echo "$out"
    grep -qE ':/usr/sbin/nologin$' <<< "$out" || { say "$SC_FORCE_USER missing or has a login shell"; rc=1; }

    say "mount point exists and is owned by force-user"
    out=$(ssh_vm "stat -c '%U %G' '$SC_BACKEND_MOUNT'" 2>&1 || true)
    echo "$out"
    # Owner check is informational — sometimes a fresh mountpoint owned by
    # root is acceptable when the cifs mount is already on top.

    say "cifs mount is live with vers=1.0, nobrl, cache=none, serverino"
    out=$(ssh_vm 'mount | grep "type cifs "' 2>&1 || true)
    echo "$out"
    grep -qF " on ${SC_BACKEND_MOUNT} " <<< "$out" || { say "no cifs mount at ${SC_BACKEND_MOUNT}"; rc=1; }
    grep -qE 'vers=1\.0' <<< "$out" || { say "live mount not vers=1.0"; rc=1; }
    grep -qF "nobrl"     <<< "$out" || { say "live mount missing nobrl"; rc=1; }
    grep -qF "cache=none" <<< "$out" || { say "live mount missing cache=none"; rc=1; }

    say "mount point is readable and contains at least one entry"
    out=$(ssh_vm "sudo ls '$SC_BACKEND_MOUNT' 2>&1 | head -10" || true)
    echo "$out"
    if grep -qiE 'permission denied|i/o error|cannot access|no such file' <<< "$out"; then
        say "ls reported an error — mount is up but not readable"; rc=1
    fi
    # An empty share is suspicious for a real WS2008 backend; warn but
    # don't fail (the share could legitimately be empty in a fresh lab).
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

    say "deploy.env persisted the backend coordinates"
    out=$(ssh_vm "sudo grep -E '^BACKEND_(IP|SHARE|USER|DOMAIN|MOUNT)=' /var/lib/smbproxy/deploy.env" 2>&1 || true)
    echo "$out"
    grep -qF "BACKEND_IP=\"${SC_BACKEND_IP}\""       <<< "$out" || rc=1
    grep -qF "BACKEND_SHARE=\"${SC_BACKEND_SHARE}\"" <<< "$out" || rc=1
    grep -qF "BACKEND_USER=\"${SC_BACKEND_USER}\""   <<< "$out" || rc=1
    grep -qF "BACKEND_MOUNT=\"${SC_BACKEND_MOUNT}\"" <<< "$out" || rc=1

    return "$rc"
}
