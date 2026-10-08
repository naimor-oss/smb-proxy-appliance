#!/usr/bin/env bash
# The SMB proxy update bundle against a simulated field unit (the production
# proxy's known state: 0.4.0-inplace7 marker, no release file, no kvstate
# libs). Builds the real bundle and applies it with the real hooks. Run as
# root in a DISPOSABLE container:
#
#   docker run --rm -v "$PWD/..":/ws:ro -e DISPOSABLE_ROOT_TEST=1 \
#       debian:trixie bash /ws/smb-proxy-appliance/tests/root/update-bundle.sh

set -uo pipefail
[[ ${EUID} -eq 0 && "${DISPOSABLE_ROOT_TEST:-0}" == 1 ]] || {
    echo "refusing: run as root in a disposable container with DISPOSABLE_ROOT_TEST=1" >&2
    exit 2
}
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
T=$(mktemp -d)
fail() { echo "FAIL: $*" >&2; exit 1; }
pass() { echo "ok   $*"; }

# ---- build the bundle ---------------------------------------------------------
cp -a "$SRC" "$T/smb-proxy-appliance"
cp -a "$SRC/../appliance-core" "$T/appliance-core"
"$T/smb-proxy-appliance/updates/build-bundle.sh" --out "$T/dist" >/dev/null || fail "bundle build failed"
VERSION=$(head -1 "$SRC/VERSION")
BUNDLE="$T/dist/smbproxy-update-$VERSION.tar.gz"
[[ -f "$BUNDLE" && -f "$BUNDLE.sha256" ]] || fail "bundle not produced"

# ---- fakes for the services a real unit has -----------------------------------
mkdir -p "$T/bin" "$T/mods/vfs"
: > "$T/mods/vfs/fileid.so"; : > "$T/mods/vfs/smbproxy_session.so"
cat > "$T/bin/systemctl" <<'SH'
#!/bin/sh
echo "$*" >> /tmp/systemctl.log
case "$*" in *is-enabled*) exit 0 ;; esac
exit 0
SH
cat > "$T/bin/testparm" <<'SH'
#!/bin/sh
[ -e /tmp/fail-testparm ] && exit 1
exit 0
SH
printf '#!/bin/sh\ncase "$*" in *smbproxy-session-vfs*) echo 0.2.0+samba4.22.10;; *) echo 2:4.22.10+dfsg-0+deb13u2;; esac\n' > "$T/bin/dpkg-query"
printf '#!/bin/sh\necho "   MODULESDIR: %s"\n' "$T/mods" > "$T/bin/smbd"
chmod +x "$T/bin/"*
export PATH="$T/bin:$PATH"
# The real version guard runs with fixture inputs (its test-mode overrides).
export SMBPROXY_ALLOW_NON_ROOT_TEST=1 SMBPROXY_DPKG_QUERY_BIN="$T/bin/dpkg-query" \
    SMBPROXY_SMBD_BIN="$T/bin/smbd" SMBPROXY_VFS_VERSION_FILE="$T/vfs-expected"
echo '2:4.22.10+dfsg-0+deb13u2' > "$T/vfs-expected"

# ---- the simulated field unit -------------------------------------------------
make_unit() {
    rm -rf /etc/samba /etc/smbproxy /var/lib/smbproxy /usr/local/lib/appliance-core \
        /etc/smbproxy.release /var/backups/smbproxy-update /etc/update-motd.d
    mkdir -p /etc/samba /etc/smbproxy /var/lib/smbproxy/shares /usr/local/sbin \
        /usr/local/lib/appliance-core /etc/update-motd.d
    printf '[global]\n    workgroup = LAB\n\n[Files]\n    # profile=legacy; locking=tps-strict; offline=direct\n    path = /run/smbproxy/sessions\n' \
        > /etc/samba/smb.conf
    # Written by the old heredoc save_share: KEY="value", raw values.
    printf 'SHARE_NAME="Files"\nPROFILE="legacy"\nOFFLINE_MODE="direct"\nBACKEND_IP="192.0.2.10"\nBACKEND_USER="clerk"\nBACKEND_DOMAIN="LEGACY"\nBACKEND_MOUNT="/mnt/legacy/Files"\nFRONT_GROUP="LAB\\Accounting"\nFRONT_FORCE_USER="ledger"\n' \
        > /var/lib/smbproxy/shares/Files.env
    printf 'DOMAIN_NIC_NAME="eth0"\nDOMAIN_NIC_MAC="00:15:5d:00:00:01"\nLEGACY_NIC_NAME="eth1"\nLEGACY_NIC_MAC="00:15:5d:00:00:02"\n' \
        > /etc/smbproxy/nic-roles.env
    echo 0.4.0-inplace7 > /etc/smbproxy/inplace-update-release
    for s in smbproxy-sconfig smbproxy-session-mount smbproxy-share-worker \
        smbproxy-vfs-version-check smbproxy-probe-backend smbproxy-firstboot smbproxy-init; do
        printf '#!/bin/sh\n# old %s\nexit 0\n' "$s" > "/usr/local/sbin/$s"
        chmod 0755 "/usr/local/sbin/$s"
    done
    rm -f /usr/local/sbin/smbproxy-domain-dns /usr/local/sbin/smbproxy-samba-hold /usr/local/sbin/smbproxy-update
    printf '#!/bin/sh\n. /var/lib/smbproxy-init-detected.env\n' > /etc/update-motd.d/15-smbproxy-net-status
    chmod 0755 /etc/update-motd.d/15-smbproxy-net-status
    printf 'old lib\n' > /usr/local/lib/appliance-core/detect-net.sh
    echo 0.11.0 > /usr/local/lib/appliance-core/VERSION
    rm -f /tmp/systemctl.log /tmp/fail-testparm
    sha256sum /usr/local/sbin/* /etc/samba/smb.conf /var/lib/smbproxy/shares/Files.env \
        /usr/local/lib/appliance-core/* /etc/update-motd.d/* > "$T/unit.before"
}
unit_unchanged() {
    sha256sum -c --quiet "$T/unit.before" >/dev/null 2>&1 \
        && [[ ! -e /etc/smbproxy.release && ! -e /usr/local/sbin/smbproxy-update ]]
}
extract() {
    rm -rf "$T/x"; mkdir -p "$T/x"
    tar -xzf "$BUNDLE" -C "$T/x"
    B="$T/x/smbproxy-update-$VERSION"
}

# ---- 1. the field unit is updated ----------------------------------------------
make_unit; extract
bash "$B/install.sh" > "$T/out" 2>&1 || { cat "$T/out"; fail "update of the field unit failed"; }
cmp -s "$SRC/smbproxy-sconfig.sh" /usr/local/sbin/smbproxy-sconfig || fail "sconfig not replaced"
cmp -s "$SRC/smbproxy-share-worker" /usr/local/sbin/smbproxy-share-worker || fail "worker not replaced"
[[ -f /usr/local/lib/appliance-core/kvstate.sh && -f /usr/local/lib/appliance-core/update.sh ]] \
    || fail "appliance-core libs not installed"
[[ -x /usr/local/sbin/smbproxy-update ]] || fail "built-in updater not installed"
[[ ! -e /usr/local/sbin/smbproxy-domain-dns ]] || fail "a script the unit never had was installed"
! grep -q '^\. /var/lib/smbproxy-init-detected.env' /etc/update-motd.d/15-smbproxy-net-status \
    || fail "the login banner still sources the detection cache"
[[ ! -e /etc/update-motd.d/17-smbproxy-samba ]] || fail "a banner the unit never had was installed"
grep -q '^VERSION="'"$VERSION"'"$' /etc/smbproxy.release || fail "release file not written"
grep -q '^SAMBA_VERSION="2:4.22.10+dfsg-0+deb13u2"$' /etc/smbproxy.release || fail "Samba version not recorded"
grep -q '^VFS_VERSION="0.2.0+samba4.22.10"$' /etc/smbproxy.release || fail "VFS version not recorded"
grep -q 'start smbproxy-share-worker.service' /tmp/systemctl.log || fail "worker pass not started"
grep -q 'Rollback: sudo /var/backups/smbproxy-update/' "$T/out" || fail "rollback command not printed"
pass "field unit 0.4.0-inplace7 -> $VERSION: scripts, libs, banner, updater, release file"

# ---- 2. the built-in updater works on the updated unit -------------------------
/usr/local/sbin/smbproxy-update status | grep -q "VERSION          $VERSION" || fail "status does not report $VERSION"
/usr/local/sbin/smbproxy-update apply "$BUNDLE" | grep -q "Already at $VERSION" || fail "re-apply is not a no-op"
pass "smbproxy-update status and an idempotent re-apply"

# ---- 3. rollback restores the unit byte for byte ------------------------------
/usr/local/sbin/smbproxy-update rollback > "$T/out" 2>&1 || { cat "$T/out"; fail "rollback failed"; }
unit_unchanged || fail "rollback did not restore the unit exactly"
pass "smbproxy-update rollback restores every file and removes what the update added"

# ---- 4. refusals change nothing -----------------------------------------------
make_unit; extract
printf 'SHARE_NAME="Files"$(touch /tmp/pwned)\n' > /var/lib/smbproxy/shares/Files.env
sha256sum /usr/local/sbin/* /etc/samba/smb.conf /var/lib/smbproxy/shares/Files.env \
    /usr/local/lib/appliance-core/* /etc/update-motd.d/* > "$T/unit.before"
rc=0; bash "$B/install.sh" > "$T/out" 2>&1 || rc=$?
[[ $rc -eq 2 ]] || fail "unreadable share state was not refused (rc=$rc)"
grep -q 'Files.env' "$T/out" || fail "refusal does not name the state file"
[[ ! -e /tmp/pwned ]] || fail "state was executed during preflight"
unit_unchanged || fail "refused update changed the unit"
make_unit; extract
rm -f /etc/smbproxy/inplace-update-release
sha256sum /usr/local/sbin/* /etc/samba/smb.conf /var/lib/smbproxy/shares/Files.env \
    /usr/local/lib/appliance-core/* /etc/update-motd.d/* > "$T/unit.before"
rc=0; bash "$B/install.sh" > "$T/out" 2>&1 || rc=$?
[[ $rc -eq 2 ]] && grep -q 'cannot determine' "$T/out" || fail "unknown starting version was not refused"
unit_unchanged || fail "refused update changed the unit"
pass "unreadable state and an unknown starting version are refused with no change"

# ---- 5. a failed verify rolls back automatically ------------------------------
make_unit; extract
touch /tmp/fail-testparm
rc=0; bash "$B/install.sh" > "$T/out" 2>&1 || rc=$?
rm -f /tmp/fail-testparm
[[ $rc -eq 3 ]] || { cat "$T/out"; fail "failed verify did not report rc=3 (rc=$rc)"; }
unit_unchanged || fail "automatic rollback did not restore the unit exactly"
pass "a failed verify restores the unit automatically (rc=3)"

echo "update bundle tests passed"
