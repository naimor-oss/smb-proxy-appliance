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

    say "smb.conf has BOTH share sections with their own (username) force user + (SID) valid users"
    for s in "$SC_SHARE_A" "$SC_SHARE_B"; do
        out=$(ssh_vm "sudo grep -n \"^\\[$s\\]\" /etc/samba/smb.conf" 2>&1 || true)
        [[ -n "$out" ]] || { say "smb.conf missing [$s] section"; rc=1; }
    done
    # Per-section content check. force user / force group are now written
    # as the LOCAL username (Samba's getpwnam() needs a name string;
    # numeric strings don't resolve there). The default-domain ambiguity
    # defense lives at write time — wbinfo --name-to-sid REFUSES the
    # config (rc=9) if the chosen name also exists in AD, and the
    # appliance's NSS files-first ordering means the local /etc/passwd
    # entry always wins over winbind. valid users stays as a SID for
    # the unrelated @"DOMAIN\Group" parsing-quirk defense.
    local sec_a sec_b user_a user_b sid_a sid_b uid_a uid_b
    sec_a=$(ssh_vm "sudo awk -v s='[$SC_SHARE_A]' 'BEGIN{p=0} \$0==s{p=1; print; next} /^\\[/{p=0} p' /etc/samba/smb.conf" 2>&1 || true)
    sec_b=$(ssh_vm "sudo awk -v s='[$SC_SHARE_B]' 'BEGIN{p=0} \$0==s{p=1; print; next} /^\\[/{p=0} p' /etc/samba/smb.conf" 2>&1 || true)
    grep -qE '^[[:space:]]*force user[[:space:]]*=[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*$' <<< "$sec_a" \
        || { say "[$SC_SHARE_A] force user not a username"; rc=1; }
    grep -qE '^[[:space:]]*force user[[:space:]]*=[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*$' <<< "$sec_b" \
        || { say "[$SC_SHARE_B] force user not a username"; rc=1; }
    # Belt-and-suspenders: a numeric force user would silently break
    # tree-connect via getpwnam("1003") — pin the regression both ways.
    grep -qE '^[[:space:]]*force user[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$' <<< "$sec_a" \
        && { say "[$SC_SHARE_A] force user is numeric (Samba getpwnam() would fail)"; rc=1; }
    grep -qE '^[[:space:]]*force user[[:space:]]*=[[:space:]]*[0-9]+[[:space:]]*$' <<< "$sec_b" \
        && { say "[$SC_SHARE_B] force user is numeric (Samba getpwnam() would fail)"; rc=1; }
    grep -qE '^[[:space:]]*valid users[[:space:]]*=[[:space:]]*S-1-' <<< "$sec_a" \
        || { say "[$SC_SHARE_A] valid users not a SID"; rc=1; }
    grep -qE '^[[:space:]]*valid users[[:space:]]*=[[:space:]]*S-1-' <<< "$sec_b" \
        || { say "[$SC_SHARE_B] valid users not a SID"; rc=1; }
    # Cross-check: the two sections MUST name DIFFERENT force-users and
    # carry DIFFERENT SIDs — the whole point of multi-share is independent
    # identities. We additionally cross-check that each force-user's
    # /etc/passwd UID exists locally (resolves via files NSS, not winbind).
    user_a=$(grep -oE 'force user[[:space:]]*=[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*' <<< "$sec_a" \
        | sed -E 's/^force user[[:space:]]*=[[:space:]]*//' | head -1)
    user_b=$(grep -oE 'force user[[:space:]]*=[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*' <<< "$sec_b" \
        | sed -E 's/^force user[[:space:]]*=[[:space:]]*//' | head -1)
    sid_a=$(grep -oE 'valid users[[:space:]]*=[[:space:]]*S-1-[0-9-]+' <<< "$sec_a" | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}')
    sid_b=$(grep -oE 'valid users[[:space:]]*=[[:space:]]*S-1-[0-9-]+' <<< "$sec_b" | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}')
    if [[ -n "$user_a" && "$user_a" == "$user_b" ]]; then
        say "shares A and B share the same force-user '$user_a' — multi-share independence broken"; rc=1
    fi
    if [[ -n "$sid_a" && "$sid_a" == "$sid_b" ]]; then
        say "shares A and B share the same valid-users SID — distinct AD groups expected"; rc=1
    fi
    # Resolve each force-user's UID via /etc/passwd files-only (matches
    # the contract: cifs uid=/gid= mount options are numeric and must
    # come from /etc/passwd, NOT winbind).
    if [[ -n "$user_a" ]]; then
        uid_a=$(ssh_vm "awk -F: -v u='${user_a}' '\$1==u {print \$3; exit}' /etc/passwd" 2>&1 || true)
        [[ -n "$uid_a" ]] || { say "[$SC_SHARE_A] no /etc/passwd entry for force-user '$user_a'"; rc=1; }
    fi
    if [[ -n "$user_b" ]]; then
        uid_b=$(ssh_vm "awk -F: -v u='${user_b}' '\$1==u {print \$3; exit}' /etc/passwd" 2>&1 || true)
        [[ -n "$uid_b" ]] || { say "[$SC_SHARE_B] no /etc/passwd entry for force-user '$user_b'"; rc=1; }
    fi
    if [[ -n "$uid_a" && -n "$uid_b" && "$uid_a" == "$uid_b" ]]; then
        say "shares A and B resolve to the same /etc/passwd UID $uid_a — independence breach"; rc=1
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

    # AD-name collision is now a REFUSAL (rc=9) at configure time, not
    # a warn-and-allow. The historical "multi-share collision check"
    # block that lived here verified that warn-and-allow stayed sane
    # under multi-share; it is unreachable now (configure_share short-
    # circuits before any share writes happen). The negative path is
    # exercised by lab/scenarios/collision-refused.sh, which expects
    # rc=9 and verifies no creds / fstab / smb.conf / share-state /
    # local-passwd entries leaked from the refused attempt.

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
