#!/usr/bin/env bash
# Restore the local files saved by install.sh. Package-manager downloads and
# temporary build dependencies are intentionally outside the backup. The
# updater may advance Samba within its installed major/minor branch, and
# rollback intentionally does not downgrade Debian packages.

set -euo pipefail

BACKUP_DIR="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "run rollback as root" >&2; exit 1; }
[[ -f "$BACKUP_DIR/config.tar" && -f "$BACKUP_DIR/introduced-paths" ]] \
    || { echo "invalid updater backup: $BACKUP_DIR" >&2; exit 2; }

systemctl disable --now smbproxy-share-worker.timer 2>/dev/null || true
systemctl stop smbproxy-share-worker.service 2>/dev/null || true
systemctl stop smbd.service 2>/dev/null || true
if [[ -x /usr/local/sbin/smbproxy-session-mount ]]; then
    /usr/local/sbin/smbproxy-session-mount cleanup-all 2>/dev/null || true
fi

while IFS= read -r path; do
    [[ -n "$path" && "$path" == /* && "$path" != "/" ]] || continue
    if [[ -d "$path" && ! -L "$path" ]]; then
        rm -rf -- "$path"
    else
        rm -f -- "$path"
    fi
done < "$BACKUP_DIR/introduced-paths"

tar -xpf "$BACKUP_DIR/config.tar" -C /
systemctl daemon-reload

if [[ -f "$BACKUP_DIR/active-mounts" ]]; then
    while IFS= read -r mountpoint; do
        [[ -n "$mountpoint" ]] || continue
        mount "$mountpoint" 2>/dev/null || true
    done < "$BACKUP_DIR/active-mounts"
fi

if [[ -f "$BACKUP_DIR/smbd-was-active" ]]; then
    systemctl start smbd.service
fi
if [[ -f "$BACKUP_DIR/timer-was-enabled" ]]; then
    systemctl enable --now smbproxy-share-worker.timer
fi

echo "Restored SMB Proxy configuration from $BACKUP_DIR"
