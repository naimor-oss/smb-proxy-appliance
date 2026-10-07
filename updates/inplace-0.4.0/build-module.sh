#!/usr/bin/env bash
# Frozen build helper for the already-deployed 0.4.0-inplace7 updater. Future
# appliance images consume the standalone smbproxy-session-vfs package.

set -euo pipefail

MODULE_SOURCE="${1:-/tmp/samba-vfs/vfs_smbproxy_session.c}"
[[ -f "$MODULE_SOURCE" ]] || { echo "missing VFS source: $MODULE_SOURCE" >&2; exit 2; }

BUILD_ROOT=$(mktemp -d /tmp/smbproxy-vfs-build.XXXXXX)
MANUAL_BEFORE="$BUILD_ROOT/manual-before"
SOURCE_LIST=/etc/apt/sources.list.d/smbproxy-vfs-build.sources
MANUAL_MARKS_RESTORED=0
restore_manual_marks() {
    [[ $MANUAL_MARKS_RESTORED -eq 0 && -f "$MANUAL_BEFORE" ]] || return 0
    apt-mark showmanual | sort > "$BUILD_ROOT/manual-after"
    comm -13 "$MANUAL_BEFORE" "$BUILD_ROOT/manual-after" > "$BUILD_ROOT/manual-new"
    if [[ -s "$BUILD_ROOT/manual-new" ]]; then
        xargs apt-mark auto < "$BUILD_ROOT/manual-new" >/dev/null
    fi
    MANUAL_MARKS_RESTORED=1
}
cleanup() {
    local rc=$?
    trap - EXIT
    set +e
    restore_manual_marks
    rm -f "$SOURCE_LIST"
    rm -rf "$BUILD_ROOT"
    exit "$rc"
}
trap cleanup EXIT

apt-mark showmanual | sort > "$MANUAL_BEFORE"
SAMBA_DEB_VERSION=$(dpkg-query -W -f='${Version}' samba)

if ! grep -qE '^Types:.*[[:space:]]deb-src([[:space:]]|$)' \
    /etc/apt/sources.list.d/debian.sources; then
    [[ ! -e "$SOURCE_LIST" ]] || {
        echo "temporary apt source path already exists: $SOURCE_LIST" >&2
        exit 2
    }
    awk '
        /^Types:/ { print "Types: deb-src"; next }
        { print }
    ' /etc/apt/sources.list.d/debian.sources > "$SOURCE_LIST"
fi

apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get build-dep -y \
    "samba=${SAMBA_DEB_VERSION}"
(
    cd "$BUILD_ROOT"
    apt-get source "samba=${SAMBA_DEB_VERSION}"
)

SAMBA_SOURCE=$(find "$BUILD_ROOT" -mindepth 1 -maxdepth 1 -type d -name 'samba-*' -print -quit)
[[ -n "$SAMBA_SOURCE" ]] || { echo "downloaded Samba source directory not found" >&2; exit 3; }

install -m 0644 "$MODULE_SOURCE" \
    "$SAMBA_SOURCE/source3/modules/vfs_smbproxy_session.c"
cat >> "$SAMBA_SOURCE/source3/modules/wscript_build" <<'WAF'

bld.SAMBA3_MODULE('vfs_smbproxy_session',
                 subsystem='vfs',
                 source='vfs_smbproxy_session.c',
                 deps='samba-util',
                 init_function='vfs_smbproxy_session_init',
                 internal_module=False,
                 enabled=True)
WAF

MODULE_ROOT=$(smbd -b | awk -F': ' '/MODULESDIR/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
[[ -n "$MODULE_ROOT" ]] || { echo "could not determine Samba MODULESDIR" >&2; exit 4; }

(
    cd "$SAMBA_SOURCE"
    if grep -q '^configure:' debian/rules; then
        configure_target=configure
    elif grep -q '^override_dh_auto_configure:' debian/rules; then
        configure_target=override_dh_auto_configure
    else
        echo "Debian Samba configure target not found" >&2
        exit 4
    fi
    DEB_BUILD_OPTIONS='nocheck nodoc' \
        ./debian/rules "$configure_target"
    PYTHONHASHSEED=1 \
        ./buildtools/bin/waf build --targets=vfs_smbproxy_session
)

BUILT_MODULE=$(find "$SAMBA_SOURCE/bin" -type f \
    \( -name 'smbproxy_session.so' -o -name 'vfs_smbproxy_session.so' \
       -o -name 'libvfs_smbproxy_session.so' \
       -o -name 'libvfs_module_smbproxy_session.so' \) \
    -print -quit)
[[ -n "$BUILT_MODULE" ]] || { echo "built VFS module not found" >&2; exit 5; }

install -d -m 0755 "$MODULE_ROOT/vfs" /usr/lib/smbproxy
install -m 0644 "$BUILT_MODULE" "$MODULE_ROOT/vfs/smbproxy_session.so"
printf '%s\n' "$SAMBA_DEB_VERSION" > /usr/lib/smbproxy/samba-version
sha256sum "$MODULE_SOURCE" | awk '{ print $1 }' \
    > /usr/lib/smbproxy/vfs-source.sha256
chmod 0644 /usr/lib/smbproxy/samba-version /usr/lib/smbproxy/vfs-source.sha256

restore_manual_marks
if [[ "${SMBPROXY_SKIP_AUTOREMOVE:-0}" != "1" ]]; then
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y
fi
apt-get clean

echo "installed $MODULE_ROOT/vfs/smbproxy_session.so for Debian Samba package $(cat /usr/lib/smbproxy/samba-version)"
