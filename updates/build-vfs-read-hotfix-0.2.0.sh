#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/updates/vfs-read-hotfix-0.2.0"
VFS_REPO="${VFS_REPO:-$ROOT/../smbproxy-session-vfs}"
NAME="smbproxy-vfs-read-hotfix-0.2.0"
DIST="$ROOT/dist"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/smbproxy-vfs-hotfix-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

packages=("$VFS_REPO"/dist/smbproxy-session-vfs_0.2.0+samba*_amd64.deb)
[[ ${#packages[@]} -eq 1 && -f "${packages[0]}" ]] \
    || { echo "expected exactly one 0.2.0 amd64 VFS package" >&2; exit 2; }
package="${packages[0]}"

install -d "$STAGE/$NAME/payload" "$DIST"
install -m 0755 "$SOURCE/install.sh" "$SOURCE/rollback.sh" "$STAGE/$NAME/"
install -m 0644 "$SOURCE/README.txt" "$STAGE/$NAME/"
install -m 0644 "$package" "$STAGE/$NAME/payload/"
(
    cd "$STAGE/$NAME/payload"
    shasum -a 256 "$(basename "$package")" > "$(basename "$package").sha256"
)

if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$STAGE/$NAME"
fi
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$DIST/$NAME.tar.gz" \
    -C "$STAGE" "$NAME"
(
    cd "$DIST"
    shasum -a 256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256"
)
echo "$DIST/$NAME.tar.gz"
