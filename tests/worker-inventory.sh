#!/usr/bin/env bash
# Fail-closed worker inventory (code-review session plan 07): a missing,
# unreadable, truncated or invalid share-state record never re-enables a
# managed frontend section, never publishes the offline placeholder as a
# live share, and never touches an operator-authored section.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="${SCRIPT_DIR}/../smbproxy-share-worker"
TEST_ROOT=$(mktemp -d /tmp/smbproxy-inventory-test.XXXXXX)
SMBPROXY_APPCORE_KVSTATE="$(cd "${SCRIPT_DIR}/../.." && pwd)/appliance-core/lib/kvstate.sh"
export SMBPROXY_APPCORE_KVSTATE
trap 'rm -rf "$TEST_ROOT"' EXIT

export SMBPROXY_STATE_DIR="${TEST_ROOT}/state"
export SMBPROXY_SHARES_DIR="${TEST_ROOT}/state/shares"
export SMBPROXY_HEALTH_DIR="${TEST_ROOT}/state/health"
export SMBPROXY_DATA_ROOT="${TEST_ROOT}/data"
export SMBPROXY_SESSION_ROOT="${TEST_ROOT}/sessions"
export SMBPROXY_SMB_CONF="${TEST_ROOT}/smb.conf"
export SMBPROXY_SMB_CONF_LOCK="${TEST_ROOT}/smb-conf.lock"
export SMBPROXY_WORKER_LOCK="${TEST_ROOT}/worker.lock"
export SMBPROXY_OFFLINE_PATH="${TEST_ROOT}/offline"
export SMBPROXY_PROBE_HINT_DIR="${TEST_ROOT}/probe-fail"
export SMBPROXY_SKIP_RELOAD=1
export SMBPROXY_FAIL_THRESHOLD=2

# shellcheck disable=SC1090
source "$WORKER"

PASS=0
FAIL=0
REACHABLE=yes
backend_reachable() { [[ "$REACHABLE" == yes ]]; }
backend_mount_ready() { [[ -d "$1" ]]; }
backend_mount_active() { [[ -d "$1" ]]; }
set_direct_automount_availability() { :; }
data_root_ready() { [[ -d "$DATA_ROOT" ]]; }
log() { :; }
testparm() { return 0; }

check() {
    if [[ "$2" == "$3" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL  %s\n  expected: %s\n  actual:   %s\n' "$1" "$2" "$3"
    fi
}
section() {
    awk -v s="[$1]" '$0 == s { p = 1; print; next } /^\[/ { p = 0 } p' "$SMB_CONF"
}
path_of() {
    section "$1" | awk -F= '/^[[:space:]]*path[[:space:]]*=/ { sub(/^[^=]*=[[:space:]]*/, ""); print }'
}
withdrawn() {
    section "$1" | grep -qxF "$MANAGED_AVAILABLE" && echo yes || echo no
}
health_error() {
    appcore_kv_get "$HEALTH_DIR/$1.env" LAST_ERROR "${HEALTH_KEYS[@]}" 2>/dev/null
}
state() {   # NAME MOUNT
    printf '%s\n' "SHARE_NAME=\"$1\"" 'PROFILE="modern"' 'OFFLINE_MODE="direct"' \
        'BACKEND_IP="192.0.2.50"' "BACKEND_MOUNT=\"$2\"" 'FRONT_FORCE_USER="clerk"' \
        > "$SHARES_DIR/$1.env"
}

mkdir -p "$SHARES_DIR" "$HEALTH_DIR" "$DATA_ROOT/shares" \
    "$TEST_ROOT/mnt/Online" "$TEST_ROOT/mnt/Other" "$TEST_ROOT/mnt/Offline" "$TEST_ROOT/mnt/Old"
cat > "$SMB_CONF" <<EOF
[global]
    workgroup = LAB

[Public]
    # operator share; an operator comment
    path = /srv/public
    available = no
    read only = yes

[Online]
$OWNER_MARKER
    # profile=modern; locking=standard; offline=direct
    path = $TEST_ROOT/mnt/Online
    read only = no

[Other]
$OWNER_MARKER
    path = $TEST_ROOT/mnt/Other

[Offline]
$OWNER_MARKER
    path = $SMBPROXY_OFFLINE_PATH
$MANAGED_MARKER
$MANAGED_AVAILABLE

[Old]
    # profile=modern; locking=standard; offline=direct
    path = $TEST_ROOT/mnt/Old
EOF
state Online "$TEST_ROOT/mnt/Online"
state Other "$TEST_ROOT/mnt/Other"
state Old "$TEST_ROOT/mnt/Old"
public_before=$(section Public)

echo "== healthy inventory and adoption =="
worker_run
check "healthy managed share stays online" no "$(withdrawn Online)"
check "pre-marker section with valid state is adopted" yes \
    "$(section Old | grep -qxF "$OWNER_MARKER" && echo yes || echo no)"
check "offline share without state stays withdrawn" yes "$(withdrawn Offline)"
check "missing state is recorded for the offline share" \
    "share withdrawn: state record is missing" "$(health_error Offline)"
check "operator section is byte-stable" "$public_before" "$(section Public)"
stable=$(cat "$SMB_CONF")
worker_run
check "a second pass changes nothing" "$stable" "$(cat "$SMB_CONF")"

echo "== deleting the state of an online share =="
rm -f "$SHARES_DIR/Online.env"
worker_run
check "online share without state is withdrawn" yes "$(withdrawn Online)"
check "withdrawn share serves the inert local path" "$SMBPROXY_OFFLINE_PATH" "$(path_of Online)"
check "withdrawal names its cause" "share withdrawn: state record is missing" "$(health_error Online)"
check "another share is unaffected" no "$(withdrawn Other)"
check "another share keeps its backend path" "$TEST_ROOT/mnt/Other" "$(path_of Other)"
check "operator section is still byte-stable" "$public_before" "$(section Public)"

echo "== invalid records =="
for bad in truncated unknown-version duplicate wrong-name unreadable; do
    case "$bad" in
        truncated)       printf 'SHARE_NAME="Onl' > "$SHARES_DIR/Online.env" ;;
        unknown-version) state Online "$TEST_ROOT/mnt/Online"
                         echo 'STATE_VERSION="9"' >> "$SHARES_DIR/Online.env" ;;
        duplicate)       state Online "$TEST_ROOT/mnt/Online"
                         echo 'SHARE_NAME="Online"' >> "$SHARES_DIR/Online.env" ;;
        wrong-name)      state Online "$TEST_ROOT/mnt/Online"
                         sed -i 's/^SHARE_NAME=.*/SHARE_NAME="Other"/' "$SHARES_DIR/Online.env" ;;
        unreadable)      rm -f "$SHARES_DIR/Online.env"
                         ln -s "$TEST_ROOT/nonexistent" "$SHARES_DIR/Online.env" ;;
    esac
    worker_run
    check "$bad state keeps the share withdrawn" yes "$(withdrawn Online)"
    check "$bad state never publishes the backend path" "$SMBPROXY_OFFLINE_PATH" "$(path_of Online)"
    check "$bad state does not disturb another share" no "$(withdrawn Other)"
    [[ -n "$(health_error Online)" ]] && PASS=$((PASS + 1)) \
        || { FAIL=$((FAIL + 1)); echo "FAIL  $bad state records no reason"; }
    rm -f "$SHARES_DIR/Online.env"
done

echo "== recovery needs a valid record and a reachable backend =="
state Online "$TEST_ROOT/mnt/Online"
REACHABLE=no
worker_run
check "valid record with unreachable backend stays withdrawn" yes "$(withdrawn Online)"
REACHABLE=yes
worker_run
check "valid record with reachable backend is published again" no "$(withdrawn Online)"
check "recovery restores the backend path" "$TEST_ROOT/mnt/Online" "$(path_of Online)"
check "recovery removes every health marker" no \
    "$(section Online | grep -q 'smbproxy-health' && echo yes || echo no)"
check "recovery keeps the ownership marker" yes \
    "$(section Online | grep -qxF "$OWNER_MARKER" && echo yes || echo no)"

echo "== empty state directory =="
rm -f "$SHARES_DIR"/*.env
worker_run
for s in Online Other Offline Old; do
    check "empty state directory withdraws $s" yes "$(withdrawn "$s")"
done
check "operator section survives an empty state directory" "$public_before" "$(section Public)"

echo "== orphan state =="
state Ghost "$TEST_ROOT/mnt/Ghost"
worker_run
check "orphan state creates no frontend section" "" "$(section Ghost)"
check "orphan state is recorded" "state has no frontend section; not published" "$(health_error Ghost)"

echo "== unknown withdrawals are left alone =="
printf '\n[Future]\n    path = /srv/future\n    # smbproxy-health: reason from a newer worker\n%s\n' \
    "$MANAGED_AVAILABLE" >> "$SMB_CONF"
future_before=$(section Future)
worker_run
check "an unowned section with a foreign withdrawal is untouched" "$future_before" "$(section Future)"

echo
echo "summary: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
