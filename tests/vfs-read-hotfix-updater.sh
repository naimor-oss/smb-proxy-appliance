#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALLER="$ROOT/updates/vfs-read-hotfix-0.2.0/install.sh"
ROLLBACK="$ROOT/updates/vfs-read-hotfix-0.2.0/rollback.sh"
BUILDER="$ROOT/updates/build-vfs-read-hotfix-0.2.0.sh"

bash -n "$INSTALLER" "$ROLLBACK" "$BUILDER"
grep -qF 'package/Samba mismatch' "$INSTALLER"
grep -qF 'active SMB client process(es)' "$INSTALLER"
grep -qF 'config.sha256.before' "$INSTALLER"
grep -qF 'smbproxy-session-vfs-rollback.deb' "$INSTALLER"
grep -qF 'vfs-was-manually-installed' "$INSTALLER"
grep -qF 'vfs-files.tar' "$ROLLBACK"
grep -qF 'cmp "$BACKUP_DIR/config.sha256.before"' "$INSTALLER"

if grep -Eq 'install .*\/etc\/(samba|smbproxy)|cp .*\/etc\/(samba|smbproxy)' \
    "$INSTALLER"; then
    echo "FAIL: VFS-only updater writes appliance configuration" >&2
    exit 1
fi

echo "VFS read hotfix updater contract passed"
