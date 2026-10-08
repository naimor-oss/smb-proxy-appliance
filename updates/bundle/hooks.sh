# shellcheck shell=bash
# SMB proxy update hooks for the appliance-core update framework
# (appliance-core docs/lib-update.md). Sourced by the bundle's install.sh and
# saved into every backup for rollback.
#
# Policy: replace the appliance's own scripts and the vendored appliance-core
# libs; never change Debian packages (Samba stays held, the VFS package is
# untouched); install a script that did not exist before only when it is
# required by the scripts being installed.

SMBPROXY_SBIN="${SMBPROXY_UPDATE_SBIN:-/usr/local/sbin}"
SMBPROXY_LIBDIR="${SMBPROXY_UPDATE_LIBDIR:-/usr/local/lib/appliance-core}"
SMBPROXY_STATE_ROOT="${SMBPROXY_UPDATE_STATE_ROOT:-/var/lib/smbproxy}"
SMBPROXY_ETC="${SMBPROXY_UPDATE_ETC:-/etc/smbproxy}"
SMBPROXY_SMB_CONF="${SMBPROXY_UPDATE_SMB_CONF:-/etc/samba/smb.conf}"
SMBPROXY_RUN_STATE="${SMBPROXY_UPDATE_RUN_STATE:-/run/smbproxy-update.state}"
# payload/sbin file -> installed name; "required" scripts are installed even
# when absent (the rest only replace an existing copy).
SMBPROXY_REQUIRED_SCRIPTS=(smbproxy-sconfig smbproxy-session-mount smbproxy-share-worker
    smbproxy-vfs-version-check smbproxy-probe-backend smbproxy-update)
SMBPROXY_OPTIONAL_SCRIPTS=(smbproxy-domain-dns smbproxy-samba-hold smbproxy-firstboot smbproxy-init)
SMBPROXY_MOTD=(15-smbproxy-net-status 17-smbproxy-samba)
SMBPROXY_SHARE_KEYS=(SHARE_NAME PROFILE OFFLINE_MODE BACKEND_IP BACKEND_USER BACKEND_DOMAIN
    BACKEND_MOUNT BACKEND_VERS BACKEND_SEAL FRONT_GROUP FRONT_FORCE_USER LOCKING_OVERRIDE)

# Units built before release identity carry the one-off updater's marker.
update_detect_version() {
    local f="$SMBPROXY_ETC/inplace-update-release"
    [[ -r "$f" ]] || return 0
    head -1 "$f" | tr -cd 'A-Za-z0-9.+~-'
}

update_backup_paths() {
    local s m
    printf '%s\n' /etc/samba /etc/fstab "$SMBPROXY_ETC" "$SMBPROXY_STATE_ROOT" "$SMBPROXY_LIBDIR" \
        /etc/systemd/system/smbproxy-share-worker.service \
        /etc/systemd/system/smbproxy-share-worker.timer
    for s in "${SMBPROXY_REQUIRED_SCRIPTS[@]}" "${SMBPROXY_OPTIONAL_SCRIPTS[@]}"; do
        printf '%s\n' "$SMBPROXY_SBIN/$s"
    done
    for m in "${SMBPROXY_MOTD[@]}"; do printf '%s\n' "/etc/update-motd.d/$m"; done
}

# Every persisted state file must parse with the new strict parser, or the
# share would be withdrawn after the update. Refuse instead, naming the file.
_smbproxy_state_problems() {
    local f bad=""
    for f in "$SMBPROXY_STATE_ROOT"/shares/*.env; do
        [[ -e "$f" ]] || continue
        appcore_kv_load "$f" "${SMBPROXY_SHARE_KEYS[@]}" >/dev/null 2>&1 || bad+=" $f"
    done
    if [[ -e "$SMBPROXY_ETC/nic-roles.env" ]]; then
        appcore_kv_load "$SMBPROXY_ETC/nic-roles.env" DOMAIN_NIC_NAME DOMAIN_NIC_MAC \
            LEGACY_NIC_NAME LEGACY_NIC_MAC >/dev/null 2>&1 || bad+=" $SMBPROXY_ETC/nic-roles.env"
    fi
    if [[ -e "$SMBPROXY_STATE_ROOT/deploy.env" ]]; then
        appcore_kv_load "$SMBPROXY_STATE_ROOT/deploy.env" REALM DOMAIN_SHORT DC_HOST DC_IP \
            >/dev/null 2>&1 || bad+=" $SMBPROXY_STATE_ROOT/deploy.env"
    fi
    printf '%s' "$bad"
}

update_preflight() {
    local c bad
    for c in systemctl testparm tar flock sha256sum; do
        command -v "$c" >/dev/null 2>&1 || { echo "required command missing: $c" >&2; return 1; }
    done
    [[ -f "$SMBPROXY_SMB_CONF" && -d "$SMBPROXY_STATE_ROOT/shares" ]] \
        || { echo "this does not look like a configured SMB proxy" >&2; return 1; }
    bad=$(_smbproxy_state_problems)
    if [[ -n "$bad" ]]; then
        echo "state files the new parser cannot read (fix or re-save them first):$bad" >&2
        return 1
    fi
    if [[ -x "$SMBPROXY_SBIN/smbproxy-vfs-version-check" ]] \
        && ! "$SMBPROXY_SBIN/smbproxy-vfs-version-check" >/dev/null 2>&1; then
        echo "the VFS/Samba version guard fails before the update; fix that first" >&2
        return 1
    fi
}

update_stop() {
    : > "$SMBPROXY_RUN_STATE"
    if systemctl is-enabled --quiet smbproxy-share-worker.timer 2>/dev/null; then
        echo timer-enabled >> "$SMBPROXY_RUN_STATE"
    fi
    systemctl stop smbproxy-share-worker.timer smbproxy-share-worker.service 2>/dev/null || true
}

update_apply() {
    local b="$1" s m
    install -d -m 0755 "$SMBPROXY_LIBDIR" "$SMBPROXY_SBIN" || return 1
    install -m 0644 "$b"/lib/*.sh "$SMBPROXY_LIBDIR/" || return 1
    install -m 0644 "$b/lib/VERSION" "$SMBPROXY_LIBDIR/VERSION" || return 1
    for s in "${SMBPROXY_REQUIRED_SCRIPTS[@]}"; do
        install -m 0755 "$b/payload/sbin/$s" "$SMBPROXY_SBIN/$s" || return 1
    done
    for s in "${SMBPROXY_OPTIONAL_SCRIPTS[@]}"; do
        if [[ -e "$SMBPROXY_SBIN/$s" ]]; then
            install -m 0755 "$b/payload/sbin/$s" "$SMBPROXY_SBIN/$s" || return 1
        else
            echo "  not installed on this unit, left absent: $s"
        fi
    done
    for m in "${SMBPROXY_MOTD[@]}"; do
        if [[ -e "/etc/update-motd.d/$m" ]]; then
            install -m 0755 "$b/payload/motd/$m" "/etc/update-motd.d/$m" || return 1
        fi
    done
    if [[ -f "$b/payload/appcore-commit" ]]; then
        install -m 0644 "$b/payload/appcore-commit" "$SMBPROXY_LIBDIR/COMMIT" || return 1
    fi
}

update_verify() {
    local s bad
    for s in "${SMBPROXY_REQUIRED_SCRIPTS[@]}" "${SMBPROXY_OPTIONAL_SCRIPTS[@]}"; do
        [[ -e "$SMBPROXY_SBIN/$s" ]] || continue
        bash -n "$SMBPROXY_SBIN/$s" || { echo "installed $s does not parse" >&2; return 1; }
    done
    testparm -s "$SMBPROXY_SMB_CONF" >/dev/null 2>&1 \
        || { echo "smb.conf fails testparm after the update" >&2; return 1; }
    "$SMBPROXY_SBIN/smbproxy-vfs-version-check" >/dev/null 2>&1 \
        || { echo "VFS/Samba version guard fails after the update" >&2; return 1; }
    # The installed parser must read every state file.
    bad=$(
        unset _APPCORE_KVSTATE_LOADED
        # shellcheck disable=SC1091
        source "$SMBPROXY_LIBDIR/kvstate.sh" && _smbproxy_state_problems
    )
    [[ -z "$bad" ]] || { echo "installed parser rejects:$bad" >&2; return 1; }
}

update_start() {
    systemctl daemon-reload || return 1
    if grep -qx timer-enabled "$SMBPROXY_RUN_STATE" 2>/dev/null; then
        systemctl start smbproxy-share-worker.timer || return 1
    fi
    # One worker pass adopts existing frontend sections (ownership marker).
    systemctl start smbproxy-share-worker.service || return 1
    rm -f "$SMBPROXY_RUN_STATE"
}

update_release_fields() {
    local v
    v=$(dpkg-query -W -f='${Version}' samba 2>/dev/null) && echo "SAMBA_VERSION $v"
    v=$(dpkg-query -W -f='${Version}' smbproxy-session-vfs 2>/dev/null) && echo "VFS_VERSION $v"
    [[ -r "$SMBPROXY_LIBDIR/VERSION" ]] && echo "APPCORE_VERSION $(head -1 "$SMBPROXY_LIBDIR/VERSION")"
    [[ -r "$SMBPROXY_LIBDIR/COMMIT" ]] && echo "APPCORE_COMMIT $(head -1 "$SMBPROXY_LIBDIR/COMMIT")"
    return 0
}
