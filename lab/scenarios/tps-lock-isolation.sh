# shellcheck shell=bash
# Release gate for coherent frontend share modes plus backend SMB1 byte-range
# locking. The Samba4 torture client creates independent SMB3 connections while
# the proxy retains distinct upstream CIFS/SMB1 sessions and one normalized
# Samba file identity.

source "$(dirname "${BASH_SOURCE[0]}")/frontend-share.sh"

eval "$(declare -f verify | sed '1s/^verify/_frontend_verify/')"

pre_hook() {
    step "bootstrap network (NIC roles + legacy IP)"
    bootstrap_network
    do_ad_cleanup_proxy
    require_backend_pass

    step "join domain (lab.test via WS2025-DC1)"
    do_join_domain
}

run_scenario() {
    step "configure session-aware legacy share [$SC_SHARE_NAME]"
    do_configure_backend
    do_apply_firewall
}

verify() {
    local rc=0 out lock_rc=0

    step "frontend/session integration checks"
    _frontend_verify || rc=1

    step "two-connection SMB3 lock overlap against SMB1 authority"
    out=$(ssh_vm "sudo bash -s" <<REMOTE
set -euo pipefail
: > /var/log/smbproxy-session-mount.log
printf '%s\n' '$SC_PASS' | kinit '$SC_ADMIN@$SC_REALM_UC'
ccache=\${KRB5CCNAME:-FILE:/tmp/krb5cc_0}
result=/tmp/smbproxy-lock-overlap.out
snapshot=/tmp/smbproxy-lock-sessions.out
devices=/tmp/smbproxy-lock-devices.out
status=/tmp/smbproxy-lock-status.json
rm -f "\$result" "\$snapshot" "\$devices" "\$status"

# Two sessions that keep the same probe file open: the session and identity
# proofs watch these. smbtorture's two-connection tests finish in well under a
# second, too fast to observe reliably.
probe=smbproxy-lock-probe.txt
smb() {
    smbclient '//$SC_FRONT_HOST/$SC_SHARE_NAME' --use-kerberos=required \
        --use-krb5-ccache="\$ccache" -m SMB3 "\$@"
}
smb -c "put /etc/hostname \$probe" >/dev/null 2>&1
holders=()
for _ in 1 2; do
    { echo "open \$probe"; sleep 12; echo quit; } | smb >/dev/null 2>&1 &
    holders+=(\$!)
done

seen=0
identity_ok=0
for _ in \$(seq 1 100); do
    count=0
    : > "\$snapshot"; : > "\$devices"
    shopt -s nullglob
    for state in /run/smbproxy/session-state/*.env; do
        share=\$(sed -n 's/^SHARE_NAME="\\(.*\\)"\$/\\1/p' "\$state" | head -1)
        [[ "\$share" == '$SC_SHARE_NAME' || "\$share" == '$(kv_escape "$SC_SHARE_NAME")' ]] || continue
        mountpoint=\$(sed -n 's/^MOUNTPOINT="\\(.*\\)"\$/\\1/p' "\$state" | head -1)
        if awk -v mp="\$mountpoint" '\$2==mp && \$3=="cifs" {found=1} END {exit !found}' /proc/mounts; then
            count=\$((count + 1))
            grep -F " \$mountpoint cifs " /proc/mounts >> "\$snapshot"
            stat -c '%d' "\$mountpoint" >> "\$devices"
        fi
    done
    shopt -u nullglob
    (( count > seen )) && seen=\$count
    # Normalised identity: Samba keeps one share-mode record per file id, so
    # the probe file shows as one entry with opens from two smbd processes
    # (two client sessions, each on its own CIFS mount).
    if (( count >= 2 )) && smbstatus -L --json > "\$status" 2>/dev/null && python3 - "\$status" "\$probe" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    status = json.load(stream)
for opened in status.get("open_files", {}).values():
    if opened.get("filename") != sys.argv[2]:
        continue
    if not str(opened.get("service_path", "")).startswith("/run/smbproxy/sessions/"):
        continue
    pids = {key.split("/")[0] for key in opened.get("opens", {})}
    if len(pids) >= 2:
        fileid = opened.get("fileid", {})
        print(f"NORMALIZED_SAMBA_FILE_ID={sys.argv[2]}:{fileid.get('devid')}:{fileid.get('inode')} opens from {len(pids)} sessions")
        raise SystemExit(0)
raise SystemExit(1)
PY
    then
        identity_ok=1
        break
    fi
    alive=0
    for h in "\${holders[@]}"; do kill -0 "\$h" 2>/dev/null && alive=1; done
    (( alive )) || break
    sleep 0.2
done
wait "\${holders[@]}" || true
smb -c "del \$probe" >/dev/null 2>&1 || true

# The identity is the ticket from kinit above. --user/--no-pass would make
# smbtorture use an empty password instead (NT_STATUS_INVALID_PARAMETER).
for test in \
    smb2.lock.overlap \
    smb2.sharemode.sharemode-access \
    smb2.rename.no_share_delete_but_delete_access; do
    smbtorture '//$SC_FRONT_HOST/$SC_SHARE_NAME' "\$test" \
        --use-kerberos=required --use-krb5-ccache="\$ccache" \
        --option='client min protocol=SMB3' \
        --option='client max protocol=SMB3' || true
done
echo "MAX_CONCURRENT_SESSION_MOUNTS=\$seen"
echo "SAMBA_FILE_IDENTITY_NORMALIZED=\$identity_ok"
[[ "\$seen" -ge 2 ]]
[[ "\$identity_ok" -eq 1 ]]
[[ -s "\$snapshot" ]]
grep -q 'vers=1.0' "\$snapshot"
grep -q 'cache=none' "\$snapshot"
grep -q 'hard' "\$snapshot"
grep -q 'nosharesock' "\$snapshot"
! grep -q 'nobrl' "\$snapshot"

superblocks=\$(sort -u "\$devices" | wc -l)
echo "DISTINCT_CIFS_SUPERBLOCK_DEVICES=\$superblocks"
[[ "\$superblocks" -ge 2 ]]

connects=\$(grep -F 'action=CONNECT share=$SC_SHARE_NAME ' /var/log/smbproxy-session-mount.log \
    | sed -E 's/.* pid=([0-9]+) vuid=([0-9]+) cnum=([0-9]+).*/\1:\2:\3/' \
    | sort -u | wc -l)
echo "DISTINCT_UPSTREAM_SESSION_KEYS=\$connects"
[[ "\$connects" -ge 2 ]]
REMOTE
    ) || lock_rc=$?
    echo "$out"
    if [[ $lock_rc -ne 0 ]]; then
        say "SMB3 overlap test or upstream-session proof failed"
        rc=1
    fi
    grep -qx 'success: overlap' <<< "$out" \
        || { say "smbtorture smb2.lock.overlap did not succeed"; rc=1; }
    grep -qx 'success: sharemode-access' <<< "$out" \
        || { say "smbtorture smb2.sharemode.sharemode-access did not succeed"; rc=1; }
    grep -qx 'success: no_share_delete_but_delete_access' <<< "$out" \
        || { say "smbtorture smb2.rename.no_share_delete_but_delete_access did not succeed"; rc=1; }
    grep -qE 'MAX_CONCURRENT_SESSION_MOUNTS=[2-9][0-9]*' <<< "$out" \
        || { say "two concurrent SMB1 sessions were not observed"; rc=1; }
    grep -qE 'DISTINCT_UPSTREAM_SESSION_KEYS=[2-9][0-9]*' <<< "$out" \
        || { say "session keys were not distinct"; rc=1; }
    grep -qE 'DISTINCT_CIFS_SUPERBLOCK_DEVICES=[2-9][0-9]*' <<< "$out" \
        || { say "session mounts did not have distinct upstream filesystem identities"; rc=1; }
    grep -qF 'SAMBA_FILE_IDENTITY_NORMALIZED=1' <<< "$out" \
        || { say "Samba did not normalize the same file across session mounts"; rc=1; }

    return "$rc"
}
