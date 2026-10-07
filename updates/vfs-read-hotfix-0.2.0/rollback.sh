#!/usr/bin/env bash
set -euo pipefail

BACKUP_DIR="${1:-}"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "run with sudo" >&2; exit 2; }
[[ -n "$BACKUP_DIR" && "$BACKUP_DIR" == /var/backups/smbproxy-updater/* ]] \
    || { echo "invalid updater backup: $BACKUP_DIR" >&2; exit 2; }
systemctl stop smbd.service
if [[ -f "$BACKUP_DIR/vfs-was-manually-installed" ]]; then
    [[ -r "$BACKUP_DIR/vfs-files.tar" ]] \
        || { echo "VFS file backup is missing" >&2; exit 2; }
    dpkg --purge smbproxy-session-vfs 2>/dev/null || true
    tar --acls --xattrs -xpf "$BACKUP_DIR/vfs-files.tar" -C /
else
    package="$BACKUP_DIR/smbproxy-session-vfs-rollback.deb"
    [[ -r "$package" ]] \
        || { echo "rollback package is missing" >&2; exit 2; }
    dpkg -i "$package"
fi
/usr/local/sbin/smbproxy-vfs-version-check
testparm -s /etc/samba/smb.conf >/dev/null
if [[ -f "$BACKUP_DIR/smbd-was-active" ]]; then
    systemctl start smbd.service
    systemctl is-active --quiet smbd.service
fi
if [[ -f "$BACKUP_DIR/timer-was-active" ]]; then
    systemctl start smbproxy-share-worker.timer
fi
echo "Previous VFS installation restored. Appliance configuration was not changed."
