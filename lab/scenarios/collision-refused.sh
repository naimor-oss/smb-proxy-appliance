# lab/scenarios/collision-refused.sh — NEGATIVE-path scenario.
#
# Verifies the AD-name-collision defense in configure_share. With the
# proxy domain-joined and `winbind use default domain = yes`, picking
# a force-user name that ALSO exists in AD would silently capture the
# mapping at tree-connect time and corrupt the share's identity
# binding (production incident 2026-05-05 — broke the WorkData share).
#
# Defense: configure_share calls `wbinfo --name-to-sid` on the chosen
# name BEFORE any persistent writes (creds, fstab, smb.conf, share
# state, useradd) happen, and REFUSES the configuration with rc=9 if
# the name resolves in AD. This scenario:
#
#   1. Snapshots whether each verifiable artifact already exists on
#      the proxy (some, like /etc/passwd entry for "Administrator",
#      may persist across earlier runs and we must not false-positive
#      on those).
#   2. Invokes `--configure-share --force-user Administrator` on a
#      domain-joined proxy.
#   3. Asserts rc=9.
#   4. Asserts NO new state was committed:
#        - /etc/samba/.creds-<safe>            absent
#        - /etc/fstab cifs line for the mount  absent
#        - [SHARE_NAME] section in smb.conf    absent
#        - /var/lib/smbproxy/shares/<safe>.env absent
#        - /etc/passwd entry for force-user    no DELTA across attempt
#
# Use the lab/profiles/adversarial-collision.env profile to drive
# this. Other scenarios (frontend-share, multi-share, etc.) MUST NOT
# use that profile — they expect rc=0 and would all fail by design.
#
# Sourced by lab/run-scenario.sh. Has access to ssh_host / ssh_vm /
# scp_to_vm / say / step helpers and the LAB_HV_* / LAB_VM_* variables.
#
# pre_hook: bootstrap_network (legacy NIC up so configure_share's
#           legacy-NIC-role guard doesn't refuse for the wrong reason)
#           + AD cleanup + domain join (winbind must be up so the
#           wbinfo --name-to-sid pre-check has a backend to query).
#
# Overridable via env (defaults from adversarial-collision.env when
# run with --profile adversarial-collision):
#   SC_SHARE_NAME    e.g. CollisionTest
#   SC_FORCE_USER    must be a name guaranteed to exist in AD (e.g.
#                    Administrator)
#   SC_GROUP         AD group for valid users; not actually consumed
#                    by the verify (collision short-circuits before
#                    the smb.conf section is built) but required by
#                    do_configure_backend's --group passthrough.

source "$(dirname "${BASH_SOURCE[0]}")/join-domain.sh"
source "$(dirname "${BASH_SOURCE[0]}")/backend-mount.sh"

SC_SHARE_NAME="${SC_SHARE_NAME:-CollisionTest}"
SC_BACKEND_IP="${SC_BACKEND_IP:-172.29.137.1}"
SC_BACKEND_USER="${SC_BACKEND_USER:-engineering_user}"
SC_BACKEND_DOMAIN="${SC_BACKEND_DOMAIN:-LEGACY}"
SC_BACKEND_MOUNT="${SC_BACKEND_MOUNT:-/mnt/legacy/CollisionTest}"
SC_FORCE_USER="${SC_FORCE_USER:-Administrator}"
SC_GROUP="${SC_GROUP:-LAB\\Administrators}"

# Snapshot state we must compare across the refused attempt. Stored
# in scenario-local globals so verify() can read them after the
# attempt has run.
_COLL_PRE_HAS_LOCAL_USER=""
_COLL_PRE_HAS_CREDS=""
_COLL_PRE_HAS_FSTAB=""
_COLL_PRE_HAS_SECTION=""
_COLL_PRE_HAS_STATE=""

snapshot_pre_state() {
    local safe; safe=$(sanitize "$SC_SHARE_NAME")
    local creds_path="/etc/samba/.creds-${safe}"
    local state_path="/var/lib/smbproxy/shares/${safe}.env"

    _COLL_PRE_HAS_LOCAL_USER=$(ssh_vm "grep -q '^${SC_FORCE_USER}:' /etc/passwd && echo yes || echo no" 2>&1)
    _COLL_PRE_HAS_CREDS=$(ssh_vm "[[ -f '$creds_path' ]] && echo yes || echo no" 2>&1)
    _COLL_PRE_HAS_FSTAB=$(ssh_vm "grep -qF ' ${SC_BACKEND_MOUNT} cifs ' /etc/fstab && echo yes || echo no" 2>&1)
    _COLL_PRE_HAS_SECTION=$(ssh_vm "grep -qF '[${SC_SHARE_NAME}]' /etc/samba/smb.conf && echo yes || echo no" 2>&1)
    _COLL_PRE_HAS_STATE=$(ssh_vm "[[ -f '$state_path' ]] && echo yes || echo no" 2>&1)

    say "pre-state: local_user=${_COLL_PRE_HAS_LOCAL_USER} creds=${_COLL_PRE_HAS_CREDS} fstab=${_COLL_PRE_HAS_FSTAB} section=${_COLL_PRE_HAS_SECTION} state=${_COLL_PRE_HAS_STATE}"
}

# Run the refused attempt and capture rc. We don't use
# do_configure_backend here because that helper exits non-zero on
# the configure-share rc, which under set -e would abort run_scenario
# before we got to verify(). Capture rc explicitly.
COLL_ATTEMPT_RC=""

attempt_collision_configure() {
    # shellcheck disable=SC2087
    COLL_ATTEMPT_RC=$(ssh_vm "echo '$SC_BACKEND_PASS' | sudo smbproxy-sconfig --configure-share \
        --name '$SC_SHARE_NAME' \
        --backend-ip '$SC_BACKEND_IP' \
        --backend-user '$SC_BACKEND_USER' \
        --backend-domain '$SC_BACKEND_DOMAIN' \
        --mount '$SC_BACKEND_MOUNT' \
        --force-user '$SC_FORCE_USER' \
        --group '$SC_GROUP' \
        --pass-stdin >/dev/null 2>&1; echo \$?")
    say "configure-share attempt returned rc=${COLL_ATTEMPT_RC}"
}

pre_hook() {
    step "bootstrap network (NIC roles + legacy IP)"
    bootstrap_network
    do_ad_cleanup_proxy
    require_backend_pass

    step "join domain (winbind must be up so wbinfo can answer)"
    do_join_domain

    step "snapshot proxy state BEFORE the refused attempt"
    snapshot_pre_state
}

run_scenario() {
    step "attempt configure-share with AD-colliding force-user"
    attempt_collision_configure
}

verify() {
    local rc=0
    local safe; safe=$(sanitize "$SC_SHARE_NAME")
    local creds_path="/etc/samba/.creds-${safe}"
    local state_path="/var/lib/smbproxy/shares/${safe}.env"

    say "configure-share refused with rc=9 (AD-name-collision defense)"
    if [[ "$COLL_ATTEMPT_RC" != "9" ]]; then
        say "expected rc=9, got rc=${COLL_ATTEMPT_RC} — defense did not trip"
        rc=1
    fi

    # No-DELTA semantics: if an artifact existed BEFORE, allow it to
    # still exist AFTER (same value). What MUST NOT happen is for the
    # refused attempt to introduce one that wasn't there before.
    say "no creds file was created by the refused attempt"
    local now_creds
    now_creds=$(ssh_vm "[[ -f '$creds_path' ]] && echo yes || echo no" 2>&1)
    if [[ "$_COLL_PRE_HAS_CREDS" == "no" && "$now_creds" == "yes" ]]; then
        say "creds file ${creds_path} was created despite refusal — orphan state"
        rc=1
    fi

    say "no fstab cifs line was added by the refused attempt"
    local now_fstab
    now_fstab=$(ssh_vm "grep -qF ' ${SC_BACKEND_MOUNT} cifs ' /etc/fstab && echo yes || echo no" 2>&1)
    if [[ "$_COLL_PRE_HAS_FSTAB" == "no" && "$now_fstab" == "yes" ]]; then
        say "fstab cifs line for ${SC_BACKEND_MOUNT} was added despite refusal — orphan state"
        rc=1
    fi

    say "no [${SC_SHARE_NAME}] section was added to smb.conf"
    local now_section
    now_section=$(ssh_vm "grep -qF '[${SC_SHARE_NAME}]' /etc/samba/smb.conf && echo yes || echo no" 2>&1)
    if [[ "$_COLL_PRE_HAS_SECTION" == "no" && "$now_section" == "yes" ]]; then
        say "smb.conf [${SC_SHARE_NAME}] section was added despite refusal — orphan state"
        rc=1
    fi

    say "no per-share state file was written"
    local now_state
    now_state=$(ssh_vm "[[ -f '$state_path' ]] && echo yes || echo no" 2>&1)
    if [[ "$_COLL_PRE_HAS_STATE" == "no" && "$now_state" == "yes" ]]; then
        say "share-state file ${state_path} was created despite refusal — orphan state"
        rc=1
    fi

    # Local /etc/passwd: the wbinfo guard fires BEFORE useradd, so a
    # name that wasn't in /etc/passwd before MUST NOT be there after.
    say "no /etc/passwd entry was added for the refused force-user"
    local now_local
    now_local=$(ssh_vm "grep -q '^${SC_FORCE_USER}:' /etc/passwd && echo yes || echo no" 2>&1)
    if [[ "$_COLL_PRE_HAS_LOCAL_USER" == "no" && "$now_local" == "yes" ]]; then
        say "/etc/passwd entry for ${SC_FORCE_USER} was created despite refusal — wbinfo check ran AFTER useradd"
        rc=1
    fi

    say "post-state: local_user=${now_local} creds=${now_creds} fstab=${now_fstab} section=${now_section} state=${now_state}"

    if [[ $rc -eq 0 ]]; then
        say "PASS — collision was refused and no orphan state was committed"
    fi
    return $rc
}

post_hook() {
    # Nothing to clean up — the whole point is that the refused
    # attempt left no state. If a regression DID leak state, leaving
    # it in place lets the operator inspect what got through.
    :
}
