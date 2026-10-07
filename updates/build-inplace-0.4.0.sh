#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/updates/inplace-0.4.0"
VFS_REPO="${VFS_REPO:-$ROOT/../smbproxy-session-vfs}"
VFS_SOURCE="$VFS_REPO/src/vfs_smbproxy_session.c"
VFS_SOURCE_SHA256=e107384ad375721c84dc33391bf01d19f6f75cb35a347be67706abab782dae46
NAME="smbproxy-inplace-updater-0.4.0-inplace7"
DIST="$ROOT/dist"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/smbproxy-updater-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

install -d "$STAGE/$NAME/payload/samba-vfs" "$DIST"
install -m 0755 "$SOURCE/install.sh" "$SOURCE/migrate-config.sh" \
    "$SOURCE/rollback.sh" "$STAGE/$NAME/"
install -m 0644 "$SOURCE/README.txt" "$STAGE/$NAME/"
install -m 0755 \
    "$ROOT/smbproxy-sconfig.sh" \
    "$ROOT/smbproxy-probe-backend" \
    "$ROOT/smbproxy-share-worker" \
    "$ROOT/smbproxy-session-mount" \
    "$ROOT/smbproxy-vfs-version-check" \
    "$STAGE/$NAME/payload/"
[[ -f "$VFS_SOURCE" ]] || { echo "missing frozen VFS source: $VFS_SOURCE" >&2; exit 2; }
actual_vfs_hash=$(shasum -a 256 "$VFS_SOURCE" | awk '{ print $1 }')
[[ "$actual_vfs_hash" == "$VFS_SOURCE_SHA256" ]] || {
    echo "one-off updater source hash changed: $actual_vfs_hash" >&2
    exit 2
}
install -m 0755 "$SOURCE/build-module.sh" \
    "$STAGE/$NAME/payload/samba-vfs/"
install -m 0644 "$VFS_SOURCE" \
    "$STAGE/$NAME/payload/samba-vfs/"

if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$STAGE/$NAME"
fi
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$DIST/$NAME.tar.gz" -C "$STAGE" "$NAME"
(
    cd "$DIST"
    shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
)
echo "$DIST/$NAME.tar.gz"
