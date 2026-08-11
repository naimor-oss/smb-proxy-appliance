#!/usr/bin/env bash
# Migrate existing generated share sections without reading or rewriting
# backend passwords.  All paths have test seams so the one-off updater can be
# exercised against fixtures before it is used on an appliance.

set -euo pipefail

SMB_CONF="${SMBPROXY_MIGRATE_SMB_CONF:-/etc/samba/smb.conf}"
FSTAB="${SMBPROXY_MIGRATE_FSTAB:-/etc/fstab}"
SHARES_DIR="${SMBPROXY_MIGRATE_SHARES_DIR:-/var/lib/smbproxy/shares}"
MANIFEST="${SMBPROXY_MIGRATE_MANIFEST:-/tmp/smbproxy-updater-mounts}"
TESTPARM_BIN="${SMBPROXY_MIGRATE_TESTPARM_BIN:-testparm}"

die() { echo "migrate-config: $*" >&2; exit 2; }
file_mode() {
    stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"
}

[[ -f "$SMB_CONF" ]] || die "missing Samba configuration: $SMB_CONF"
[[ -f "$FSTAB" ]] || die "missing fstab: $FSTAB"
[[ -d "$SHARES_DIR" ]] || die "missing share state directory: $SHARES_DIR"

work=$(mktemp -d "${TMPDIR:-/tmp}/smbproxy-migrate.XXXXXX")
trap 'rm -rf "$work"' EXIT
cp -p "$SMB_CONF" "$work/smb.conf"
cp -p "$FSTAB" "$work/fstab"
: > "$work/mounts"

migrate_section() {
    local name="$1" profile="$2" mode="$3"
    local section existing_vfs custom_preexec next="$work/smb.conf.next"

    section=$(awk -v target="[$name]" '
        BEGIN { in_section=0 }
        tolower($0) == tolower(target) { in_section=1; print; next }
        /^\[/ { in_section=0 }
        in_section { print }
    ' "$work/smb.conf")

    # A state file may represent a backend configured before domain join, in
    # which case no frontend section exists yet and there is nothing to edit.
    [[ -n "$section" ]] || return 0

    if [[ "$profile" == "legacy" ]]; then
        existing_vfs=$(grep -ciE '^[[:space:]]*vfs objects[[:space:]]*=' <<< "$section" || true)
        (( existing_vfs <= 1 )) \
            || die "share '$name' has multiple vfs objects directives; refusing to guess their order"
    fi

    if [[ "$profile" == "modern" && "$mode" == "direct" ]]; then
        custom_preexec=$(grep -iE '^[[:space:]]*root preexec[[:space:]]*=' <<< "$section" \
            | grep -ivF '/usr/local/sbin/smbproxy-probe-backend' || true)
        [[ -z "$custom_preexec" ]] \
            || die "share '$name' has a custom root preexec; preserving it requires manual composition"
    fi

    awk -v target="[$name]" -v profile="$profile" -v mode="$mode" '
        function emit_missing(    extra) {
            if (!in_target) return
            if (profile == "legacy") {
                if (!saw_path) print "    path = /run/smbproxy/sessions"
                if (!saw_vfs) print "    vfs objects = smbproxy_session fileid"
                if (!saw_fileid_algorithm) print "    fileid:algorithm = fsname"
            }
            if (profile == "modern" && mode == "direct") {
                if (!saw_probe) print "    root preexec = /usr/local/sbin/smbproxy-probe-backend \"%S\""
                if (!saw_probe_close) print "    root preexec close = yes"
            }
        }
        function reset_target() {
            saw_path=0; saw_vfs=0; saw_fileid_algorithm=0; saw_probe=0; saw_probe_close=0
        }
        function vfs_line(line,    rhs,n,a,i,out) {
            rhs=line
            sub(/^[^=]*=/, "", rhs)
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", rhs)
            n=split(rhs, a, /[[:space:]]+/)
            out="smbproxy_session fileid"
            for (i=1; i<=n; i++) {
                if (a[i] != "" && a[i] != "smbproxy_session" && a[i] != "fileid") out=out " " a[i]
            }
            return "    vfs objects = " out
        }
        BEGIN { in_target=0; reset_target() }
        /^\[/ {
            emit_missing()
            in_target=(tolower($0) == tolower(target))
            reset_target()
            print
            next
        }
        !in_target { print; next }
        /^[[:space:]]*#[[:space:]]*smbproxy-health:[[:space:]]*backend unavailable[[:space:]]*$/ {
            drop_available=1
            next
        }
        drop_available && /^[[:space:]]*available[[:space:]]*=[[:space:]]*no[[:space:]]*$/ {
            drop_available=0
            next
        }
        {
            drop_available=0
            lower=tolower($0)
        }
        profile == "legacy" && lower ~ /^[[:space:]]*path[[:space:]]*=/ {
            if (!saw_path) print "    path = /run/smbproxy/sessions"
            saw_path=1
            next
        }
        profile == "legacy" && lower ~ /^[[:space:]]*vfs objects[[:space:]]*=/ {
            if (!saw_vfs) print vfs_line($0)
            saw_vfs=1
            next
        }
        profile == "legacy" && lower ~ /^[[:space:]]*fileid:algorithm[[:space:]]*=/ {
            if (!saw_fileid_algorithm) print "    fileid:algorithm = fsname"
            saw_fileid_algorithm=1
            next
        }
        lower ~ /^[[:space:]]*root preexec[[:space:]]*=/ \
            && index(lower, "/usr/local/sbin/smbproxy-probe-backend") != 0 {
            if (profile == "modern" && mode == "direct" && !saw_probe) {
                print "    root preexec = /usr/local/sbin/smbproxy-probe-backend \"%S\""
                saw_probe=1
            } else {
                removed_probe=1
            }
            next
        }
        lower ~ /^[[:space:]]*root preexec close[[:space:]]*=/ {
            if (profile == "modern" && mode == "direct" && !saw_probe_close) {
                print "    root preexec close = yes"
                saw_probe_close=1
            } else if (!removed_probe) {
                print
            }
            next
        }
        { print }
        END { emit_missing() }
    ' "$work/smb.conf" > "$next"
    mv "$next" "$work/smb.conf"
}

migrate_fstab() {
    local mountpoint="$1" profile="$2" next="$work/fstab.next" rc=0
    awk -v mp="$mountpoint" -v profile="$profile" '
        function append_opt(current, value) {
            return current == "" ? value : current "," value
        }
        BEGIN { found=0 }
        $0 !~ /^[[:space:]]*#/ && $2 == mp && $3 == "cifs" {
            found++
            if (profile == "legacy") next
            n=split($4, a, ",")
            opts=""
            for (i=1; i<=n; i++) {
                if (a[i] == "hard" || a[i] == "soft" || a[i] ~ /^echo_interval=/ \
                    || a[i] ~ /^x-systemd\.mount-timeout=/) continue
                opts=append_opt(opts, a[i])
            }
            opts=append_opt(opts, "soft")
            opts=append_opt(opts, "echo_interval=10")
            opts=append_opt(opts, "x-systemd.mount-timeout=4")
            $4=opts
            print
            next
        }
        { print }
        END {
            if (profile == "modern" && found != 1) exit 42
        }
    ' "$work/fstab" > "$next" || rc=$?
    if [[ $rc -eq 42 ]]; then
        rm -f "$next"
        die "modern share mount '$mountpoint' does not have exactly one CIFS fstab entry"
    elif [[ $rc -ne 0 ]]; then
        rm -f "$next"
        return "$rc"
    fi
    mv "$next" "$work/fstab"
}

shopt -s nullglob
states=("$SHARES_DIR"/*.env)
shopt -u nullglob
(( ${#states[@]} > 0 )) || die "no configured share state files found"

for state in "${states[@]}"; do
    SHARE_NAME="" PROFILE="" OFFLINE_MODE="" BACKEND_MOUNT=""
    # shellcheck disable=SC1090
    source "$state"
    [[ -n "$SHARE_NAME" && -n "$BACKEND_MOUNT" ]] \
        || die "incomplete share state: $state"
    PROFILE="${PROFILE:-legacy}"
    OFFLINE_MODE="${OFFLINE_MODE:-direct}"
    case "$PROFILE:$OFFLINE_MODE" in
        legacy:direct|modern:direct|modern:queued) : ;;
        *) die "unsupported share mode '$PROFILE:$OFFLINE_MODE' for '$SHARE_NAME'" ;;
    esac
    [[ "$SHARE_NAME" != *$'\t'* && "$SHARE_NAME" != *$'\n'* \
        && "$BACKEND_MOUNT" != *$'\t'* && "$BACKEND_MOUNT" != *$'\n'* ]] \
        || die "tabs/newlines are not supported in share state"

    migrate_section "$SHARE_NAME" "$PROFILE" "$OFFLINE_MODE"
    migrate_fstab "$BACKEND_MOUNT" "$PROFILE"
    printf '%s\t%s\t%s\t%s\n' "$PROFILE" "$OFFLINE_MODE" \
        "$SHARE_NAME" "$BACKEND_MOUNT" >> "$work/mounts"
done

if command -v "$TESTPARM_BIN" >/dev/null 2>&1; then
    "$TESTPARM_BIN" -s "$work/smb.conf" >/dev/null
fi

chmod "$(file_mode "$SMB_CONF")" "$work/smb.conf"
chmod "$(file_mode "$FSTAB")" "$work/fstab"
mv "$work/smb.conf" "$SMB_CONF"
mv "$work/fstab" "$FSTAB"
install -m 0600 "$work/mounts" "$MANIFEST"
