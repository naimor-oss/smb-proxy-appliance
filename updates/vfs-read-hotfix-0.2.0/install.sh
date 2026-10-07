#!/usr/bin/env bash
# One-off install of the signed-SMB1 serialized-read VFS component. Appliance
# configuration is backed up and verified byte-for-byte but never rewritten.

set -euo pipefail

readonly RELEASE="vfs-read-hotfix-0.2.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$SCRIPT_DIR/payload"
BACKUP_ROOT="${SMBPROXY_UPDATE_BACKUP_ROOT:-/var/backups/smbproxy-updater}"
WORK=""
BACKUP_DIR=""
ROLLBACK_NEEDED=0

log() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 2; }

on_exit() {
    local rc=$?
    [[ -z "$WORK" ]] || rm -rf "$WORK"
    if [[ $rc -ne 0 && $ROLLBACK_NEEDED -eq 1 ]]; then
        echo "Update failed; restoring the previous VFS package..." >&2
        "$BACKUP_DIR/rollback.sh" "$BACKUP_DIR" || \
            echo "AUTOMATIC ROLLBACK FAILED — run: sudo $BACKUP_DIR/rollback.sh $BACKUP_DIR" >&2
    fi
    exit "$rc"
}
trap on_exit EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run this installer with sudo"
for command in awk cmp cp date dpkg dpkg-deb dpkg-query find flock grep \
    install mktemp rm sha256sum smbd smbstatus sort systemctl tar testparm \
    xargs; do
    command -v "$command" >/dev/null 2>&1 \
        || die "required command is missing: $command"
done

packages=("$PAYLOAD"/smbproxy-session-vfs_*.deb)
[[ ${#packages[@]} -eq 1 && -f "${packages[0]}" ]] \
    || die "updater payload must contain exactly one VFS package"
package="${packages[0]}"
checksum_file="$package.sha256"
[[ -f "$checksum_file" ]] || die "package checksum is missing"
(cd "$PAYLOAD" && sha256sum -c "$(basename "$checksum_file")")

exec 9>/run/lock/smbproxy-vfs-hotfix.lock
flock -n 9 || die "another VFS update is running"

installed_samba=$(dpkg-query -W -f='${Version}' samba)
package_depends=$(dpkg-deb -f "$package" Depends)
[[ "$package_depends" == "samba (= $installed_samba)" ]] \
    || die "package/Samba mismatch: installed=$installed_samba depends=$package_depends"
old_package_installed=0
if dpkg-query -W -f='${Status}' smbproxy-session-vfs 2>/dev/null \
    | grep -qx 'install ok installed'; then
    old_package_installed=1
fi

active_clients=$(smbstatus --processes 2>/dev/null \
    | awk '$1 ~ /^[0-9]+$/ { count++ } END { print count+0 }')
if (( active_clients != 0 )); then
    [[ "${SMBPROXY_DRAIN_CLIENTS:-0}" == "1" ]] \
        || die "$active_clients active SMB client process(es); disconnect users before updating"
    log "Disconnecting $active_clients explicitly approved SMB client process(es)"
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="$BACKUP_ROOT/$timestamp-$RELEASE"
WORK=$(mktemp -d /tmp/smbproxy-vfs-hotfix.XXXXXX)
install -d -m 0700 "$BACKUP_DIR" "$WORK/old-package/DEBIAN"

smbd_was_active=0
timer_was_active=0
systemctl is-active --quiet smbd.service && smbd_was_active=1
systemctl is-active --quiet smbproxy-share-worker.timer \
    && timer_was_active=1

log "Backing up configuration and the installed VFS package"
config_paths=(etc/fstab etc/samba etc/smbproxy var/lib/smbproxy/shares)
tar --acls --xattrs -cpf "$BACKUP_DIR/config.tar" -C / "${config_paths[@]}"
chmod 0600 "$BACKUP_DIR/config.tar"

module_root=$(smbd -b | awk -F': ' \
    '/MODULESDIR/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
module_path="$module_root/vfs/smbproxy_session.so"
[[ -r "$module_path" ]] || die "installed VFS module is missing: $module_path"
vfs_paths=("${module_path#/}")
for path in /usr/lib/smbproxy /usr/share/smbproxy-session-vfs; do
    [[ -e "$path" ]] && vfs_paths+=("${path#/}")
done
tar --acls --xattrs -cpf "$BACKUP_DIR/vfs-files.tar" -C / "${vfs_paths[@]}"
chmod 0600 "$BACKUP_DIR/vfs-files.tar"

if (( old_package_installed == 1 )); then
    install -d "$WORK/old-package$(dirname "$module_path")" \
        "$WORK/old-package/usr/share"
    install -m 0644 "$module_path" "$WORK/old-package$module_path"
    cp -a /usr/share/smbproxy-session-vfs \
        "$WORK/old-package/usr/share/smbproxy-session-vfs"
    old_version=$(dpkg-query -W -f='${Version}' smbproxy-session-vfs)
    old_arch=$(dpkg-query -W -f='${Architecture}' smbproxy-session-vfs)
    old_depends=$(dpkg-query -W -f='${Depends}' smbproxy-session-vfs)
    cat > "$WORK/old-package/DEBIAN/control" <<CONTROL
Package: smbproxy-session-vfs
Version: $old_version
Architecture: $old_arch
Maintainer: Naimor, Inc. <admin@naimorinc.com>
Depends: $old_depends
Section: net
Priority: optional
Description: rollback copy of the SMB proxy session VFS module
CONTROL
    dpkg-deb --build --root-owner-group "$WORK/old-package" \
        "$BACKUP_DIR/smbproxy-session-vfs-rollback.deb" >/dev/null
else
    : > "$BACKUP_DIR/vfs-was-manually-installed"
fi
install -m 0700 "$SCRIPT_DIR/rollback.sh" "$BACKUP_DIR/rollback.sh"
if (( smbd_was_active == 1 )); then
    : > "$BACKUP_DIR/smbd-was-active"
fi
if (( timer_was_active == 1 )); then
    : > "$BACKUP_DIR/timer-was-active"
fi
ROLLBACK_NEEDED=1

log "Installing $RELEASE without changing appliance configuration"
systemctl stop smbproxy-share-worker.timer smbproxy-share-worker.service \
    2>/dev/null || true
systemctl stop smbd.service
find /etc/samba /etc/smbproxy /var/lib/smbproxy/shares -xdev -type f -print0 \
    | sort -z | xargs -0 sha256sum > "$BACKUP_DIR/config.sha256.before"
sha256sum /etc/fstab >> "$BACKUP_DIR/config.sha256.before"
chmod 0600 "$BACKUP_DIR/config.sha256.before"
dpkg -i "$package"
/usr/local/sbin/smbproxy-vfs-version-check
testparm -s /etc/samba/smb.conf >/dev/null

find /etc/samba /etc/smbproxy /var/lib/smbproxy/shares -xdev -type f -print0 \
    | sort -z | xargs -0 sha256sum > "$WORK/config.sha256.after"
sha256sum /etc/fstab >> "$WORK/config.sha256.after"
cmp "$BACKUP_DIR/config.sha256.before" "$WORK/config.sha256.after" \
    || die "appliance configuration changed unexpectedly"

if (( smbd_was_active == 1 )); then
    systemctl start smbd.service
    systemctl is-active --quiet smbd.service
fi
if (( timer_was_active == 1 )); then
    systemctl start smbproxy-share-worker.timer
fi

ROLLBACK_NEEDED=0
log "Update complete"
echo "Configuration backup: $BACKUP_DIR/config.tar"
echo "Rollback command: sudo $BACKUP_DIR/rollback.sh $BACKUP_DIR"
echo "Required acceptance: downstream large-file hash, CIFS error log, and two-user ProfitFab test"
