# lab/scenarios/multi-share.sh — configure TWO proxied shares from
# the SAME legacy backend with DIFFERENT credentials and DIFFERENT
# AD access groups + force-users. This is the use case the
# multi-share refactor (B1-B3, 2026-05-04) was built for: in
# practice the operator needs to publish more than one share from
# the same legacy server with independent ACLs.
#
# Sourced by lab/run-scenario.sh.
#
# pre_hook: bootstrap_network → AD cleanup → join domain. Once.
#
# run_scenario: configure share #1 then share #2 via two
# --configure-share invocations on the SAME backend IP, then apply
# the firewall.
#
# Verification confirms BOTH shares are independent in every
# observable place: per-share env files, per-share creds files at
# their own paths and modes, two distinct fstab entries with
# distinct credentials= paths, two distinct [SHARE] sections in
# smb.conf with their own valid users / force user, both visible
# in --list-shares and --status, and both reachable via
# smbclient -k from the proxy itself.
#
# Overridable via env (defaults form a realistic two-share
# configuration on the existing legacy backend):
#   SC_SHARE_A, SC_SHARE_B          two share names; both used at
#                                   both ends per the convention
#   SC_BACKEND_PASS_A,
#   SC_BACKEND_PASS_B               independent passwords. ONE of
#                                   them may equal SC_BACKEND_PASS
#                                   (defaulted from creds.env), the
#                                   other must be supplied explicitly
#                                   via this scenario's env.
#   SC_BACKEND_USER_A, SC_BACKEND_USER_B   distinct usernames
#   SC_GROUP_A, SC_GROUP_B          distinct AD security groups
#   SC_FORCE_USER_A, SC_FORCE_USER_B distinct local Linux accounts
#   SC_BACKEND_IP                   shared (same backend!)
#
# This scenario INTENTIONALLY does NOT default the per-share creds.
# In practice you'd set SC_BACKEND_PASS_A / SC_BACKEND_PASS_B in
# lab/backend-creds.env (gitignored). For a quick smoke test against
# the existing legacy backend you can set them both to the same
# value as SC_BACKEND_PASS — the scenario will warn but proceed.

source "$(dirname "${BASH_SOURCE[0]}")/join-domain.sh"
source "$(dirname "${BASH_SOURCE[0]}")/backend-mount.sh"

# Two distinct share configurations against the SAME backend.
SC_BACKEND_IP="${SC_BACKEND_IP:-172.29.137.1}"
SC_BACKEND_DOMAIN="${SC_BACKEND_DOMAIN:-LEGACY}"

SC_SHARE_A="${SC_SHARE_A:-Engineering\$}"
SC_BACKEND_USER_A="${SC_BACKEND_USER_A:-engineering_user}"
SC_FORCE_USER_A="${SC_FORCE_USER_A:-engineering_user}"
SC_GROUP_A="${SC_GROUP_A:-LAB\\Domain Users}"

SC_SHARE_B="${SC_SHARE_B:-Drawings\$}"
SC_BACKEND_USER_B="${SC_BACKEND_USER_B:-drawuser}"
SC_FORCE_USER_B="${SC_FORCE_USER_B:-drawuser}"
SC_GROUP_B="${SC_GROUP_B:-LAB\\Domain Admins}"

# Per-share password vars. The pre_hook below validates them.
SC_BACKEND_PASS_A="${SC_BACKEND_PASS_A:-${SC_BACKEND_PASS:-}}"
SC_BACKEND_PASS_B="${SC_BACKEND_PASS_B:-}"

require_two_passwords() {
    if [[ -z "$SC_BACKEND_PASS_A" ]]; then
        say "ERROR: SC_BACKEND_PASS_A is unset (and SC_BACKEND_PASS fallback also unset)"
        return 1
    fi
    if [[ -z "$SC_BACKEND_PASS_B" ]]; then
        say "ERROR: SC_BACKEND_PASS_B is unset"
        say "  Multi-share scenario needs an INDEPENDENT password for the second share's"
        say "  backend user. Set SC_BACKEND_PASS_B='...' in lab/backend-creds.env (or"
        say "  whatever file you pass to --backend-creds)."
        return 1
    fi
    if [[ "$SC_BACKEND_PASS_A" == "$SC_BACKEND_PASS_B" ]] && \
       [[ "$SC_BACKEND_USER_A" != "$SC_BACKEND_USER_B" ]]; then
        say "  warning: SC_BACKEND_PASS_A == SC_BACKEND_PASS_B but the backend USERS differ."
        say "  This is unusual — typically distinct users have distinct passwords. Continuing."
    fi
}

# Helper: drive --configure-share for one of the two shares. Sets the
# per-share env vars from the SC_*_A or SC_*_B variants, then calls
# do_configure_backend (which now passes --group through when SC_GROUP
# is set). The shared backend-mount helper writes one share at a time;
# this function calls it twice.
configure_share_n() {
    local suffix="$1"   # A or B
    local sname uname guser fuser pw mount safe
    case "$suffix" in
        A) sname="$SC_SHARE_A" uname="$SC_BACKEND_USER_A" guser="$SC_GROUP_A"
           fuser="$SC_FORCE_USER_A" pw="$SC_BACKEND_PASS_A" ;;
        B) sname="$SC_SHARE_B" uname="$SC_BACKEND_USER_B" guser="$SC_GROUP_B"
           fuser="$SC_FORCE_USER_B" pw="$SC_BACKEND_PASS_B" ;;
        *) say "configure_share_n: unknown suffix '$suffix'"; return 2 ;;
    esac
    safe=$(sanitize "$sname")
    mount="/mnt/legacy/${safe}"

    SC_SHARE_NAME="$sname"
    SC_BACKEND_USER="$uname"
    SC_GROUP="$guser"
    SC_FORCE_USER="$fuser"
    SC_BACKEND_MOUNT="$mount"
    SC_BACKEND_PASS="$pw"

    do_configure_backend
}

pre_hook() {
    step "bootstrap network (NIC roles + legacy IP)"
    bootstrap_network
    do_ad_cleanup_proxy
    require_two_passwords

    step "join domain (lab.test via WS2025-DC1)"
    do_join_domain
}

run_scenario() {
    step "configure share #1 [$SC_SHARE_A] (user=$SC_BACKEND_USER_A, group=$SC_GROUP_A)"
    configure_share_n A

    step "configure share #2 [$SC_SHARE_B] (user=$SC_BACKEND_USER_B, group=$SC_GROUP_B)"
    configure_share_n B

    step "apply nftables ruleset"
    ssh_vm 'sudo smbproxy-sconfig --apply-firewall'
}

verify() {
    local rc=0 out
    local safe_a; safe_a=$(sanitize "$SC_SHARE_A")
    local safe_b; safe_b=$(sanitize "$SC_SHARE_B")

    say "both per-share state files exist with the right SHARE_NAME"
    out=$(ssh_vm "sudo cat /var/lib/smbproxy/shares/${safe_a}.env" 2>&1 || true)
    grep -qF "SHARE_NAME=\"${SC_SHARE_A}\"" <<< "$out" || { say "share A state file wrong"; rc=1; }
    out=$(ssh_vm "sudo cat /var/lib/smbproxy/shares/${safe_b}.env" 2>&1 || true)
    grep -qF "SHARE_NAME=\"${SC_SHARE_B}\"" <<< "$out" || { say "share B state file wrong"; rc=1; }

    say "both creds files exist at their own paths, mode 0600 root:root"
    for s in "$safe_a" "$safe_b"; do
        out=$(ssh_vm "sudo stat -c '%a %U %G' /etc/samba/.creds-${s}" 2>&1 || true)
        grep -qE '^600 root root' <<< "$out" || { say "creds for $s have wrong perms: $out"; rc=1; }
    done

    say "creds files carry DIFFERENT username + (probably) DIFFERENT password"
    out=$(ssh_vm "sudo grep ^username= /etc/samba/.creds-${safe_a}" 2>&1 || true)
    grep -qF "username=${SC_BACKEND_USER_A}" <<< "$out" || { say "share A creds username wrong"; rc=1; }
    out=$(ssh_vm "sudo grep ^username= /etc/samba/.creds-${safe_b}" 2>&1 || true)
    grep -qF "username=${SC_BACKEND_USER_B}" <<< "$out" || { say "share B creds username wrong"; rc=1; }

    say "fstab has TWO cifs entries with distinct credentials= paths"
    out=$(ssh_vm 'sudo grep "type cifs\|cifs " /etc/fstab' 2>&1 || true)
    echo "$out"
    grep -qF "credentials=/etc/samba/.creds-${safe_a}" <<< "$out" || { say "fstab missing share A creds path"; rc=1; }
    grep -qF "credentials=/etc/samba/.creds-${safe_b}" <<< "$out" || { say "fstab missing share B creds path"; rc=1; }
    local fstab_lines
    fstab_lines=$(grep -c 'cifs ' <<< "$out" 2>/dev/null || echo 0)
    [[ "${fstab_lines:-0}" -ge 2 ]] || { say "expected ≥2 cifs lines in fstab, got $fstab_lines"; rc=1; }

    say "smb.conf has BOTH share sections with their own (numeric) force user + (SID) valid users"
    for s in "$SC_SHARE_A" "$SC_SHARE_B"; do
        out=$(ssh_vm "sudo grep -n \"^\\[$s\\]\" /etc/samba/smb.conf" 2>&1 || true)
        [[ -n "$out" ]] || { say "smb.conf missing [$s] section"; rc=1; }
    done
    # Per-section content check. force user / force group are written
    # as numeric LOCAL UID/GID (default-domain ambiguity defense), and
    # valid users is written as a SID (NSS-independent, immune to the
    # default-domain @"DOMAIN\Group" parsing quirk in Samba 4.22).
    local sec_a sec_b uid_a uid_b sid_a sid_b
    sec_a=$(ssh_vm "sudo awk -v s='[$SC_SHARE_A]' 'BEGIN{p=0} \$0==s{p=1; print; next} /^\\[/{p=0} p' /etc/samba/smb.conf" 2>&1 || true)
    sec_b=$(ssh_vm "sudo awk -v s='[$SC_SHARE_B]' 'BEGIN{p=0} \$0==s{p=1; print; next} /^\\[/{p=0} p' /etc/samba/smb.conf" 2>&1 || true)
    grep -qE '^[[:space:]]*force user[[:space:]]*=[[:space:]]*[0-9]+'  <<< "$sec_a" || { say "[$SC_SHARE_A] force user not numeric";  rc=1; }
    grep -qE '^[[:space:]]*force user[[:space:]]*=[[:space:]]*[0-9]+'  <<< "$sec_b" || { say "[$SC_SHARE_B] force user not numeric";  rc=1; }
    grep -qE '^[[:space:]]*valid users[[:space:]]*=[[:space:]]*S-1-'   <<< "$sec_a" || { say "[$SC_SHARE_A] valid users not a SID";   rc=1; }
    grep -qE '^[[:space:]]*valid users[[:space:]]*=[[:space:]]*S-1-'   <<< "$sec_b" || { say "[$SC_SHARE_B] valid users not a SID";   rc=1; }
    # Cross-check: the two sections MUST have distinct UIDs and SIDs —
    # the whole point of multi-share is independent identities.
    uid_a=$(grep -oE 'force user[[:space:]]*=[[:space:]]*[0-9]+' <<< "$sec_a" | grep -oE '[0-9]+$' | head -1)
    uid_b=$(grep -oE 'force user[[:space:]]*=[[:space:]]*[0-9]+' <<< "$sec_b" | grep -oE '[0-9]+$' | head -1)
    sid_a=$(grep -oE 'valid users[[:space:]]*=[[:space:]]*S-1-[0-9-]+' <<< "$sec_a" | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}')
    sid_b=$(grep -oE 'valid users[[:space:]]*=[[:space:]]*S-1-[0-9-]+' <<< "$sec_b" | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}')
    if [[ -n "$uid_a" && "$uid_a" == "$uid_b" ]]; then
        say "shares A and B share the same force-user UID $uid_a — multi-share independence broken"; rc=1
    fi
    if [[ -n "$sid_a" && "$sid_a" == "$sid_b" ]]; then
        say "shares A and B share the same valid-users SID — distinct AD groups expected"; rc=1
    fi

    say "testparm -s reports no warnings for the combined config"
    out=$(ssh_vm 'sudo testparm -s 2>&1 1>/dev/null' || true)
    echo "$out" | head -20
    if grep -qiE 'WARNING|ERROR' <<< "$out"; then
        say "testparm reported warnings/errors"; rc=1
    fi

    say "--list-shares enumerates both shares"
    out=$(ssh_vm 'sudo smbproxy-sconfig --list-shares' 2>&1 || true)
    echo "$out"
    grep -qFx "$SC_SHARE_A" <<< "$out" || { say "--list-shares missing $SC_SHARE_A"; rc=1; }
    grep -qFx "$SC_SHARE_B" <<< "$out" || { say "--list-shares missing $SC_SHARE_B"; rc=1; }

    say "--status shows both as active with smb_section:yes"
    out=$(ssh_vm 'sudo smbproxy-sconfig --status' 2>&1 || true)
    echo "$out"
    grep -qF "  - $SC_SHARE_A" <<< "$out" || { say "--status missing entry for $SC_SHARE_A"; rc=1; }
    grep -qF "  - $SC_SHARE_B" <<< "$out" || { say "--status missing entry for $SC_SHARE_B"; rc=1; }

    say "smbclient -k from the proxy lists BOTH shares"
    out=$(ssh_vm "sudo bash -c 'echo \"$SC_PASS\" | kinit \"$SC_ADMIN@$SC_REALM_UC\" && smbclient -k -L //$LAB_VM_IP -m SMB3'" 2>&1 || true)
    echo "$out"
    grep -qF "$SC_SHARE_A" <<< "$out" || { say "smbclient -L missing $SC_SHARE_A"; rc=1; }
    grep -qF "$SC_SHARE_B" <<< "$out" || { say "smbclient -L missing $SC_SHARE_B"; rc=1; }

    # Adversarial-profile checks: if either force-user collides with an
    # AD account, verify the d480a7c default-domain ambiguity defense
    # held under multi-share. The check self-activates when collision
    # is detected on the live system — no need to gate on $PROFILE_NAME.
    # Run BEFORE the destructive --remove-share step so both shares are
    # still in place to inspect.
    _multi_share_collision_check() {
        local share_name="$1" force_user="$2" smb_section="$3"
        local smb_uid file_uid ad_uid

        say "  ${share_name}: configure log recorded the collision WARN"
        out=$(ssh_vm "sudo grep -E \"WARN: requested force-user '${force_user}'\" /var/log/smbproxy-share.log 2>/dev/null" || true)
        echo "$out"
        [[ -n "$out" ]] || { say "  WARN about colliding name '${force_user}' not in /var/log/smbproxy-share.log"; rc=1; }

        say "  ${share_name}: local /etc/passwd entry exists for '${force_user}'"
        ssh_vm "grep -q '^${force_user}:' /etc/passwd" || { say "  no /etc/passwd entry for ${force_user} — useradd was skipped"; rc=1; }

        say "  ${share_name}: smb.conf force-user UID is the LOCAL one, not the AD one"
        smb_uid=$(grep -oE 'force user[[:space:]]*=[[:space:]]*[0-9]+' <<< "$smb_section" | grep -oE '[0-9]+$' | head -1)
        file_uid=$(ssh_vm "awk -F: -v u='${force_user}' '\$1==u {print \$3; exit}' /etc/passwd" 2>&1 || true)
        ad_uid=$(ssh_vm "wbinfo --name-to-sid='${force_user}' 2>/dev/null | awk '{print \$1}' | xargs -I{} wbinfo --sid-to-uid={} 2>/dev/null" || true)
        echo "  ${share_name}: local=${file_uid} AD=${ad_uid} smb.conf=${smb_uid}"
        if [[ -n "$file_uid" && -n "$smb_uid" && "$file_uid" != "$smb_uid" ]]; then
            say "  ${share_name}: smb.conf UID $smb_uid != local /etc/passwd UID $file_uid — defense breach"; rc=1
        fi
        if [[ -n "$ad_uid" && "$ad_uid" == "$smb_uid" ]]; then
            say "  ${share_name}: smb.conf UID $smb_uid is the AD UID — defense breach"; rc=1
        fi
    }

    if ssh_vm "id '${SC_FORCE_USER_A}' 2>/dev/null | grep -q 'gid=.*domain users'"; then
        say "share A force-user '${SC_FORCE_USER_A}' collides with an AD account — adversarial checks active"
        _multi_share_collision_check "[$SC_SHARE_A]" "$SC_FORCE_USER_A" "$sec_a"
    fi
    if ssh_vm "id '${SC_FORCE_USER_B}' 2>/dev/null | grep -q 'gid=.*domain users'"; then
        say "share B force-user '${SC_FORCE_USER_B}' collides with an AD account — adversarial checks active"
        _multi_share_collision_check "[$SC_SHARE_B]" "$SC_FORCE_USER_B" "$sec_b"
    fi

    # When BOTH force-users collide with AD accounts, additionally
    # confirm the two LOCAL accounts ended up with distinct UIDs (i.e.
    # we actually created two separate /etc/passwd entries — not
    # silently reused one). This is the adversarial mirror of the
    # standard multi-share independence cross-check above.
    if ssh_vm "id '${SC_FORCE_USER_A}' 2>/dev/null | grep -q 'gid=.*domain users'" && \
       ssh_vm "id '${SC_FORCE_USER_B}' 2>/dev/null | grep -q 'gid=.*domain users'"; then
        say "both force-users collide with AD — checking the two LOCAL UIDs are distinct"
        local local_uid_a local_uid_b
        local_uid_a=$(ssh_vm "awk -F: -v u='${SC_FORCE_USER_A}' '\$1==u {print \$3; exit}' /etc/passwd" 2>&1 || true)
        local_uid_b=$(ssh_vm "awk -F: -v u='${SC_FORCE_USER_B}' '\$1==u {print \$3; exit}' /etc/passwd" 2>&1 || true)
        echo "  local UIDs: A=${local_uid_a} B=${local_uid_b}"
        if [[ -n "$local_uid_a" && "$local_uid_a" == "$local_uid_b" ]]; then
            say "  both local accounts share UID $local_uid_a — useradd was reused, not separate"; rc=1
        fi
    fi

    say "removing share B leaves share A intact"
    # The destructive part of this scenario — exercises remove_share
    # while another share is configured against the same backend, which
    # is exactly the case where bugs in remove_share would bite (e.g.
    # wrong sed pattern stripping the wrong fstab line).
    ssh_vm "sudo smbproxy-sconfig --remove-share --name '$SC_SHARE_B'" 2>&1
    out=$(ssh_vm 'sudo smbproxy-sconfig --list-shares' 2>&1 || true)
    grep -qFx "$SC_SHARE_A" <<< "$out" || { say "share A vanished after removing B"; rc=1; }
    grep -qFx "$SC_SHARE_B" <<< "$out" && { say "share B still listed after --remove-share"; rc=1; }
    out=$(ssh_vm "sudo grep -F ' /mnt/legacy/${safe_b} cifs ' /etc/fstab" 2>&1 || true)
    [[ -z "$out" ]] || { say "share B fstab line not removed"; rc=1; }
    out=$(ssh_vm "sudo grep -F '[$SC_SHARE_B]' /etc/samba/smb.conf" 2>&1 || true)
    [[ -z "$out" ]] || { say "share B smb.conf section not removed"; rc=1; }
    out=$(ssh_vm "sudo grep -F '[$SC_SHARE_A]' /etc/samba/smb.conf" 2>&1 || true)
    [[ -n "$out" ]] || { say "share A smb.conf section was incorrectly stripped too"; rc=1; }

    return "$rc"
}
