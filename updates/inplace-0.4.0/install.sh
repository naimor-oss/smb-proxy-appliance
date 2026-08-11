#!/usr/bin/env bash
# One-off in-place update for an appliance built before modern-share fail-fast
# and per-downstream-session SMB1 mounts. Existing state and credential files
# are retained; generated smb.conf/fstab entries are migrated surgically.

set -euo pipefail

readonly RELEASE="0.4.0-inplace7"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$SCRIPT_DIR/payload"
BACKUP_ROOT="${SMBPROXY_UPDATE_BACKUP_ROOT:-/var/backups/smbproxy-updater}"
WORK=""
BACKUP_DIR=""
ROLLBACK_NEEDED=0

log() { printf '\n==> %s\n' "$*"; }
die() { echo "ERROR: $*" >&2; exit 2; }
mount_active() {
    awk -v mp="$1" '$2 == mp && $3 == "cifs" { found=1 } END { exit !found }' /proc/mounts
}
unit_for() {
    systemd-escape --path --suffix="$1" "$2"
}
version_branch() {
    sed -E 's/^[0-9]+://; s/^([0-9]+\.[0-9]+).*/\1/' <<< "$1"
}

on_exit() {
    local rc=$?
    [[ -z "$WORK" ]] || rm -rf "$WORK"
    if [[ $rc -ne 0 && $ROLLBACK_NEEDED -eq 1 && -n "$BACKUP_DIR" ]]; then
        echo "Update failed; restoring the saved appliance configuration..." >&2
        "$BACKUP_DIR/rollback.sh" "$BACKUP_DIR" || \
            echo "AUTOMATIC ROLLBACK FAILED — run: sudo $BACKUP_DIR/rollback.sh $BACKUP_DIR" >&2
    fi
    exit "$rc"
}
trap on_exit EXIT

[[ ${EUID:-$(id -u)} -eq 0 ]] || die "run this installer with sudo"
[[ -f /etc/samba/smb.conf && -f /etc/fstab ]] \
    || die "this does not look like a configured SMB Proxy appliance"
[[ -d /var/lib/smbproxy/shares ]] || die "share state directory is missing"
for command in apt-cache apt-get dpkg-query flock mount sha256sum smbd smbstatus \
    systemctl systemd-escape systemd-tmpfiles tar testparm timeout umount; do
    command -v "$command" >/dev/null 2>&1 || die "required command is missing: $command"
done
for file in smbproxy-sconfig.sh smbproxy-probe-backend smbproxy-share-worker \
    smbproxy-session-mount smbproxy-vfs-version-check \
    samba-vfs/build-module.sh samba-vfs/vfs_smbproxy_session.c; do
    [[ -f "$PAYLOAD/$file" ]] || die "updater payload is incomplete: $file"
done

exec 9>/run/lock/smbproxy-inplace-updater.lock
flock -n 9 || die "another SMB Proxy update is running"

module_root=$(smbd -b | awk -F': ' '/MODULESDIR/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
[[ -n "$module_root" ]] || die "could not determine Samba module directory"
module_path="$module_root/vfs/smbproxy_session.so"
fileid_module="$module_root/vfs/fileid.so"
[[ -r "$fileid_module" ]] || die "Samba's required fileid VFS module is missing: $fileid_module"

smbd_was_active=0
systemctl is-active --quiet smbd.service && smbd_was_active=1
active_clients=$(smbstatus --processes 2>/dev/null \
    | awk '$1 ~ /^[0-9]+$/ { count++ } END { print count+0 }')
if (( active_clients != 0 )); then
    [[ "${SMBPROXY_DRAIN_CLIENTS:-0}" == "1" ]] \
        || die "$active_clients active SMB client process(es); disconnect users before updating"
    log "Disconnecting $active_clients explicitly approved idle SMB client process(es)"
    systemctl stop smbd.service
    active_clients=$(smbstatus --processes 2>/dev/null \
        | awk '$1 ~ /^[0-9]+$/ { count++ } END { print count+0 }')
    (( active_clients == 0 )) || die "SMB clients remain after stopping smbd"
fi

timestamp=$(date -u +%Y%m%dT%H%M%SZ)
BACKUP_DIR="$BACKUP_ROOT/$timestamp"
install -d -m 0700 "$BACKUP_DIR"

log "Saving current appliance configuration to $BACKUP_DIR"
paths=(etc/fstab)
for path in \
    /etc/samba /etc/smbproxy /var/lib/smbproxy \
    /usr/local/sbin/smbproxy-sconfig \
    /usr/local/sbin/smbproxy-probe-backend \
    /usr/local/sbin/smbproxy-share-worker \
    /usr/local/sbin/smbproxy-session-mount \
    /usr/local/sbin/smbproxy-vfs-version-check \
    /etc/systemd/system/smbproxy-share-worker.service \
    /etc/systemd/system/smbproxy-share-worker.timer \
    /etc/systemd/system/smbd.service.d/20-smbproxy-session-integrity.conf \
    /etc/tmpfiles.d/smbproxy-sessions.conf \
    /usr/lib/smbproxy/samba-version \
    /usr/lib/smbproxy/vfs-source.sha256 \
    "$module_path"; do
    if [[ -e "$path" ]]; then
        paths+=("${path#/}")
    else
        printf '%s\n' "$path" >> "$BACKUP_DIR/introduced-paths"
    fi
done
for introduced in \
    /etc/smbproxy/inplace-update-release \
    /var/lib/smbproxy/health; do
    [[ -e "$introduced" ]] || printf '%s\n' "$introduced" >> "$BACKUP_DIR/introduced-paths"
done
: > "$BACKUP_DIR/introduced-paths.tmp"
if [[ -f "$BACKUP_DIR/introduced-paths" ]]; then
    sort -u "$BACKUP_DIR/introduced-paths" > "$BACKUP_DIR/introduced-paths.tmp"
fi
mv "$BACKUP_DIR/introduced-paths.tmp" "$BACKUP_DIR/introduced-paths"
tar --acls --xattrs -cpf "$BACKUP_DIR/config.tar" -C / "${paths[@]}"
chmod 0600 "$BACKUP_DIR/config.tar" "$BACKUP_DIR/introduced-paths"
install -m 0700 "$SCRIPT_DIR/rollback.sh" "$BACKUP_DIR/rollback.sh"
(( smbd_was_active == 1 )) && : > "$BACKUP_DIR/smbd-was-active" || true
systemctl is-enabled --quiet smbproxy-share-worker.timer 2>/dev/null \
    && : > "$BACKUP_DIR/timer-was-enabled" || true
awk '$3 == "cifs" { print $2 }' /proc/mounts > "$BACKUP_DIR/active-mounts"
chmod 0600 "$BACKUP_DIR/active-mounts"
dpkg-query -W samba samba-common-bin samba-libs winbind libwbclient0 \
    > "$BACKUP_DIR/package-versions.before"
chmod 0600 "$BACKUP_DIR/package-versions.before"
ROLLBACK_NEEDED=1

log "Preparing a password-free migration of existing share configuration"
WORK=$(mktemp -d /tmp/smbproxy-inplace-update.XXXXXX)
install -m 0644 /etc/samba/smb.conf "$WORK/smb.conf"
install -m 0644 /etc/fstab "$WORK/fstab"
SMBPROXY_MIGRATE_SMB_CONF="$WORK/smb.conf" \
SMBPROXY_MIGRATE_FSTAB="$WORK/fstab" \
SMBPROXY_MIGRATE_SHARES_DIR=/var/lib/smbproxy/shares \
SMBPROXY_MIGRATE_MANIFEST="$WORK/mounts" \
SMBPROXY_MIGRATE_TESTPARM_BIN=testparm \
    "$SCRIPT_DIR/migrate-config.sh"
testparm -s "$WORK/smb.conf" >/dev/null

log "Stopping new connections and retiring old static mounts"
systemctl stop smbproxy-share-worker.timer smbproxy-share-worker.service 2>/dev/null || true
systemctl stop smbd.service

while IFS=$'\t' read -r _profile _mode _share mountpoint; do
    [[ -n "$mountpoint" ]] || continue
    automount_unit=$(unit_for automount "$mountpoint")
    mount_unit=$(unit_for mount "$mountpoint")
    timeout 30 systemctl stop "$automount_unit" 2>/dev/null || true
    timeout 30 systemctl stop "$mount_unit" 2>/dev/null || true
    systemctl is-active --quiet "$automount_unit" 2>/dev/null \
        && die "automount unit remains active for $mountpoint"
    layers=0
    while mount_active "$mountpoint"; do
        layers=$((layers + 1))
        (( layers <= 32 )) || die "too many stacked mounts at $mountpoint"
        timeout 30 umount "$mountpoint" \
            || die "could not cleanly unmount $mountpoint; bring its backend online and retry"
    done
done < "$WORK/mounts"

log "Selecting a supported Samba patch revision and installing its testsuite"
apt-get update -y
installed_samba=$(dpkg-query -W -f='${Version}' samba)
target_samba=$(apt-cache policy samba | awk '/Candidate:/ { print $2; exit }')
[[ -n "$target_samba" && "$target_samba" != "(none)" ]] \
    || die "APT has no Samba candidate"
[[ "$(version_branch "$target_samba")" == "$(version_branch "$installed_samba")" ]] \
    || die "refusing Samba branch change: installed=$installed_samba candidate=$target_samba"
DEBIAN_FRONTEND=noninteractive apt-get install -y \
    "samba=$target_samba" "samba-testsuite=$target_samba"
[[ "$(dpkg-query -W -f='${Version}' samba)" == "$target_samba" ]] \
    || die "Samba did not reach the selected revision $target_samba"
# Package maintainer scripts must not reopen the frontend during the
# maintenance window, even if their restart policy changes in a future update.
systemctl stop smbd.service 2>/dev/null || true

payload_vfs_hash=$(sha256sum "$PAYLOAD/samba-vfs/vfs_smbproxy_session.c" \
    | awk '{ print $1 }')
if [[ -r "$module_path" \
      && "$(cat /usr/lib/smbproxy/samba-version 2>/dev/null || true)" == "$target_samba" \
      && "$(cat /usr/lib/smbproxy/vfs-source.sha256 2>/dev/null || true)" == "$payload_vfs_hash" ]]; then
    log "Using the already validated session VFS build for Samba package $target_samba"
else
    log "Building the session VFS module for Samba package $target_samba"
    SMBPROXY_SKIP_AUTOREMOVE=1 "$PAYLOAD/samba-vfs/build-module.sh" \
        "$PAYLOAD/samba-vfs/vfs_smbproxy_session.c"
fi
[[ "$(dpkg-query -W -f='${Version}' samba)" == "$target_samba" ]] \
    || die "Samba changed version during the build; refusing to migrate configuration"
[[ -r "$module_path" \
   && "$(cat /usr/lib/smbproxy/vfs-source.sha256 2>/dev/null || true)" == "$payload_vfs_hash" ]] \
    || die "session VFS module did not reach the validated payload revision"

log "Installing updater payload and migrated configuration"
install -m 0755 "$PAYLOAD/smbproxy-sconfig.sh" /usr/local/sbin/smbproxy-sconfig
install -m 0755 "$PAYLOAD/smbproxy-probe-backend" /usr/local/sbin/smbproxy-probe-backend
install -m 0755 "$PAYLOAD/smbproxy-share-worker" /usr/local/sbin/smbproxy-share-worker
install -m 0755 "$PAYLOAD/smbproxy-session-mount" /usr/local/sbin/smbproxy-session-mount
install -m 0755 "$PAYLOAD/smbproxy-vfs-version-check" /usr/local/sbin/smbproxy-vfs-version-check
install -m 0644 "$WORK/smb.conf" /etc/samba/smb.conf
install -m 0644 "$WORK/fstab" /etc/fstab

install -d -o root -g root -m 0755 \
    /run/smbproxy/sessions /run/smbproxy/session-state \
    /etc/tmpfiles.d /etc/systemd/system/smbd.service.d /usr/lib/smbproxy
cat > /etc/tmpfiles.d/smbproxy-sessions.conf <<'EOF'
d /run/smbproxy 0755 root root -
d /run/smbproxy/sessions 0755 root root -
d /run/smbproxy/session-state 0755 root root -
EOF
cat > /etc/systemd/system/smbd.service.d/20-smbproxy-session-integrity.conf <<'EOF'
[Service]
ExecStartPre=/usr/local/sbin/smbproxy-vfs-version-check
ExecStartPre=/usr/local/sbin/smbproxy-session-mount cleanup-all
ExecStopPost=/usr/local/sbin/smbproxy-session-mount cleanup-all
EOF
cat > /etc/systemd/system/smbproxy-share-worker.service <<'EOF'
[Unit]
Description=SMB Proxy backend health and queued delivery worker
After=network-online.target local-fs.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/smbproxy-share-worker
TimeoutStartSec=infinity
EOF
cat > /etc/systemd/system/smbproxy-share-worker.timer <<'EOF'
[Unit]
Description=Run SMB Proxy share worker every 15 seconds

[Timer]
OnBootSec=30s
OnUnitActiveSec=15s
AccuracySec=1s
Persistent=true
Unit=smbproxy-share-worker.service

[Install]
WantedBy=timers.target
EOF

testparm -s /etc/samba/smb.conf >/dev/null
/usr/local/sbin/smbproxy-vfs-version-check
systemctl daemon-reload
systemd-tmpfiles --create /etc/tmpfiles.d/smbproxy-sessions.conf
/usr/local/sbin/smbproxy-session-mount cleanup-all

while IFS=$'\t' read -r profile _mode _share mountpoint; do
    if [[ "$profile" == "modern" ]]; then
        systemctl start "$(unit_for automount "$mountpoint")"
    fi
done < "$WORK/mounts"

if [[ -f "$BACKUP_DIR/smbd-was-active" ]]; then
    systemctl start smbd.service
    systemctl is-active --quiet smbd.service
fi
systemctl enable --now smbproxy-share-worker.timer
systemctl start smbproxy-share-worker.service

install -d -m 0755 /etc/smbproxy
printf '%s\n' "$RELEASE" > /etc/smbproxy/inplace-update-release
chmod 0644 /etc/smbproxy/inplace-update-release

ROLLBACK_NEEDED=0
log "Update complete"
echo "Configuration backup: $BACKUP_DIR"
echo "Rollback command: sudo $BACKUP_DIR/rollback.sh $BACKUP_DIR"
echo "Locking release gate: lab/run-scenario.sh tps-lock-isolation"
