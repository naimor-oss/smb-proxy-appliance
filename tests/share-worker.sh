#!/usr/bin/env bash
# Unit/scenario tests for one-way queued delivery and direct availability.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKER="${SCRIPT_DIR}/../smbproxy-share-worker"
[[ -f "$WORKER" ]] || { echo "FAIL: $WORKER not found" >&2; exit 2; }

TEST_ROOT=$(mktemp -d /tmp/smbproxy-worker-test.XXXXXX)
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
REAL_AUTOMOUNT_FN=$(declare -f set_direct_automount_availability)
eval "${REAL_AUTOMOUNT_FN/set_direct_automount_availability/set_direct_automount_availability_real}"

PASS=0
FAIL=0
TEST_REACHABLE=yes
AUTOMOUNT_ACTION=""

# Keep tests independent of real mounts, TCP endpoints, syslog, and users.
data_root_ready() { [[ -d "$DATA_ROOT" ]]; }
backend_reachable() { [[ "$TEST_REACHABLE" == yes ]]; }
backend_mount_ready() { [[ -d "$1" ]]; }
backend_mount_active() { [[ -d "$1" ]]; }
set_direct_automount_availability() {
    AUTOMOUNT_ACTION="$1:$2:$3"
}
log() { :; }

check_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL  %s\n  expected: %s\n  actual:   %s\n' \
            "$name" "$expected" "$actual"
    fi
}

check_path() {
    local name="$1" expected="$2" path="$3" actual=no
    [[ -e "$path" ]] && actual=yes
    check_eq "$name" "$expected" "$actual"
}

mkdir -p "$SHARES_DIR" "$HEALTH_DIR" "$DATA_ROOT/shares/CNC" \
    "$DATA_ROOT/state" "$TEST_ROOT/backend"
printf '%s\n' \
    'SHARE_NAME="CNC"' \
    'PROFILE="modern"' \
    'OFFLINE_MODE="queued"' \
    'BACKEND_IP="192.0.2.10"' \
    "BACKEND_MOUNT=\"${TEST_ROOT}/backend\"" \
    'FRONT_FORCE_USER=""' \
    > "$SHARES_DIR/CNC.env"
printf '[global]\n' > "$SMB_CONF"

echo "== queued one-way delivery =="
printf 'v1\n' > "$DATA_ROOT/shares/CNC/program.nc"
worker_run
check_path "first observation does not publish a possibly partial file" no \
    "$TEST_ROOT/backend/program.nc"
worker_run
check_eq "new office file uploads" "v1" \
    "$(tr -d '\n' < "$TEST_ROOT/backend/program.nc")"

printf 'operator tweak\n' > "$TEST_ROOT/backend/program.nc"
worker_run
check_eq "unchanged office source does not overwrite operator tweak" \
    "operator tweak" "$(tr -d '\n' < "$TEST_ROOT/backend/program.nc")"

printf 'v2\n' > "$DATA_ROOT/shares/CNC/program.nc"
worker_run
check_eq "first update observation leaves deployed version intact" \
    "operator tweak" "$(tr -d '\n' < "$TEST_ROOT/backend/program.nc")"
worker_run
check_eq "office update intentionally overwrites same-name operator tweak" \
    "v2" "$(tr -d '\n' < "$TEST_ROOT/backend/program.nc")"

printf 'machine-only\n' > "$TEST_ROOT/backend/operator.nest"
worker_run
check_eq "machine-only file is never imported to office copy" "no" \
    "$([[ -e "$DATA_ROOT/shares/CNC/operator.nest" ]] && echo yes || echo no)"
check_path "machine-only file remains on backend" yes \
    "$TEST_ROOT/backend/operator.nest"

mv "$DATA_ROOT/shares/CNC/program.nc" "$DATA_ROOT/shares/CNC/renamed.nc"
worker_run
check_path "rename keeps old path until new file is stable" yes \
    "$TEST_ROOT/backend/program.nc"
check_path "rename does not publish new path on first observation" no \
    "$TEST_ROOT/backend/renamed.nc"
worker_run
check_path "rename uploads new path first" yes \
    "$TEST_ROOT/backend/renamed.nc"
check_path "rename removes old managed path" no \
    "$TEST_ROOT/backend/program.nc"
check_path "rename does not touch machine-only file" yes \
    "$TEST_ROOT/backend/operator.nest"

rm "$DATA_ROOT/shares/CNC/renamed.nc"
worker_run
check_path "first delete observation leaves deployed file intact" yes \
    "$TEST_ROOT/backend/renamed.nc"
worker_run
check_path "office delete removes tracked backend path" no \
    "$TEST_ROOT/backend/renamed.nc"
check_path "office delete still does not touch machine-only file" yes \
    "$TEST_ROOT/backend/operator.nest"

TEST_REACHABLE=no
printf 'queued while offline\n' > "$DATA_ROOT/shares/CNC/offline.nc"
worker_run
check_path "offline office write remains local" yes \
    "$DATA_ROOT/shares/CNC/offline.nc"
check_path "offline office write is not published prematurely" no \
    "$TEST_ROOT/backend/offline.nc"
# shellcheck disable=SC1091
pending=$(source "$HEALTH_DIR/CNC.env"; printf '%s' "$PENDING_UPLOADS")
check_eq "offline write is reported pending" "1" "$pending"

TEST_REACHABLE=yes
worker_run
check_eq "pending write deploys when backend returns" "queued while offline" \
    "$(tr -d '\n' < "$TEST_ROOT/backend/offline.nc")"
# shellcheck disable=SC1091
pending=$(source "$HEALTH_DIR/CNC.env"; printf '%s' "$PENDING_UPLOADS")
check_eq "pending count clears after successful delivery" "0" "$pending"

mkdir -p "$DATA_ROOT/shares/LegacyQueued" "$TEST_ROOT/backend-legacy"
printf 'must not replay\n' > "$DATA_ROOT/shares/LegacyQueued/unsafe.tps"
printf '%s\n' \
    'SHARE_NAME="LegacyQueued"' \
    'PROFILE="legacy"' \
    'OFFLINE_MODE="queued"' \
    'BACKEND_IP="192.0.2.30"' \
    "BACKEND_MOUNT=\"${TEST_ROOT}/backend-legacy\"" \
    'FRONT_FORCE_USER=""' \
    > "$SHARES_DIR/LegacyQueued.env"
worker_run
check_path "worker refuses queued replay for legacy profile" no \
    "$TEST_ROOT/backend-legacy/unsafe.tps"
# shellcheck disable=SC1091
health_mode=$(source "$HEALTH_DIR/LegacyQueued.env"; printf '%s' "$MODE")
check_eq "legacy queued state falls back to direct health behavior" \
    "direct" "$health_mode"

echo "== direct fail-fast availability =="
printf '%s\n' \
    'SHARE_NAME="Direct"' \
    'PROFILE="modern"' \
    'OFFLINE_MODE="direct"' \
    'BACKEND_IP="192.0.2.20"' \
    "BACKEND_MOUNT=\"${TEST_ROOT}/backend-direct\"" \
    'FRONT_FORCE_USER=""' \
    > "$SHARES_DIR/Direct.env"
printf '[global]\n\n[Direct]\n    path = %s\n' \
    "$TEST_ROOT/backend-direct" > "$SMB_CONF"

TEST_REACHABLE=no
worker_run
check_eq "first failed health check keeps direct automount available" \
    "Direct:$TEST_ROOT/backend-direct:online" "$AUTOMOUNT_ACTION"
check_eq "first failed health check does not withdraw share" "no" \
    "$(grep -qF "$MANAGED_AVAILABLE" "$SMB_CONF" && echo yes || echo no)"
worker_run
check_eq "withdrawal pass defers backend cleanup until config is reloaded" \
    "Direct:$TEST_ROOT/backend-direct:online" "$AUTOMOUNT_ACTION"
check_eq "second failed health check withdraws new tree connects" "yes" \
    "$(grep -qF "$MANAGED_AVAILABLE" "$SMB_CONF" && echo yes || echo no)"
check_path "offline direct share uses an existing inert local path" yes \
    "$SMBPROXY_OFFLINE_PATH"
direct_path=$(awk -F= '
    $0 == "[Direct]" { in_section=1; next }
    in_section && /^\[/ { in_section=0 }
    in_section && /^[[:space:]]*path[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, "")
        path=$0
    }
    END { print path }
' "$SMB_CONF")
check_eq "offline direct share overrides a disconnected backend path" \
    "$SMBPROXY_OFFLINE_PATH" "$direct_path"

worker_run
check_eq "next offline pass reconciles the idle automount" \
    "Direct:$TEST_ROOT/backend-direct:offline" "$AUTOMOUNT_ACTION"

TEST_REACHABLE=yes
mkdir -p "$TEST_ROOT/backend-direct"
worker_run
check_eq "recovered direct share restores its automount" \
    "Direct:$TEST_ROOT/backend-direct:online" "$AUTOMOUNT_ACTION"
check_eq "successful health check restores share availability" "no" \
    "$(grep -qF "$MANAGED_AVAILABLE" "$SMB_CONF" && echo yes || echo no)"
check_eq "health marker is also removed on recovery" "no" \
    "$(grep -qF "$MANAGED_MARKER" "$SMB_CONF" && echo yes || echo no)"
direct_path=$(awk -F= '
    $0 == "[Direct]" { in_section=1; next }
    in_section && /^\[/ { in_section=0 }
    in_section && /^[[:space:]]*path[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, "")
        path=$0
    }
    END { print path }
' "$SMB_CONF")
check_eq "successful health check restores the configured backend path" \
    "$TEST_ROOT/backend-direct" "$direct_path"

echo "== pre-connect failure hint =="
rm -f "$HEALTH_DIR/Direct.env"
mkdir -p "$SMBPROXY_PROBE_HINT_DIR"
: > "$SMBPROXY_PROBE_HINT_DIR/Direct"
TEST_REACHABLE=no
worker_run
check_eq "hint plus independent worker failure withdraws in one pass" "yes" \
    "$(grep -qF "$MANAGED_AVAILABLE" "$SMB_CONF" && echo yes || echo no)"
check_path "worker consumes the pre-connect failure hint" no \
    "$SMBPROXY_PROBE_HINT_DIR/Direct"

echo "== active mount cleanup guard =="
TEST_AUTOMOUNT_ACTIVE=yes
TEST_DIRECT_MOUNT_ACTIVE=yes
TEST_FRONTEND_ACTIVE=yes
SYSTEMCTL_ACTION=""
backend_automount_unit() { printf 'fixture.automount'; }
backend_mount_unit() { printf 'fixture.mount'; }
backend_mount_active() { [[ "$TEST_DIRECT_MOUNT_ACTIVE" == yes ]]; }
frontend_share_active() { [[ "$TEST_FRONTEND_ACTIVE" == yes ]]; }
systemctl() {
    local action="$1" unit="${2:-}"
    case "$action" in
        show) printf 'loaded\n' ;;
        is-active) [[ "$TEST_AUTOMOUNT_ACTIVE" == yes ]] ;;
        stop)
            SYSTEMCTL_ACTION="stop:${*:2}"
            TEST_AUTOMOUNT_ACTIVE=no
            [[ " $* " == *' fixture.mount '* ]] && TEST_DIRECT_MOUNT_ACTIVE=no
            ;;
        start)
            SYSTEMCTL_ACTION="start:${*:2}"
            TEST_AUTOMOUNT_ACTIVE=yes
            ;;
        reset-failed) : ;;
    esac
}
set_direct_automount_availability_real Direct /fixture/direct offline
check_eq "active frontend session defers mounted-backend cleanup" "" \
    "$SYSTEMCTL_ACTION"
TEST_FRONTEND_ACTIVE=no
set_direct_automount_availability_real Direct /fixture/direct offline
check_eq "session-free offline share stops mount and automount together" \
    "stop:fixture.automount fixture.mount" "$SYSTEMCTL_ACTION"
SYSTEMCTL_ACTION=""
set_direct_automount_availability_real Direct /fixture/direct online
check_eq "recovery restarts the idle automount" \
    "start:fixture.automount" "$SYSTEMCTL_ACTION"

echo
echo "summary: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
