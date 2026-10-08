#!/usr/bin/env bash
# Share lifecycle integration test (code-review session plan 02). Drives the
# real remove_share / share_requires_drain from smbproxy-sconfig.sh and the
# real session helper against the real /var/lib/smbproxy and /etc/samba
# paths, so it must run as root in a DISPOSABLE container:
#
#   docker run --rm -v "$PWD":/src:ro -e DISPOSABLE_ROOT_TEST=1 \
#       debian:trixie bash /src/tests/root/share-lifecycle.sh
#
# smbd/smbcontrol/systemctl and mount/umount are fakes; no network.

set -euo pipefail
[[ ${EUID} -eq 0 && "${DISPOSABLE_ROOT_TEST:-0}" == 1 ]] || {
    echo "refusing: run as root in a disposable container with DISPOSABLE_ROOT_TEST=1" >&2
    exit 2
}

SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

# ---- fixtures -------------------------------------------------------------
install -m 0755 "$SRC/smbproxy-session-mount" /usr/local/sbin/smbproxy-session-mount
mkdir -p "$T/bin" /var/lib/smbproxy/shares /etc/samba /run/lock
: > "$T/proc-mounts"
cat > "$T/bin/mount" <<'SH'
#!/usr/bin/env bash
printf '%s %s cifs %s 0 0\n' "$3" "$4" "$6" >> "$SMBPROXY_PROC_MOUNTS"
SH
cat > "$T/bin/umount" <<'SH'
#!/usr/bin/env bash
[[ -e "$FAKE_UMOUNT_FAIL" ]] && exit 32
awk -v mp="$1" '$2 != mp' "$SMBPROXY_PROC_MOUNTS" > "$SMBPROXY_PROC_MOUNTS.new"
mv "$SMBPROXY_PROC_MOUNTS.new" "$SMBPROXY_PROC_MOUNTS"
SH
# close-share: a well-behaved smbd disconnects the share's trees, which runs
# the VFS disconnect hook for each recorded session.
cat > "$T/bin/smbcontrol" <<'SH'
#!/usr/bin/env bash
[[ "$2" == close-share ]] || exit 0
[[ -e "$FAKE_STUCK_CLIENT" ]] && exit 0
for rec in /run/smbproxy-test/session-state/*.env; do
    [[ -e "$rec" ]] || continue
    k=$(basename "$rec" .env); IFS=- read -r pid vuid cnum <<< "$k"
    /usr/local/sbin/smbproxy-session-mount disconnect "$3" "$pid" "$vuid" "$cnum" || true
done
SH
# systemctl: "is-active smbd" true; "reload smbd" can be paused on a gate.
cat > "$T/bin/systemctl" <<'SH'
#!/usr/bin/env bash
case "$*" in
    *is-active*smbd*) exit 0 ;;
esac
exit 0
SH
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
export SMBPROXY_ALLOW_NON_ROOT_TEST=1
export SMBPROXY_PROC_MOUNTS="$T/proc-mounts"
export SMBPROXY_MOUNT_BIN="$T/bin/mount" SMBPROXY_UMOUNT_BIN="$T/bin/umount"
export SMBPROXY_SESSION_ROOT=/run/smbproxy-test/sessions
export SMBPROXY_SESSION_STATE=/run/smbproxy-test/session-state
export SMBPROXY_SESSION_LOG="$T/session.log"
export SMBPROXY_DRAIN_SECONDS=2
export FAKE_UMOUNT_FAIL="$T/umount-fail" FAKE_STUCK_CLIENT="$T/stuck"

# Library mode: the entry-point guard skips the TUI when sourced.
# shellcheck disable=SC1091
source "$SRC/smbproxy-sconfig.sh"
set +e +u   # the configurator tolerates unset/non-zero internally
H=/usr/local/sbin/smbproxy-session-mount

seed_share() {
    cat > /var/lib/smbproxy/shares/Ledger.env <<'ENV'
SHARE_NAME="Ledger"
PROFILE="legacy"
OFFLINE_MODE="direct"
BACKEND_IP="192.0.2.10"
BACKEND_USER="clerk"
BACKEND_DOMAIN="LEGACY"
BACKEND_MOUNT="/mnt/legacy/Ledger"
FRONT_GROUP="LAB\Accounting"
FRONT_FORCE_USER="root"
ENV
    printf 'username=clerk\npassword=old-secret\ndomain=LEGACY\n' > /etc/samba/.creds-Ledger
    chmod 0600 /etc/samba/.creds-Ledger
    printf '[global]\n    security = ads\n\n[Ledger]\n    path = /srv/x\n' > /etc/samba/smb.conf
}
session_count() { ls /run/smbproxy-test/session-state/*.env 2>/dev/null | wc -l; }

# ---- 1. removal paused after drain: a new connect must be refused ----------
# The periodic health worker holds the worker lock routinely. A removal that
# has drained the share's sessions then waits for that lock while the share
# is still configured: exactly the window in which a new client used to get a
# fresh upstream SMB1 session whose credentials were then deleted.
seed_share
"$H" connect Ledger 11 1 1 || fail "baseline connect"
( exec 7>/run/lock/smbproxy-share-worker.lock; flock -x 7; : > "$T/held"
  while [[ ! -e "$T/release" ]]; do sleep 0.1; done ) &
holder=$!
for _ in $(seq 1 50); do [[ -e "$T/held" ]] && break; sleep 0.1; done
remove_share Ledger > "$T/remove.out" 2>&1 &
rm_pid=$!
for _ in $(seq 1 100); do [[ $(session_count) -eq 0 ]] && break; sleep 0.1; done
[[ $(session_count) -eq 0 ]] || fail "existing session not drained"
sleep 0.5   # removal is now blocked on the worker lock
kill -0 "$rm_pid" 2>/dev/null || fail "removal did not wait for the worker lock"
if "$H" connect Ledger 12 1 1 2>/dev/null; then
    "$H" disconnect Ledger 12 1 1 || true
    : > "$T/release"; wait "$rm_pid" "$holder" || true
    fail "new connect got an upstream session while removal was in progress"
fi
pass "connect refused while removal waits after drain"
: > "$T/release"; wait "$holder"
wait "$rm_pid" || fail "remove_share failed: $(cat "$T/remove.out")"
[[ ! -e /var/lib/smbproxy/shares/Ledger.env && ! -e /etc/samba/.creds-Ledger ]] || fail "state/creds left after removal"
! grep -q '^\[Ledger\]' /etc/samba/smb.conf || fail "section left after removal"
! "$H" withdrawn Ledger 2>/dev/null || fail "marker left after successful removal"
[[ $(session_count) -eq 0 ]] || fail "an upstream session outlived the removal"
pass "successful removal leaves nothing behind"

# ---- 2. a client that will not let go: removal fails, nothing is lost -----
seed_share
"$H" connect Ledger 21 1 1
: > "$FAKE_STUCK_CLIENT"; : > "$FAKE_UMOUNT_FAIL"
rc=0; remove_share Ledger > "$T/remove2.out" 2>&1 || rc=$?
[[ $rc -ne 0 ]] || fail "removal reported success with a live session"
[[ -e /var/lib/smbproxy/shares/Ledger.env && -e /etc/samba/.creds-Ledger ]] || fail "state/creds deleted on failed removal"
grep -q '^\[Ledger\]' /etc/samba/smb.conf || fail "section deleted on failed removal"
"$H" withdrawn Ledger || fail "share not left withdrawn after failed removal"
grep -q -- "--remove-share" "$T/remove2.out" || fail "no recovery guidance printed"
pass "failed drain keeps state, stays withdrawn, prints recovery command"
# Recovery: client gone, re-run removal.
rm -f "$FAKE_STUCK_CLIENT" "$FAKE_UMOUNT_FAIL"
remove_share Ledger >/dev/null 2>&1 || fail "retry after recovery failed"
! "$H" withdrawn Ledger && [[ ! -e /var/lib/smbproxy/shares/Ledger.env ]] || fail "retry left residue"
pass "re-run after recovery completes the removal"

# ---- 3. when does a reconfigure need a drain? ------------------------------
seed_share
load_share Ledger
BACKEND_PASS=old-secret
share_requires_drain && fail "unchanged config asked for a drain"
FRONT_GROUP='LAB\Auditors'
share_requires_drain && fail "frontend-only change asked for a drain"
BACKEND_PASS=new-secret
share_requires_drain || fail "password change did not require a drain"
BACKEND_PASS=old-secret; BACKEND_IP=192.0.2.99
share_requires_drain || fail "backend change did not require a drain"
load_share Ledger; BACKEND_PASS=old-secret; FRONT_FORCE_USER=other
share_requires_drain || fail "identity change did not require a drain"
pass "drain required exactly for backend/identity/credential changes"

# ---- 4. an interrupted removal that already deleted state ------------------
"$H" withdraw Ledger remove
rm -f /var/lib/smbproxy/shares/Ledger.env /etc/samba/.creds-Ledger
remove_share Ledger >/dev/null 2>&1 || fail "cleanup of a half-removed share failed"
! "$H" withdrawn Ledger || fail "stale marker survived re-run of removal"
pass "re-running removal clears a stale withdrawal marker"

echo "share lifecycle integration tests passed"
