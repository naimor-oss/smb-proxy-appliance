#!/usr/bin/env bash
# tests/unit-helpers.sh — pure-bash unit tests for the shape-producing
# helpers in smbproxy-sconfig.sh.
#
# These helpers (share_safe_name, share_default_mount, resolve_locking_kind,
# backend_mount_opts, frontend_locking_stanza) are pure functions — they
# take inputs, return strings, and have no side effects. Their output is
# what gets baked into /etc/fstab and /etc/samba/smb.conf, so accidental
# drift (e.g. someone removing `nosharesock` during a refactor) silently
# breaks production. End-to-end scenarios catch that eventually, but only
# after a full lab cycle. These tests catch it in milliseconds.
#
# Usage:
#   bash tests/unit-helpers.sh         # exit 0 = all pass; non-zero = first failure detail
#   VERBOSE=1 bash tests/unit-helpers.sh
#
# Adding a test: copy one of the functions below, change the inputs and
# expected output. Tests are deliberately verbose-but-trivial — pinning
# the exact output string is the whole point.
#
# Adding a new profile or option: extend the helper, then add the
# matching expected-output strings here. The test failure tells you
# exactly which character of which option string moved.

set -u

# Locate and source smbproxy-sconfig.sh in library mode (the entry-point
# guard at the bottom of the file detects sourced-vs-executed).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCONFIG="${SCRIPT_DIR}/../smbproxy-sconfig.sh"
[[ -f "$SCONFIG" ]] || { echo "FAIL: $SCONFIG not found" >&2; exit 2; }
# shellcheck disable=SC1090
source "$SCONFIG"

PASS=0
FAIL=0
FIRST_FAIL=""

check_eq() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        [[ "${VERBOSE:-0}" == "1" ]] && printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL  %s\n' "$name"
        printf '  expected: %s\n' "$expected"
        printf '  actual:   %s\n' "$actual"
        [[ -z "$FIRST_FAIL" ]] && FIRST_FAIL="$name"
    fi
}

check_rc() {
    local name="$1" expected="$2" actual="$3"
    if [[ "$expected" == "$actual" ]]; then
        PASS=$((PASS + 1))
        [[ "${VERBOSE:-0}" == "1" ]] && printf '  ok   %s\n' "$name"
    else
        FAIL=$((FAIL + 1))
        printf 'FAIL  %s\n' "$name"
        printf '  expected rc: %s\n' "$expected"
        printf '  actual rc:   %s\n' "$actual"
        [[ -z "$FIRST_FAIL" ]] && FIRST_FAIL="$name"
    fi
}

#-------------------------------------------------------------------------------
# share_safe_name — non-alphanumeric → underscore. Idempotent.
#-------------------------------------------------------------------------------
echo "== share_safe_name =="
check_eq "ascii-clean unchanged" \
    "Engineering" "$(share_safe_name "Engineering")"
check_eq "trailing dollar → underscore (the Engineering\$ case)" \
    "Engineering_" "$(share_safe_name 'Engineering$')"
check_eq "embedded space → underscore" \
    "Old_Files" "$(share_safe_name "Old Files")"
check_eq "embedded dot → underscore" \
    "Backup_2024" "$(share_safe_name "Backup.2024")"
check_eq "multiple specials run together → multiple underscores (NOT collapsed)" \
    "Engineering__" "$(share_safe_name 'Engineering$.')"
check_eq "idempotent on already-safe name" \
    "Already_Safe" "$(share_safe_name "Already_Safe")"
check_eq "empty input → empty output" \
    "" "$(share_safe_name "")"
check_eq "single special char → single underscore" \
    "_" "$(share_safe_name '$')"

#-------------------------------------------------------------------------------
# share_default_mount — profile-aware default path.
#-------------------------------------------------------------------------------
echo "== share_default_mount =="
check_eq "legacy profile → /mnt/legacy/<safe>" \
    "/mnt/legacy/Engineering_" "$(share_default_mount 'Engineering$' legacy)"
check_eq "modern profile → /mnt/backend/<safe>" \
    "/mnt/backend/Drawings_" "$(share_default_mount 'Drawings$' modern)"
check_eq "missing profile arg defaults to legacy (back-compat)" \
    "/mnt/legacy/Shop_" "$(share_default_mount 'Shop$')"
check_eq "unknown profile falls through to legacy default" \
    "/mnt/legacy/X" "$(share_default_mount 'X' nonsense)"

#-------------------------------------------------------------------------------
# resolve_locking_kind — (profile, override) → effective kind.
#-------------------------------------------------------------------------------
echo "== resolve_locking_kind =="
check_eq "legacy + profile-default → tps-strict" \
    "tps-strict" "$(resolve_locking_kind legacy profile-default)"
check_eq "modern + profile-default → relaxed" \
    "relaxed"    "$(resolve_locking_kind modern profile-default)"
check_eq "legacy + empty override → tps-strict (back-compat)" \
    "tps-strict" "$(resolve_locking_kind legacy "")"
check_eq "modern + empty override → relaxed" \
    "relaxed"    "$(resolve_locking_kind modern "")"
check_eq "explicit override 'tps-strict' wins over modern profile" \
    "tps-strict" "$(resolve_locking_kind modern tps-strict)"
check_eq "explicit override 'relaxed' wins over legacy profile" \
    "relaxed"    "$(resolve_locking_kind legacy relaxed)"

# Negative path: unrecognized override returns rc=2.
resolve_locking_kind legacy bogus >/dev/null 2>&1
check_rc "unknown override → rc=2" 2 $?

#-------------------------------------------------------------------------------
# backend_mount_opts — comma-separated cifs option string per profile.
# Uses globals CREDS, FU_UID, FU_GID, BACKEND_SEAL.
#
# These tests pin the EXACT option string. Any drift — option removed,
# option added, value changed — fails immediately with a diff. That is
# the whole point: this is the contract between configure_share and the
# kernel cifs module.
#-------------------------------------------------------------------------------
echo "== backend_mount_opts =="
CREDS="/etc/samba/.creds-X"
FU_UID="1002"
FU_GID="1002"
COMMON="credentials=/etc/samba/.creds-X,nosharesock,serverino,uid=1002,gid=1002,file_mode=0660,dir_mode=0770,_netdev,x-systemd.automount,x-systemd.requires=network-online.target"

check_eq "legacy: vers=1.0 + cache=none + nobrl appended" \
    "${COMMON},vers=1.0,cache=none,nobrl" \
    "$(backend_mount_opts legacy)"

# nosharesock invariant — the prod 2026-05-05 multi-share creds-isolation
# fix. If this string ever loses 'nosharesock', this test fails BEFORE any
# scenario boots. Belt-and-suspenders against the most expensive bug we hit.
check_eq "legacy MUST contain nosharesock" \
    "yes" \
    "$(backend_mount_opts legacy | grep -qF nosharesock && echo yes || echo no)"

check_eq "modern + default seal=on → vers=3,seal,soft,echo_interval=10" \
    "${COMMON},vers=3,seal,soft,echo_interval=10" \
    "$(backend_mount_opts modern)"

check_eq "modern + BACKEND_SEAL=no → vers=3,soft,echo_interval=10 (no seal)" \
    "${COMMON},vers=3,soft,echo_interval=10" \
    "$(BACKEND_SEAL=no; backend_mount_opts modern)"

check_eq "modern + BACKEND_SEAL=yes (explicit) → vers=3,seal,soft,echo_interval=10" \
    "${COMMON},vers=3,seal,soft,echo_interval=10" \
    "$(BACKEND_SEAL=yes; backend_mount_opts modern)"

# --backend-vers override (added 2026-05-07 for the HMI device that
# only speaks SMB1/SMB2). Modern profile semantics (relaxed locking,
# soft mount) are preserved; only the version changes.
check_eq "modern + BACKEND_VERS=2.1 → vers=2.1, seal auto-dropped (SMB3-only)" \
    "${COMMON},vers=2.1,soft,echo_interval=10" \
    "$(BACKEND_VERS=2.1; backend_mount_opts modern)"
check_eq "modern + BACKEND_VERS=1.0 → vers=1.0, seal auto-dropped" \
    "${COMMON},vers=1.0,soft,echo_interval=10" \
    "$(BACKEND_VERS=1.0; backend_mount_opts modern)"
check_eq "modern + BACKEND_VERS=3.1.1 (explicit SMB3.1.1) → seal kept" \
    "${COMMON},vers=3.1.1,seal,soft,echo_interval=10" \
    "$(BACKEND_VERS=3.1.1; backend_mount_opts modern)"
check_eq "modern + BACKEND_VERS=3.0 → seal kept" \
    "${COMMON},vers=3.0,seal,soft,echo_interval=10" \
    "$(BACKEND_VERS=3.0; backend_mount_opts modern)"
# Critical invariant: seal must be SUPPRESSED for non-SMB3 versions
# even if BACKEND_SEAL=yes is explicit. The cifs driver would reject
# seal on a vers=2.1 negotiation with NT_STATUS_NOT_SUPPORTED. The
# silent suppress is the right default — emitting `seal` for SMB1/2
# would just break the mount with a confusing error.
check_eq "modern + BACKEND_VERS=2.1 + BACKEND_SEAL=yes → seal STILL suppressed" \
    "${COMMON},vers=2.1,soft,echo_interval=10" \
    "$(BACKEND_VERS=2.1; BACKEND_SEAL=yes; backend_mount_opts modern)"

# Legacy is fixed at vers=1.0 regardless of BACKEND_VERS — the override
# is a CLI-level rejection, but defense-in-depth at the helper level
# would also be cheap. Today the helper just ignores BACKEND_VERS for
# legacy. Pin that.
check_eq "legacy ignores BACKEND_VERS (still vers=1.0)" \
    "${COMMON},vers=1.0,cache=none,nobrl" \
    "$(BACKEND_VERS=2.1; backend_mount_opts legacy)"

check_eq "modern MUST contain nosharesock" \
    "yes" \
    "$(backend_mount_opts modern | grep -qF nosharesock && echo yes || echo no)"

# soft + echo_interval=10 invariants — the offline-device fail-fast
# fix (Layer 1, 2026-05-06). Modern profile MUST have both so Open
# Dialog grays out instead of hanging when a CNC/NAS is powered off.
check_eq "modern MUST have soft (Layer 1 offline-device fail-fast)" \
    "yes" \
    "$(backend_mount_opts modern | grep -qE '(^|,)soft(,|$)' && echo yes || echo no)"
check_eq "modern MUST have echo_interval=10" \
    "yes" \
    "$(backend_mount_opts modern | grep -qF 'echo_interval=10' && echo yes || echo no)"

# Legacy profile MUST NOT have soft — under .TPS multi-writer the
# soft-mount mid-write error would corrupt the database. The legacy
# zone is also expected to be always-on, so the offline annoyance
# doesn't apply. Pin the absence so a future "let me unify the
# profiles' mount options" refactor can't sneak it in.
check_eq "legacy MUST NOT have soft (TPS write-corruption defense)" \
    "no" \
    "$(backend_mount_opts legacy | grep -qE '(^|,)soft(,|$)' && echo yes || echo no)"
check_eq "legacy MUST NOT have echo_interval (no fail-fast on .TPS)" \
    "no" \
    "$(backend_mount_opts legacy | grep -qF 'echo_interval' && echo yes || echo no)"

# Invariant: numeric uid=/gid= must appear in BOTH profiles. The
# default-domain ambiguity defense from configure_share writes them
# numerically; if any future refactor passes a symbolic name through,
# we want to know.
check_eq "legacy MUST have numeric uid=/gid= (not symbolic)" \
    "yes" \
    "$(backend_mount_opts legacy | grep -qE 'uid=[0-9]+,gid=[0-9]+' && echo yes || echo no)"
check_eq "modern MUST have numeric uid=/gid= (not symbolic)" \
    "yes" \
    "$(backend_mount_opts modern | grep -qE 'uid=[0-9]+,gid=[0-9]+' && echo yes || echo no)"

#-------------------------------------------------------------------------------
# frontend_locking_stanza — smb.conf locking lines per kind.
#
# Pin the key directives (oplocks, strict locking) by exact line content.
# We deliberately do NOT pin every comment/whitespace byte — those are
# allowed to evolve. We DO pin the directive lines because changing them
# changes Samba's lock semantics, and that's the whole point of the
# stanza.
#-------------------------------------------------------------------------------
echo "== frontend_locking_stanza =="

TPS=$(frontend_locking_stanza tps-strict)
check_eq "tps-strict: oplocks = no" "yes" \
    "$(grep -qxF '    oplocks = no'        <<< "$TPS" && echo yes || echo no)"
check_eq "tps-strict: level2 oplocks = no" "yes" \
    "$(grep -qxF '    level2 oplocks = no' <<< "$TPS" && echo yes || echo no)"
check_eq "tps-strict: strict locking = yes" "yes" \
    "$(grep -qxF '    strict locking = yes' <<< "$TPS" && echo yes || echo no)"
check_eq "tps-strict: kernel oplocks = no" "yes" \
    "$(grep -qxF '    kernel oplocks = no' <<< "$TPS" && echo yes || echo no)"
check_eq "tps-strict: posix locking = yes" "yes" \
    "$(grep -qxF '    posix locking = yes' <<< "$TPS" && echo yes || echo no)"

REL=$(frontend_locking_stanza relaxed)
check_eq "relaxed: oplocks = yes" "yes" \
    "$(grep -qxF '    oplocks = yes'        <<< "$REL" && echo yes || echo no)"
check_eq "relaxed: level2 oplocks = yes" "yes" \
    "$(grep -qxF '    level2 oplocks = yes' <<< "$REL" && echo yes || echo no)"
check_eq "relaxed: strict locking = no" "yes" \
    "$(grep -qxF '    strict locking = no'  <<< "$REL" && echo yes || echo no)"
check_eq "relaxed: posix locking = yes" "yes" \
    "$(grep -qxF '    posix locking = yes' <<< "$REL" && echo yes || echo no)"

# Regression: 'posix locking = auto' is not a valid Samba boolean
# (caught by testparm in production 2026-05-07: "set_variable_helper
# (auto): value is not boolean!"). Pin that the relaxed stanza never
# regresses to it.
check_eq "relaxed MUST NOT use 'auto' (not a Samba boolean)" \
    "no" \
    "$(grep -qF 'auto' <<< "$REL" && echo yes || echo no)"

# Cross-check: tps-strict MUST NOT have oplocks=yes; relaxed MUST NOT
# have strict locking=yes. Catches a "fix" that copy-pastes the wrong
# stanza into the wrong branch.
check_eq "tps-strict MUST NOT enable oplocks" "yes" \
    "$(grep -q 'oplocks = yes' <<< "$TPS" && echo no || echo yes)"
check_eq "relaxed MUST NOT set strict locking = yes" "yes" \
    "$(grep -q 'strict locking = yes' <<< "$REL" && echo no || echo yes)"

#-------------------------------------------------------------------------------
# share_section_present — regression for the $-in-share-name bug
# caught on the production proxy 2026-05-07. Section presence was
# being detected with `grep -qE "^\[$name\]"`; for a share named
# `Shop$` the regex `^\[Shop$\]` interpreted `$` as end-of-line and
# silently reported every $-bearing share as section-MISSING even
# when the section was present and serving traffic.
#-------------------------------------------------------------------------------
echo "== share_section_present =="

fixture_smb=$(mktemp /tmp/smbproxy-smbconf-XXXX.conf)
trap 'rm -f "$fixture_smb"' EXIT
cat > "$fixture_smb" <<'EOF'
[global]
    realm = LAB.TEST
[Engineering$]
    path = /mnt/legacy/Engineering
[Shop$]
    path = /mnt/legacy/Shop
[Plain]
    path = /mnt/plain
EOF
# Pass the fixture as the optional second arg — SMB_CONF is readonly
# in the script so we can't override it, and the helper takes the
# file path as $2 specifically to make this testable.

# The $-bearing names: must report present.
share_section_present 'Engineering$' "$fixture_smb"
check_rc "share_section_present('Engineering\$') → 0 (present)"  0 $?
share_section_present 'Shop$' "$fixture_smb"
check_rc "share_section_present('Shop\$') → 0 (present)"       0 $?
# Plain ASCII control case.
share_section_present 'Plain' "$fixture_smb"
check_rc "share_section_present('Plain') → 0 (present)"        0 $?
# Negative cases: similar names that are NOT present.
share_section_present 'NotThere' "$fixture_smb"
check_rc "share_section_present('NotThere') → !0 (missing)"    1 $?
share_section_present 'Engineering' "$fixture_smb"   # no $ — different section
check_rc "share_section_present('Engineering') → !0 (the \$ matters)" 1 $?
# Defense check: empty name returns failure (don't accidentally
# match e.g. an `[]` line).
share_section_present '' "$fixture_smb"
check_rc "share_section_present('') → !0"                      1 $?

# Lint: no caller in smbproxy-sconfig.sh should use the old buggy
# `grep -qE "^\[$name\]"` pattern for section detection. Catches a
# future revert where someone "simplifies" share_section_present
# back to an inline grep. Excludes comment lines so the docstring
# in share_section_present (which quotes the old pattern as the
# bug it fixed) doesn't self-match.
buggy_callers=$(grep -cE '^[^#]*grep -qE "\^\\\[\$' "$SCONFIG" 2>/dev/null || true)
check_eq "no caller uses raw grep -qE for section detection" "0" "$buggy_callers"

#-------------------------------------------------------------------------------
echo
echo "summary: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    echo "first failure: $FIRST_FAIL"
    exit 1
fi
exit 0
