#!/usr/bin/env bash
# Build dist/smbproxy-samba-hold-1.0.tar.gz for already-deployed appliances.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SOURCE="$ROOT/updates/samba-hold-1.0"
NAME="smbproxy-samba-hold-1.0"
DIST="$ROOT/dist"
STAGE=$(mktemp -d "${TMPDIR:-/tmp}/smbproxy-samba-hold-stage.XXXXXX")
trap 'rm -rf "$STAGE"' EXIT

sha256() { if command -v sha256sum >/dev/null 2>&1; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

install -d "$STAGE/$NAME/payload" "$DIST"
install -m 0755 "$SOURCE/install.sh" "$SOURCE/rollback.sh" "$STAGE/$NAME/"
install -m 0644 "$SOURCE/README.txt" "$STAGE/$NAME/"
install -m 0755 "$ROOT/smbproxy-samba-hold" "$STAGE/$NAME/payload/"
# Extract the banner snippet from prepare-image.sh so the field unit and new
# images get byte-identical files.
awk '/^cat > \/etc\/update-motd.d\/17-smbproxy-samba <</ {on=1; next}
     on && /^MOTDEOF$/ {exit}
     on {print}' "$ROOT/prepare-image.sh" > "$STAGE/$NAME/payload/17-smbproxy-samba"
[[ -s "$STAGE/$NAME/payload/17-smbproxy-samba" ]] || { echo "banner snippet not found in prepare-image.sh" >&2; exit 2; }
chmod 0755 "$STAGE/$NAME/payload/17-smbproxy-samba"
(cd "$STAGE/$NAME/payload" && sha256 smbproxy-samba-hold 17-smbproxy-samba > SHA256SUMS)

if command -v xattr >/dev/null 2>&1; then
    xattr -cr "$STAGE/$NAME"
fi
COPYFILE_DISABLE=1 tar --no-xattrs -czf "$DIST/$NAME.tar.gz" -C "$STAGE" "$NAME" 2>/dev/null \
    || tar -czf "$DIST/$NAME.tar.gz" -C "$STAGE" "$NAME"
(cd "$DIST" && sha256 "$NAME.tar.gz" > "$NAME.tar.gz.sha256")
echo "$DIST/$NAME.tar.gz"
