#!/usr/bin/env bash
# Behavioral test for the fail-closed private-ABI package revision guard.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CHECK="$ROOT/smbproxy-vfs-version-check"
TEST_ROOT=$(mktemp -d /tmp/smbproxy-vfs-version-test.XXXXXX)
# Sibling appliance-core supplies the state parser (code-review session plan 05).
SMBPROXY_APPCORE_KVSTATE="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/appliance-core/lib/kvstate.sh"
export SMBPROXY_APPCORE_KVSTATE
trap 'rm -rf "$TEST_ROOT"' EXIT

mkdir -p "$TEST_ROOT/shares" "$TEST_ROOT/bin" "$TEST_ROOT/modules/vfs"
printf '%s\n' '1:4.22.0+dfsg-1' > "$TEST_ROOT/expected"
: > "$TEST_ROOT/modules/vfs/fileid.so"

cat > "$TEST_ROOT/bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$SMBPROXY_TEST_PACKAGE_VERSION"
EOF
chmod +x "$TEST_ROOT/bin/dpkg-query"

cat > "$TEST_ROOT/bin/smbd" <<EOF
#!/usr/bin/env bash
printf '   MODULESDIR: %s\n' '$TEST_ROOT/modules'
EOF
chmod +x "$TEST_ROOT/bin/smbd"

export SMBPROXY_STATE_DIR="$TEST_ROOT/shares"
export SMBPROXY_VFS_VERSION_FILE="$TEST_ROOT/expected"
export SMBPROXY_DPKG_QUERY_BIN="$TEST_ROOT/bin/dpkg-query"
export SMBPROXY_SMBD_BIN="$TEST_ROOT/bin/smbd"

# No configured legacy share means modern-only service operation is allowed.
SMBPROXY_TEST_PACKAGE_VERSION='different' "$CHECK"

cat > "$TEST_ROOT/shares/Legacy.env" <<'EOF'
SHARE_NAME="Legacy"
PROFILE="legacy"
EOF

SMBPROXY_TEST_PACKAGE_VERSION='1:4.22.0+dfsg-1' "$CHECK"
if SMBPROXY_TEST_PACKAGE_VERSION='1:4.22.0+dfsg-2' "$CHECK" 2>/dev/null; then
    echo "FAIL package revision mismatch did not fail closed" >&2
    exit 1
fi

rm -f "$TEST_ROOT/expected"
if SMBPROXY_TEST_PACKAGE_VERSION='1:4.22.0+dfsg-1' "$CHECK" 2>/dev/null; then
    echo "FAIL missing build revision did not fail closed" >&2
    exit 1
fi

printf '%s\n' '1:4.22.0+dfsg-1' > "$TEST_ROOT/expected"
rm -f "$TEST_ROOT/modules/vfs/fileid.so"
if SMBPROXY_TEST_PACKAGE_VERSION='1:4.22.0+dfsg-1' "$CHECK" 2>/dev/null; then
    echo "FAIL missing fileid module did not fail closed" >&2
    exit 1
fi

# Code-review session plan 05: state is data. A record that claims to be
# modern but is malformed counts as legacy (the guard applies), and nothing
# in it runs.
rm -f "$TEST_ROOT/shares/Legacy.env"
printf '%s\n' 'SHARE_NAME="Evil"' 'PROFILE="modern"$(touch '"$TEST_ROOT"'/pwned)' \
    > "$TEST_ROOT/shares/Evil.env"
if SMBPROXY_TEST_PACKAGE_VERSION='different' "$CHECK" 2>/dev/null; then
    echo "FAIL malformed share state did not fail closed" >&2
    exit 1
fi
[[ ! -e "$TEST_ROOT/pwned" ]] || { echo "FAIL share state was executed" >&2; exit 1; }
if SMBPROXY_TEST_PACKAGE_VERSION='different' SMBPROXY_APPCORE_KVSTATE=/nonexistent \
    "$CHECK" 2>/dev/null; then
    echo "FAIL missing state parser did not fail closed" >&2
    exit 1
fi

echo "VFS version guard tests passed"
