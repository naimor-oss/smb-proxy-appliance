#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MIGRATE="$ROOT/updates/inplace-0.4.0/migrate-config.sh"
TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/smbproxy-updater-test.XXXXXX")
trap 'rm -rf "$TEST_ROOT"' EXIT
mkdir -p "$TEST_ROOT/shares"

cat > "$TEST_ROOT/smb.conf" <<'EOF'
[global]
    workgroup = LAB

[AppData]
    path = /mnt/legacy/AppData
    read only = no
    vfs objects = acl_xattr
    # preserve this operator comment
    strict locking = yes

[CNC]
    path = /mnt/backend/CNC
    read only = no
    root preexec = /usr/local/sbin/smbproxy-probe-backend %S
    root preexec close = yes
EOF
cat > "$TEST_ROOT/fstab" <<'EOF'
UUID=abc / ext4 defaults 0 1
//172.20.50.1/AppData /mnt/legacy/AppData cifs credentials=/etc/samba/.creds-AppData,vers=1.0,cache=none,nobrl,hard,x-systemd.automount 0 0
//172.20.50.1/AppData /mnt/legacy/AppData cifs credentials=/etc/samba/.creds-AppData,vers=1.0,cache=none,nobrl,hard,x-systemd.automount 0 0
//10.10.10.50/CNC /mnt/backend/CNC cifs credentials=/etc/samba/.creds-CNC,vers=2.1,x-systemd.automount,soft,echo_interval=10,x-systemd.mount-timeout=4 0 0
EOF
cat > "$TEST_ROOT/shares/AppData.env" <<'EOF'
SHARE_NAME="AppData"
BACKEND_MOUNT="/mnt/legacy/AppData"
EOF
cat > "$TEST_ROOT/shares/CNC.env" <<'EOF'
SHARE_NAME="CNC"
PROFILE="modern"
OFFLINE_MODE="direct"
BACKEND_MOUNT="/mnt/backend/CNC"
EOF
before_states=$(shasum "$TEST_ROOT/shares/"*.env)

run_migration() {
    SMBPROXY_MIGRATE_SMB_CONF="$TEST_ROOT/smb.conf" \
    SMBPROXY_MIGRATE_FSTAB="$TEST_ROOT/fstab" \
    SMBPROXY_MIGRATE_SHARES_DIR="$TEST_ROOT/shares" \
    SMBPROXY_MIGRATE_MANIFEST="$TEST_ROOT/mounts" \
    SMBPROXY_MIGRATE_TESTPARM_BIN=__not_installed__ \
        "$MIGRATE"
}

run_migration
grep -qF 'path = /run/smbproxy/sessions' "$TEST_ROOT/smb.conf"
grep -qF 'vfs objects = smbproxy_session fileid acl_xattr' "$TEST_ROOT/smb.conf"
grep -qF 'fileid:algorithm = fsname' "$TEST_ROOT/smb.conf"
grep -qF '# preserve this operator comment' "$TEST_ROOT/smb.conf"
grep -qF 'root preexec = /usr/local/sbin/smbproxy-probe-backend "%S"' "$TEST_ROOT/smb.conf"
grep -qF 'root preexec close = yes' "$TEST_ROOT/smb.conf"
if grep -qF '/mnt/legacy/AppData cifs' "$TEST_ROOT/fstab"; then
    echo "FAIL legacy fstab mount survived migration" >&2
    exit 1
fi
grep -qF '/mnt/backend/CNC cifs' "$TEST_ROOT/fstab"
grep -qF 'soft,echo_interval=10,x-systemd.mount-timeout=4' "$TEST_ROOT/fstab"
if grep -qE '(^|,)hard(,|[[:space:]])' "$TEST_ROOT/fstab"; then
    echo "FAIL modern fstab mount remained hard" >&2
    exit 1
fi
if grep -qF 'nobrl' "$TEST_ROOT/fstab"; then
    echo "FAIL nobrl survived migration" >&2
    exit 1
fi
[[ "$before_states" == "$(shasum "$TEST_ROOT/shares/"*.env)" ]]

# Re-running is content-idempotent.
first_conf=$(shasum "$TEST_ROOT/smb.conf")
first_fstab=$(shasum "$TEST_ROOT/fstab")
run_migration
[[ "$first_conf" == "$(shasum "$TEST_ROOT/smb.conf")" ]]
[[ "$first_fstab" == "$(shasum "$TEST_ROOT/fstab")" ]]
[[ $(grep -cF 'vfs objects = smbproxy_session fileid acl_xattr' "$TEST_ROOT/smb.conf") -eq 1 ]]
[[ $(grep -cF 'fileid:algorithm = fsname' "$TEST_ROOT/smb.conf") -eq 1 ]]
[[ $(grep -cF 'root preexec = /usr/local/sbin/smbproxy-probe-backend "%S"' "$TEST_ROOT/smb.conf") -eq 2 ]]

# A custom hook is never overwritten silently.
sed -i.bak '/\[CNC\]/a\
    root preexec = /usr/local/sbin/operator-hook' "$TEST_ROOT/smb.conf"
cp "$TEST_ROOT/smb.conf" "$TEST_ROOT/conf-before-refusal"
if run_migration 2>/dev/null; then
    echo "FAIL migration accepted a custom root preexec" >&2
    exit 1
fi
cmp -s "$TEST_ROOT/conf-before-refusal" "$TEST_ROOT/smb.conf"

echo "in-place updater migration tests passed"
