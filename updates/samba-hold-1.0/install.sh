#!/usr/bin/env bash
# One-off install of the Samba package hold for an appliance built before
# image prep applied it. Changes nothing but apt hold marks, one helper,
# and one login-banner snippet. No service restart, no Samba change.

set -euo pipefail

readonly RELEASE="samba-hold-1.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$SCRIPT_DIR/payload"
BACKUP_ROOT="${SMBPROXY_UPDATE_BACKUP_ROOT:-/var/backups/smbproxy-updater}"
HELPER=/usr/local/sbin/smbproxy-samba-hold
MOTD=/etc/update-motd.d/17-smbproxy-samba

die() { echo "ERROR: $*" >&2; exit 2; }

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run this installer with sudo"
(cd "$PAYLOAD" && sha256sum -c --quiet SHA256SUMS) || die "payload checksum mismatch"

BACKUP_DIR="$BACKUP_ROOT/$(date -u +%Y%m%dT%H%M%SZ)-$RELEASE"
install -d -m 0700 "$BACKUP_DIR"
apt-mark showhold > "$BACKUP_DIR/holds-before"
for f in "$HELPER" "$MOTD"; do
    [[ -e "$f" ]] && cp -a "$f" "$BACKUP_DIR/"
done
install -m 0755 "$SCRIPT_DIR/rollback.sh" "$BACKUP_DIR/rollback.sh"

install -m 0755 "$PAYLOAD/smbproxy-samba-hold" "$HELPER"
install -m 0755 "$PAYLOAD/17-smbproxy-samba" "$MOTD"
"$HELPER" apply
"$HELPER" check

echo
echo "Installed $RELEASE."
"$HELPER" status
echo "Backup:   $BACKUP_DIR"
echo "Rollback: sudo $BACKUP_DIR/rollback.sh $BACKUP_DIR"
