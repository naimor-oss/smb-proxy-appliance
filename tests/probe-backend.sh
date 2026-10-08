#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE="$ROOT/smbproxy-probe-backend"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/smbproxy-probe-test.XXXXXX")
# Sibling appliance-core supplies the state parser (code-review session plan 05).
SMBPROXY_APPCORE_KVSTATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/appliance-core/lib/kvstate.sh"
export SMBPROXY_APPCORE_KVSTATE
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/shares" "$TEST_ROOT/bin"

cat > "$TEST_ROOT/shares/Direct.env" <<'EOF'
SHARE_NAME="Direct"
BACKEND_IP="192.0.2.1"
EOF
cat > "$TEST_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SMBPROXY_TEST_SYSTEMCTL_LOG"
EOF
chmod +x "$TEST_ROOT/bin/systemctl"

export PATH="$TEST_ROOT/bin:$PATH"
export SMBPROXY_SHARES_DIR="$TEST_ROOT/shares"
export SMBPROXY_PROBE_HINT_DIR="$TEST_ROOT/probe-fail"
export SMBPROXY_WORKER_SERVICE="fixture-worker.service"
export SMBPROXY_PROBE_SECONDS=0.05
export SMBPROXY_TEST_SYSTEMCTL_LOG="$TEST_ROOT/systemctl.log"

if "$PROBE" Direct; then
    echo "FAIL: unreachable fixture unexpectedly passed" >&2
    exit 1
fi
test -f "$TEST_ROOT/probe-fail/Direct"
grep -qFx 'start --no-block fixture-worker.service' "$TEST_ROOT/systemctl.log"

rm -f "$TEST_ROOT/systemctl.log"
if "$PROBE" Missing; then
    echo "FAIL: missing share unexpectedly passed" >&2
    exit 1
fi
test ! -e "$TEST_ROOT/probe-fail/Missing"
test ! -e "$TEST_ROOT/systemctl.log"

echo "probe-backend tests passed"
