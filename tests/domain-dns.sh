#!/usr/bin/env bash
# Unit contract for domain-NIC-only AD DNS registration.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="${SCRIPT_DIR}/../smbproxy-domain-dns"
TEST_ROOT=$(mktemp -d /tmp/smbproxy-domain-dns-test.XXXXXX)
# Sibling appliance-core supplies the state parser (code-review session plan 05).
SMBPROXY_APPCORE_KVSTATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/appliance-core/lib/kvstate.sh"
export SMBPROXY_APPCORE_KVSTATE
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/bin"
cat > "$TEST_ROOT/roles.env" <<'EOF'
DOMAIN_NIC_NAME="eth-domain"
LEGACY_NIC_NAME="eth-legacy"
EOF
cat > "$TEST_ROOT/deploy.env" <<'EOF'
REALM="EXAMPLE.TEST"
EOF
cat > "$TEST_ROOT/bin/ip" <<'EOF'
#!/usr/bin/env bash
printf '2: eth-domain    inet 192.0.2.20/24 brd 192.0.2.255 scope global eth-domain\n'
EOF
cat > "$TEST_ROOT/bin/net" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SMBPROXY_TEST_NET_LOG"
EOF
cat > "$TEST_ROOT/bin/timeout" <<'EOF'
#!/usr/bin/env bash
shift
exec "$@"
EOF
cat > "$TEST_ROOT/bin/logger" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$SMBPROXY_TEST_LOGGER_LOG"
EOF
chmod +x "$TEST_ROOT/bin/"*

export SMBPROXY_ROLES_FILE="$TEST_ROOT/roles.env"
export SMBPROXY_DEPLOY_FILE="$TEST_ROOT/deploy.env"
export SMBPROXY_IP_BIN="$TEST_ROOT/bin/ip"
export SMBPROXY_NET_BIN="$TEST_ROOT/bin/net"
export SMBPROXY_TIMEOUT_BIN="$TEST_ROOT/bin/timeout"
export SMBPROXY_LOGGER_BIN="$TEST_ROOT/bin/logger"
export SMBPROXY_SLEEP_BIN=true
export SMBPROXY_ALLOW_NON_ROOT_TEST=1
export SMBPROXY_TEST_NET_LOG="$TEST_ROOT/net.log"
export SMBPROXY_TEST_LOGGER_LOG="$TEST_ROOT/logger.log"

SMBPROXY_DNS_DRY_RUN=1 "$HELPER" \
    | grep -qE '^fqdn=[^.]+\.example\.test interface=eth-domain ips=192\.0\.2\.20$'
[[ ! -e "$TEST_ROOT/net.log" ]]

"$HELPER"

grep -qFx 'ads testjoin' "$TEST_ROOT/net.log"
grep -qE '^ads dns unregister [^.]+\.example\.test -P$' "$TEST_ROOT/net.log"
grep -qE '^ads dns register [^.]+\.example\.test 192\.0\.2\.20 --force -P$' \
    "$TEST_ROOT/net.log"
if grep -qF 'eth-legacy' "$TEST_ROOT/net.log"; then
    echo "FAIL legacy NIC reached AD DNS registration" >&2
    exit 1
fi

echo "domain DNS tests passed"
