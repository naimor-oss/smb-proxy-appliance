#!/usr/bin/env bash
# Unit contract for the privileged session-mount helper. Uses fake mount tools;
# no real mount, network access, or credentials are touched.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../smbproxy-session-mount"
TEST_ROOT=$(mktemp -d /tmp/smbproxy-session-test.XXXXXX)
# Sibling appliance-core supplies the state parser (code-review session plan 05).
SMBPROXY_APPCORE_KVSTATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/appliance-core/lib/kvstate.sh"
export SMBPROXY_APPCORE_KVSTATE
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/shares" "$TEST_ROOT/creds" "$TEST_ROOT/bin"
: > "$TEST_ROOT/proc-mounts"
: > "$TEST_ROOT/mount-args"

cat > "$TEST_ROOT/shares/Engineering_.env" <<'EOF'
SHARE_NAME="Engineering$"
PROFILE="legacy"
BACKEND_IP="192.0.2.10"
FRONT_FORCE_USER="root"
EOF
cat > "$TEST_ROOT/creds/.creds-Engineering_" <<'EOF'
username=test
password=not-a-real-secret
domain=LEGACY
EOF
chmod 0600 "$TEST_ROOT/creds/.creds-Engineering_"

cat > "$TEST_ROOT/bin/mount" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$SMBPROXY_TEST_MOUNT_ARGS"
printf '%s %s cifs %s 0 0\n' "$3" "$4" "$6" >> "$SMBPROXY_PROC_MOUNTS"
EOF
cat > "$TEST_ROOT/bin/umount" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
awk -v mp="$1" '$2 != mp { print }' "$SMBPROXY_PROC_MOUNTS" > "${SMBPROXY_PROC_MOUNTS}.new"
mv "${SMBPROXY_PROC_MOUNTS}.new" "$SMBPROXY_PROC_MOUNTS"
EOF
chmod +x "$TEST_ROOT/bin/mount" "$TEST_ROOT/bin/umount"

export SMBPROXY_STATE_DIR="$TEST_ROOT/shares"
export SMBPROXY_CREDS_DIR="$TEST_ROOT/creds"
export SMBPROXY_SESSION_ROOT="$TEST_ROOT/sessions"
export SMBPROXY_SESSION_STATE="$TEST_ROOT/session-state"
export SMBPROXY_PROC_MOUNTS="$TEST_ROOT/proc-mounts"
export SMBPROXY_MOUNT_BIN="$TEST_ROOT/bin/mount"
export SMBPROXY_UMOUNT_BIN="$TEST_ROOT/bin/umount"
export SMBPROXY_SESSION_LOG="$TEST_ROOT/session.log"
export SMBPROXY_TEST_MOUNT_ARGS="$TEST_ROOT/mount-args"
export SMBPROXY_ALLOW_NON_ROOT_TEST=1
export SMBPROXY_LIFECYCLE_DIR="$TEST_ROOT/lifecycle"
export SMBPROXY_SHARE_LOCK_DIR="$TEST_ROOT/locks"

"$HELPER" connect 'Engineering$' 101 202 303

args=$(<"$TEST_ROOT/mount-args")
for required in '//192.0.2.10/Engineering$' 'vers=1.0' 'cache=none' \
    'hard' 'nosharesock' 'serverino' 'credentials='; do
    [[ "$args" == *"$required"* ]] || { echo "FAIL missing mount option: $required" >&2; exit 1; }
done
[[ "$args" != *nobrl* ]] || { echo "FAIL nobrl disables backend lock forwarding" >&2; exit 1; }

record="$TEST_ROOT/session-state/101-202-303.env"
[[ -f "$record" ]] || { echo "FAIL session record missing" >&2; exit 1; }
grep -qF 'SHARE_NAME="Engineering$"' "$record"
grep -qF "MOUNTPOINT=\"$TEST_ROOT/sessions/101-202-303\"" "$record"
grep -qF 'action=CONNECT share=Engineering$ pid=101 vuid=202 cnum=303' "$TEST_ROOT/session.log"

"$HELPER" disconnect 'Engineering$' 101 202 303
[[ ! -f "$record" ]] || { echo "FAIL session record survived disconnect" >&2; exit 1; }
[[ ! -s "$TEST_ROOT/proc-mounts" ]] || { echo "FAIL CIFS mount survived disconnect" >&2; exit 1; }
grep -qF 'action=DISCONNECT share=Engineering$ pid=101 vuid=202 cnum=303' "$TEST_ROOT/session.log"

# Crash recovery removes both recorded sessions and a mount whose process died
# after mount(8) succeeded but before its state file was written.
"$HELPER" connect 'Engineering$' 111 222 333
mkdir -p "$TEST_ROOT/sessions/444-555-666"
printf '%s %s cifs %s 0 0\n' '//192.0.2.10/Engineering$' \
    "$TEST_ROOT/sessions/444-555-666" 'vers=1.0,cache=none,hard,nosharesock' \
    >> "$TEST_ROOT/proc-mounts"
"$HELPER" cleanup-all
[[ ! -s "$TEST_ROOT/proc-mounts" ]] || { echo "FAIL cleanup-all left a CIFS mount" >&2; exit 1; }
shopt -s nullglob
records=("$TEST_ROOT/session-state"/*.env)
shopt -u nullglob
[[ ${#records[@]} -eq 0 ]] || { echo "FAIL cleanup-all left session state" >&2; exit 1; }

# ---- Lifecycle: withdrawal blocks new upstream sessions (session plan 02) ----
lifecycle_fail() { echo "FAIL lifecycle: $*" >&2; exit 1; }
"$HELPER" cleanup-all
"$HELPER" withdraw 'Engineering$' remove
"$HELPER" withdrawn 'Engineering$' || lifecycle_fail "withdrawn did not report the marker"
grep -q '^reason=remove$' "$TEST_ROOT/lifecycle/Engineering_.withdrawn" || lifecycle_fail "marker lacks reason"
if "$HELPER" connect 'Engineering$' 401 402 403 2>"$TEST_ROOT/err"; then
    lifecycle_fail "connect succeeded on a withdrawn share"
fi
grep -q 'withdrawn' "$TEST_ROOT/err" || lifecycle_fail "refusal does not say why"
! grep -q ' /.*401-402-403 ' "$TEST_ROOT/proc-mounts" || lifecycle_fail "withdrawn connect mounted anyway"
"$HELPER" unwithdraw 'Engineering$'
! "$HELPER" withdrawn 'Engineering$' || lifecycle_fail "marker survived unwithdraw"
"$HELPER" connect 'Engineering$' 401 402 403 || lifecycle_fail "connect refused after unwithdraw"
"$HELPER" disconnect 'Engineering$' 401 402 403

# Barrier: a connect already past the marker check (slow mount) must finish
# before withdraw returns; a connect after withdraw must be refused.
cp "$TEST_ROOT/bin/mount" "$TEST_ROOT/bin/mount.fast"
cat > "$TEST_ROOT/bin/mount" <<'SLOW'
#!/usr/bin/env bash
set -euo pipefail
sleep 2
printf '%s\n' "$*" >> "$SMBPROXY_TEST_MOUNT_ARGS"
printf '%s %s cifs %s 0 0\n' "$3" "$4" "$6" >> "$SMBPROXY_PROC_MOUNTS"
SLOW
chmod +x "$TEST_ROOT/bin/mount"
"$HELPER" connect 'Engineering$' 501 502 503 &
inflight=$!
sleep 0.5
start=$SECONDS
"$HELPER" withdraw 'Engineering$' reconfigure
[[ -f "$TEST_ROOT/session-state/501-502-503.env" ]] \
    || lifecycle_fail "withdraw returned before the in-flight connect finished"
(( SECONDS - start >= 1 )) || lifecycle_fail "withdraw did not wait on the barrier"
wait "$inflight" || lifecycle_fail "in-flight connect failed"
if "$HELPER" connect 'Engineering$' 601 602 603 2>/dev/null; then
    lifecycle_fail "connect after withdraw succeeded"
fi
mv "$TEST_ROOT/bin/mount.fast" "$TEST_ROOT/bin/mount"
"$HELPER" cleanup-share 'Engineering$'

# Barrier timeout: a connect that never finishes cannot hold up removal
# forever, and the share stays withdrawn when withdraw gives up.
"$HELPER" unwithdraw 'Engineering$'
( exec 8>"$TEST_ROOT/locks/Engineering_.lock"; flock -s 8; sleep 4 ) &
holder=$!
sleep 0.5
if SMBPROXY_BARRIER_TIMEOUT=1 "$HELPER" withdraw 'Engineering$' remove 2>/dev/null; then
    lifecycle_fail "withdraw ignored a stuck connect"
fi
"$HELPER" withdrawn 'Engineering$' || lifecycle_fail "share not left withdrawn after barrier timeout"
wait "$holder"
"$HELPER" unwithdraw 'Engineering$'

if "$HELPER" withdraw 'Engineering$' 'two words' 2>/dev/null; then
    lifecycle_fail "free-text reason accepted"
fi

# ---- State is data, never code (session plan 05) ----------------------------
printf '%s\n' 'SHARE_NAME="Evil"' "BACKEND_IP=\"192.0.2.10\"\$(touch $TEST_ROOT/pwned)" \
    'PROFILE="legacy"' 'FRONT_FORCE_USER="root"' > "$TEST_ROOT/shares/Evil.env"
cp "$TEST_ROOT/creds/.creds-Engineering_" "$TEST_ROOT/creds/.creds-Evil"
if "$HELPER" connect Evil 601 602 603 2>"$TEST_ROOT/err"; then
    echo "FAIL connect accepted malformed share state" >&2; exit 1
fi
[[ ! -e "$TEST_ROOT/pwned" ]] || { echo "FAIL share state was executed" >&2; exit 1; }
grep -q malformed "$TEST_ROOT/err" || { echo "FAIL refusal does not say why" >&2; exit 1; }
! grep -q '601-602-603' "$TEST_ROOT/proc-mounts" || { echo "FAIL malformed share mounted" >&2; exit 1; }
if SMBPROXY_APPCORE_KVSTATE=/nonexistent "$HELPER" connect 'Engineering$' 701 702 703 2>/dev/null; then
    echo "FAIL connect succeeded without the state parser" >&2; exit 1
fi

# Outside test mode the helper must not read any path or binary override:
# smbd runs it as root, so an inherited environment must not redirect it.
ungated=$(awk '/^if \[\[ "\$ALLOW_NON_ROOT_TEST" == "1" \]\]; then$/ {exit}
               /\$\{SMBPROXY_/ && !/SMBPROXY_ALLOW_NON_ROOT_TEST/ {print}' "$HELPER")
[[ -z "$ungated" ]] || { echo "FAIL: override read outside test mode: $ungated" >&2; exit 1; }

echo "session-mount tests passed"
