#!/usr/bin/env bash
# Static contract checks across the appliance/standalone-VFS boundary.
# Compilation and live lock semantics are covered by image build plus
# tps-lock-isolation.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
VFS_REPO="${VFS_REPO:-$ROOT/../smbproxy-session-vfs}"
VFS="$VFS_REPO/src/vfs_smbproxy_session.c"
BUILD="$VFS_REPO/scripts/build-debian-package.sh"

[[ -f "$VFS" && -f "$BUILD" ]] || {
    echo "FAIL standalone smbproxy-session-vfs sibling is missing: $VFS_REPO" >&2
    exit 1
}

# shellcheck disable=SC1091
source "$ROOT/components/smbproxy-session-vfs.env"
actual_version=$(tr -d '[:space:]' < "$VFS_REPO/VERSION")
actual_hash=$(shasum -a 256 "$VFS" | awk '{ print $1 }')
[[ "$actual_version" == "$SMBPROXY_VFS_COMPONENT_VERSION" \
   && "$actual_hash" == "$SMBPROXY_VFS_SOURCE_SHA256" ]] || {
    echo "FAIL standalone VFS source does not match appliance component pin" >&2
    exit 1
}

for required in \
    'handle->conn->vuid' \
    'handle->conn->cnum' \
    'state->pid = getpid()' \
    'set_conn_connectpath(handle->conn, state->mountpoint)' \
    'smbproxy_run_helper("connect", state)' \
    'smbproxy_run_helper("disconnect", state)' \
    'static_decl_vfs;'; do
    grep -qF "$required" "$VFS" || {
        echo "FAIL VFS contract missing: $required" >&2
        exit 1
    }
done

# shellcheck disable=SC2016
grep -qF 'Depends: samba (= $SAMBA_DEB_VERSION)' "$BUILD" || {
    echo "FAIL component package does not depend on an exact Samba revision" >&2
    exit 1
}
grep -qF "init_function='vfs_smbproxy_session_init'" "$BUILD" || {
    echo "FAIL custom VFS initializer is not exported as Samba's dynamic module entry point" >&2
    exit 1
}
# shellcheck disable=SC2016
grep -qF './debian/rules "$configure_target"' "$BUILD" || {
    echo "FAIL VFS build is not using Debian's exact Samba configure contract" >&2
    exit 1
}
grep -qF 'configure_target=configure' "$BUILD" || {
    echo "FAIL VFS build does not support Debian Samba's configure target" >&2
    exit 1
}
# shellcheck disable=SC2016
grep -qF '"samba=$SAMBA_DEB_VERSION"' "$BUILD" || {
    echo "FAIL VFS build dependencies are not pinned to the Samba revision" >&2
    exit 1
}
# shellcheck disable=SC2016
grep -qF -- "-f='\${Version}' samba" "$ROOT/smbproxy-vfs-version-check" || {
    echo "FAIL runtime guard does not compare the Debian Samba package revision" >&2
    exit 1
}
grep -qF '/usr/share/smbproxy-session-vfs/samba-package-version' \
    "$ROOT/smbproxy-vfs-version-check" || {
    echo "FAIL runtime guard does not consume standalone component metadata" >&2
    exit 1
}
grep -qF 'ExecStartPre=/usr/local/sbin/smbproxy-session-mount cleanup-all' "$ROOT/prepare-image.sh" || {
    echo "FAIL smbd startup does not sweep stale upstream sessions" >&2
    exit 1
}

echo "VFS contract tests passed"
