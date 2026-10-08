#!/usr/bin/env bash
# Transactional share configuration (code-review session plan 06). Drives the
# real configure_share against real /etc/samba, /etc/fstab and
# /var/lib/smbproxy paths, with fake systemctl/testparm/wbinfo/smbd so
# failures can be injected. Run as root in a DISPOSABLE container:
#
#   docker run --rm -v "$PWD":/src:ro -e DISPOSABLE_ROOT_TEST=1 \
#       debian:trixie bash /src/tests/root/config-transaction.sh

set -euo pipefail
[[ ${EUID} -eq 0 && "${DISPOSABLE_ROOT_TEST:-0}" == 1 ]] || {
    echo "refusing: run as root in a disposable container with DISPOSABLE_ROOT_TEST=1" >&2
    exit 2
}

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

# ---- fakes ------------------------------------------------------------------
mkdir -p "$T/bin" "$T/mods/vfs" /etc/samba /var/lib/smbproxy/shares \
    /usr/share/smbproxy-session-vfs /usr/local/sbin /etc/smbproxy
: > "$T/mods/vfs/smbproxy_session.so"; : > "$T/mods/vfs/fileid.so"
echo '2:4.22.10+dfsg-0+deb13u2' > /usr/share/smbproxy-session-vfs/samba-package-version
install -m 0755 "$SRC/smbproxy-session-mount" /usr/local/sbin/smbproxy-session-mount
printf '#!/bin/sh\nexit 0\n' > /usr/local/sbin/smbproxy-vfs-version-check
chmod 0755 /usr/local/sbin/smbproxy-vfs-version-check
printf 'LEGACY_NIC_NAME="eth1"\nLEGACY_NIC_MAC="00:15:5d:00:00:02"\n' > "$T/roles.env"

# systemctl: FAIL_RELOADS=n makes the next n reload/restart calls fail;
# FAIL_DAEMON_RELOADS=n does the same for daemon-reload.
cat > "$T/bin/systemctl" <<'SH'
#!/usr/bin/env bash
take() { local f="$1" n; n=$(cat "$f" 2>/dev/null || echo 0); (( n > 0 )) || return 1; echo $((n - 1)) > "$f"; }
case "$*" in
    *is-active*smbd*) exit 0 ;;
    *daemon-reload*) take "$FAKE_DIR/daemon-reload-failures" && exit 1; exit 0 ;;
    *reload\ smbd*|*restart\ smbd*)
        take "$FAKE_DIR/reload-failures" && exit 1
        echo "$*" >> "$FAKE_DIR/reloads"; exit 0 ;;
esac
exit 0
SH
cat > "$T/bin/wbinfo" <<'SH'
#!/usr/bin/env bash
# Only the AD group resolves; force-user names never collide with AD.
[[ "$*" == *Accounting* ]] && { echo "S-1-5-21-1-2-3-1105 SID_DOM_GROUP (2)"; exit 0; }
exit 1
SH
printf '#!/bin/sh\nexit 0\n' > "$T/bin/testparm"
printf '#!/bin/sh\necho "   MODULESDIR: %s"\n' "$T/mods" > "$T/bin/smbd"
printf '#!/bin/sh\necho 2:4.22.10+dfsg-0+deb13u2\n' > "$T/bin/dpkg-query"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/smbcontrol"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH" FAKE_DIR="$T" SMBPROXY_ROLES_FILE="$T/roles.env"
export SMBPROXY_ALLOW_NON_ROOT_TEST=1 SMBPROXY_DRAIN_SECONDS=1
export SMBPROXY_SESSION_STATE=/run/smbproxy-test/session-state
export SMBPROXY_SESSION_ROOT=/run/smbproxy-test/sessions
fail_reloads() { echo "$1" > "$T/reload-failures"; }
fail_daemon_reloads() { echo "$1" > "$T/daemon-reload-failures"; }

# shellcheck disable=SC1091
source "$SRC/smbproxy-sconfig.sh"
set +e +u

printf '[global]\n    security = ads\n    workgroup = LAB\n' > /etc/samba/smb.conf
echo '# fstab under test' > /etc/fstab

share_vars() {
    SHARE_NAME="$1" PROFILE="$2" OFFLINE_MODE=direct BACKEND_IP="$3"
    BACKEND_USER=clerk BACKEND_DOMAIN=LEGACY BACKEND_PASS="$4"
    BACKEND_MOUNT="/mnt/backend/$1" FRONT_GROUP='LAB\Accounting'
    FRONT_FORCE_USER=ledgeruser LOCKING_OVERRIDE="" BACKEND_VERS="" BACKEND_SEAL=""
}
fingerprint() {
    sha256sum /etc/samba/.creds-"$1" /var/lib/smbproxy/shares/"$1".env \
        /etc/fstab /etc/samba/smb.conf 2>&1
}
snapshots() { find /run -maxdepth 1 -name 'smbproxy-cfg.*' | wc -l; }

# ---- 1. a new share commits, and the snapshot is discarded ----------------
share_vars Files modern 192.0.2.20 first-secret
configure_share || fail "initial modern configure failed (rc=$?)"
grep -q '^\[Files\]' /etc/samba/smb.conf || fail "section not published"
grep -q ' /mnt/backend/Files cifs ' /etc/fstab || fail "fstab line not written"
grep -q '^password=first-secret$' /etc/samba/.creds-Files || fail "creds not written"
[[ -z "${BACKEND_PASS+set}" ]] || fail "password still set after success"
[[ $(snapshots) -eq 0 ]] || fail "snapshot left behind after success"
pass "new share commits; snapshot discarded; password cleared"

# ---- 2. reload fails, rollback succeeds: previous generation, rc=14 --------
before=$(fingerprint Files)
share_vars Files modern 192.0.2.99 second-secret
fail_reloads 2          # reload and the fallback restart of the new config
rc=0; configure_share || rc=$?
[[ $rc -eq 14 ]] || fail "expected rc=14 after a failed reload, got $rc"
[[ "$(fingerprint Files)" == "$before" ]] || fail "files differ from the previous generation after rollback"
[[ -z "${BACKEND_PASS+set}" ]] || fail "password still set after failure"
[[ $(snapshots) -eq 0 ]] || fail "snapshot left behind after a successful rollback"
grep -q 'rolled back' /var/log/smbproxy-share.log || fail "rollback not logged"
pass "failed reload restores the previous generation byte for byte (rc=14)"

# ---- 3. daemon-reload fails: same rollback ---------------------------------
fail_daemon_reloads 1
share_vars Files modern 192.0.2.98 third-secret
rc=0; configure_share || rc=$?
[[ $rc -eq 14 && "$(fingerprint Files)" == "$before" ]] || fail "daemon-reload failure not rolled back (rc=$rc)"
pass "failed daemon-reload is rolled back (rc=14)"

# ---- 4. a brand-new share that fails leaves no trace -----------------------
share_vars Scans modern 192.0.2.30 scan-secret
fail_reloads 2
rc=0; configure_share || rc=$?
[[ $rc -eq 14 ]] || fail "expected rc=14 for a failed new share, got $rc"
[[ ! -e /etc/samba/.creds-Scans && ! -e /var/lib/smbproxy/shares/Scans.env ]] || fail "failed new share left creds/state"
! grep -q '^\[Scans\]' /etc/samba/smb.conf || fail "failed new share left its section"
! grep -q '/mnt/backend/Scans' /etc/fstab || fail "failed new share left its fstab line"
pass "failed new share leaves no creds, state, section or fstab line"

# ---- 5. legacy: apply and rollback both fail -> withdrawn, snapshot kept ---
share_vars Ledger legacy 192.0.2.40 ledger-secret
configure_share || fail "initial legacy configure failed (rc=$?)"
share_vars Ledger legacy 192.0.2.41 ledger-secret
fail_reloads 4          # the change and the rollback both fail to reload
rc=0; configure_share || rc=$?
[[ $rc -eq 15 ]] || fail "expected rc=15 when rollback also fails, got $rc"
/usr/local/sbin/smbproxy-session-mount withdrawn Ledger || fail "legacy share not withdrawn after double failure"
kept=$(find /run -maxdepth 1 -name 'smbproxy-cfg.*' | head -1)
[[ -n "$kept" && -f "$kept/files" ]] || fail "snapshot not kept for recovery"
[[ "$(stat -c %a "$kept")" == 700 ]] || fail "kept snapshot is not root-only"
grep -qF "$kept" /var/log/smbproxy-share.log || fail "log does not name the kept snapshot"
[[ -z "${BACKEND_PASS+set}" ]] || fail "password still set after double failure"
pass "double failure withdraws the legacy share and keeps a root-only snapshot (rc=15)"

# Recovery: the cause is fixed and the change is re-run.
share_vars Ledger legacy 192.0.2.41 ledger-secret
configure_share || fail "re-run after recovery failed (rc=$?)"
! /usr/local/sbin/smbproxy-session-mount withdrawn Ledger || fail "re-run did not re-admit the share"
pass "re-running the change after recovery commits and re-admits the share"

echo "config transaction tests passed"
