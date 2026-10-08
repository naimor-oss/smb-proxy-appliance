#!/usr/bin/env bash
#===============================================================================
# smbproxy-sconfig — SMB1↔SMB3 Proxy Appliance Configuration Tool
#
# Whiptail TUI plus headless CLI. Handles deployment configuration and
# management of an SMB1↔SMB3 protocol-version proxy on Debian 13 (Trixie).
#
# Usage:
#   sudo smbproxy-sconfig                     # interactive TUI
#   sudo smbproxy-sconfig --status            # one-shot summary, exit
#   sudo smbproxy-sconfig --help              # full headless CLI docs
#
# Maintainer map:
#   - TUI menu functions collect input and confirm destructive operations.
#   - Shared helpers do the real work and are also used by the headless CLI
#     at the bottom of this file.
#   - Keep deployment-specific decisions out of prepare-image.sh. If a value
#     depends on realm, DC, legacy backend, share name, or backend creds, set
#     it here.
#   - Read AGENTS.md before changing the locking semantics. Legacy shares use
#     one distinct upstream SMB1 mount/session for every downstream Samba tree
#     connection and normalize them into one Samba file identity. `nobrl` is
#     forbidden: locks must also reach the SMB1 server.
#===============================================================================
set -uo pipefail

readonly VERSION="0.4.0"
readonly SCRIPT_NAME="smbproxy-sconfig"
readonly WT_HEIGHT=22
readonly WT_WIDTH=78
readonly WT_MENU_HEIGHT=14

readonly ROLES_FILE="${SMBPROXY_ROLES_FILE:-/etc/smbproxy/nic-roles.env}"
readonly DETECT_FILE="${SMBPROXY_DETECT_FILE:-/var/lib/smbproxy-init-detected.env}"
readonly STATE_DIR="/var/lib/smbproxy"
readonly DEPLOY_FILE="${STATE_DIR}/deploy.env"
readonly SHARES_DIR="${STATE_DIR}/shares"
readonly CREDS_DIR="/etc/samba"
readonly CREDS_PREFIX=".creds-"
readonly SMB_CONF="/etc/samba/smb.conf"
readonly SMB_CONF_LOCK="/run/lock/smbproxy-smb-conf.lock"
readonly WORKER_LOCK="/run/lock/smbproxy-share-worker.lock"
readonly KRB5_CONF="/etc/krb5.conf"
readonly NFT_TEMPLATE="/etc/nftables-smbproxy.conf"
readonly NFT_LIVE="/etc/nftables.conf"
readonly DATA_ROOT="/srv/smbproxy-data"
readonly SESSION_ROOT="/run/smbproxy/sessions"
readonly SESSION_STATE="/run/smbproxy/session-state"
readonly SESSION_HELPER="/usr/local/sbin/smbproxy-session-mount"
readonly VFS_VERSION_HELPER="/usr/local/sbin/smbproxy-vfs-version-check"
readonly SAMBA_HOLD_HELPER="/usr/local/sbin/smbproxy-samba-hold"

readonly JOIN_LOG="/var/log/smbproxy-join.log"
readonly SHARE_LOG="/var/log/smbproxy-share.log"

# Per-share profile names. The profile picks the cifs mount option
# preset, the smb.conf locking-stanza preset, the default mount path,
# and whether the legacy (backend-isolation) NIC role is required.
# Adding a profile means adding cases to backend_mount_opts,
# resolve_locking_kind, share_default_mount, and any_legacy_profile_shares.
readonly PROFILE_LEGACY="legacy"
readonly PROFILE_MODERN="modern"
readonly OFFLINE_DIRECT="direct"
readonly OFFLINE_QUEUED="queued"

#===============================================================================
# UTILITIES
#===============================================================================
# Source the shared appliance-core libs that prepare-image.sh §16b
# vendored to /usr/local/lib/appliance-core/. Sentinel-guarded, so
# sourcing every time smbproxy-sconfig starts is cheap. Older images
# without the libs work fine for paths that don't depend on them.
APPCORE_LIBS=/usr/local/lib/appliance-core
if [[ -d "$APPCORE_LIBS" ]]; then
    [[ -f "$APPCORE_LIBS/identity.sh"   ]] && source "$APPCORE_LIBS/identity.sh"
    [[ -f "$APPCORE_LIBS/tui.sh"        ]] && source "$APPCORE_LIBS/tui.sh"
    [[ -f "$APPCORE_LIBS/hostname.sh"   ]] && source "$APPCORE_LIBS/hostname.sh"
    [[ -f "$APPCORE_LIBS/detect-net.sh" ]] && source "$APPCORE_LIBS/detect-net.sh"
    [[ -f "$APPCORE_LIBS/netconfig.sh"  ]] && source "$APPCORE_LIBS/netconfig.sh"
    [[ -f "$APPCORE_LIBS/timezone.sh"   ]] && source "$APPCORE_LIBS/timezone.sh"
fi

# info / yesno / die delegate to appliance-core's sized whiptail
# wrappers when available. The old hand-fixed dimensions (12x64,
# 10x60) clipped wide content and looked starved on roomy consoles;
# the appcore variants compute size from `tput` and cap at 24x100
# for readability. Fallbacks preserve the old behavior when the
# lib isn't vendored (older images, smoke tests).
die() {
    if command -v appcore_tui_msgbox >/dev/null 2>&1; then
        appcore_tui_msgbox "FATAL: $*"
    else
        whiptail --msgbox "FATAL: $*" 10 60
    fi
    exit 1
}
info() {
    if command -v appcore_tui_msgbox >/dev/null 2>&1; then
        appcore_tui_msgbox "$*"
    else
        whiptail --msgbox "$*" 12 64
    fi
}
yesno() {
    if command -v appcore_tui_yesno >/dev/null 2>&1; then
        appcore_tui_yesno "$*"
    else
        whiptail --yesno "$*" 10 60
    fi
}

# info_text — sized dialog for message bodies that contain LITERAL
# backslashes (DOMAIN\Group examples, UNC paths). Delegates to
# appcore_tui_show_text which uses --textbox and reads the body
# byte-for-byte, so `LAB\Domain Admins` displays as-is instead of
# whiptail interpreting `\D` / `\A` as escape sequences.
# Fallback doubles `\` so single-backslash content still renders
# correctly under the --msgbox path.
info_text() {
    local title="$1" body="$2"
    if command -v appcore_tui_show_text >/dev/null 2>&1; then
        appcore_tui_show_text "$title" "$body"
    else
        info "${body//\\/\\\\}"
    fi
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Run as root (sudo smbproxy-sconfig)." >&2
        exit 1
    fi
}

# Append a timestamped line to the share-action log. Top-level (not
# nested in a function) so it's defined for every entry point: TUI,
# CLI, and tests. configure_share calls this for WARN/ERROR. Logfile
# is created on first write at mode 0600 since it may carry operator-
# facing diagnostics (never credentials).
log_share() {
    local f="$SHARE_LOG"
    if [[ ! -f "$f" ]]; then
        : > "$f" 2>/dev/null && chmod 0600 "$f" 2>/dev/null
    fi
    printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$f"
    # Also echo to stderr so the message reaches a CLI operator who
    # is watching stdout/stderr and won't think to tail the log file.
    printf '%s\n' "$*" >&2
}

# Idempotent loaders for the two persistent state files written by
# smbproxy-init and by sconfig itself.
load_roles() {
    DOMAIN_NIC_NAME="" DOMAIN_NIC_MAC=""
    LEGACY_NIC_NAME="" LEGACY_NIC_MAC=""
    if [[ -f "$ROLES_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$ROLES_FILE"
    fi
}

load_deploy() {
    # Domain-level state only. Per-share state lives under $SHARES_DIR;
    # see load_share() below.
    REALM="" DOMAIN_SHORT="" DC_HOST="" DC_IP=""
    if [[ -f "$DEPLOY_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$DEPLOY_FILE"
    fi
}

_proxy_detect_cache_value() {
    local key="$1"
    [[ -r "$DETECT_FILE" ]] || return 0
    awk -F= -v key="$key" '
        $1 == key {
            value=substr($0, index($0, "=") + 1)
            sub(/^"/, "", value); sub(/"$/, "", value)
            print value
            exit
        }
    ' "$DETECT_FILE"
}

# Canonical deployment context. Only the persisted Domain/LAN NIC may
# contribute the appliance IP, gateway, resolver, DHCP domain, or PTR.
# Before roles are assigned, appliance-core safely falls back to the
# default-route interface; the gateway-less legacy link cannot win.
refresh_proxy_network_context() {
    load_roles
    APPCORE_DET_IFACE="" APPCORE_DET_IP="" APPCORE_DET_GATEWAY=""
    APPCORE_DET_DHCP_DNS="" APPCORE_DET_DHCP_DOMAIN=""
    APPCORE_DET_PTR_FQDN=""
    APPCORE_DET_PTR_DOMAIN="" APPCORE_DET_EFFECTIVE_DOMAIN=""
    APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE=""
    if command -v appcore_detect_net_init >/dev/null 2>&1; then
        appcore_detect_net_init "$DETECT_FILE" "${DOMAIN_NIC_NAME:-}" \
            >/dev/null 2>&1 || true
        return
    fi

    # Compatibility path for an older image without the shared detector.
    APPCORE_DET_IFACE=$(_proxy_detect_cache_value APPCORE_DET_IFACE)
    APPCORE_DET_IP=$(_proxy_detect_cache_value APPCORE_DET_IP)
    APPCORE_DET_GATEWAY=$(_proxy_detect_cache_value APPCORE_DET_GATEWAY)
    APPCORE_DET_DHCP_DNS=$(_proxy_detect_cache_value APPCORE_DET_DHCP_DNS)
    APPCORE_DET_DHCP_DOMAIN=$(_proxy_detect_cache_value APPCORE_DET_DHCP_DOMAIN)
    APPCORE_DET_PTR_DOMAIN=$(_proxy_detect_cache_value APPCORE_DET_PTR_DOMAIN)
    APPCORE_DET_EFFECTIVE_DOMAIN="${APPCORE_DET_DHCP_DOMAIN:-$APPCORE_DET_PTR_DOMAIN}"
}

refresh_proxy_domain_defaults() {
    refresh_proxy_network_context
    PROXY_DEFAULT_REALM=$(printf '%s' "${APPCORE_DET_EFFECTIVE_DOMAIN:-}" \
        | tr '[:lower:]' '[:upper:]')
    PROXY_DEFAULT_DOMAIN_SHORT="${PROXY_DEFAULT_REALM%%.*}"
    PROXY_DEFAULT_DC=""
    local domain="${APPCORE_DET_EFFECTIVE_DOMAIN:-}" dc
    if [[ -n "$domain" ]]; then
        dc=$(timeout 5 dig +short -t SRV "_ldap._tcp.${domain}" 2>/dev/null \
            | awk 'NR==1 {sub(/\.$/,"",$4); print $4}') || dc=""
        PROXY_DEFAULT_DC="$dc"
    fi
    export PROXY_DEFAULT_REALM PROXY_DEFAULT_DOMAIN_SHORT PROXY_DEFAULT_DC
}

#-------------------------------------------------------------------------------
# Per-share state model.
#
# Each proxied share has:
#   - one env file at $SHARES_DIR/<safe>.env carrying SHARE_NAME plus all
#     non-credential per-share fields (BACKEND_IP, BACKEND_USER,
#     BACKEND_DOMAIN, BACKEND_MOUNT, FRONT_GROUP, FRONT_FORCE_USER).
#   - one credentials file at $CREDS_DIR/$CREDS_PREFIX<safe> mode 0600
#     root:root, carrying username/password/domain for the cifs mount.
#   - modern shares: one cifs entry in /etc/fstab.
#   - legacy shares: runtime CIFS mounts under $SESSION_ROOT, one per Samba
#     session/tree, with lifecycle records under $SESSION_STATE.
#   - one [SHARE_NAME] section in $SMB_CONF.
#
# By convention SHARE_NAME is used as both the legacy backend share name
# AND the published SMB3 frontend share name (per the user's deployment
# model — operator picks one name and it appears at both ends).
# <safe> is the SHARE_NAME with non-alphanumeric characters replaced by
# underscore, so a $-bearing share like "Engineering$" stores as
# Engineering_.env / .creds-Engineering_ on the filesystem while the literal
# name lives in SHARE_NAME.
#-------------------------------------------------------------------------------

share_safe_name() {
    # Sanitize SHARE_NAME for use in filesystem paths. Idempotent —
    # already-sanitized names pass through unchanged.
    echo "${1//[^A-Za-z0-9_]/_}"
}

# Validate a proposed share name. Single point of truth for both the
# CLI (cli_configure_share) and TUI (shares_add_wizard). Rejects:
#
#   - empty
#   - characters not legal in SMB share names (\ / [ ] < > " ')
#   - whitespace (spaces would land unescaped in fstab and break the
#     mount; tabs/newlines are even worse)
#   - shell metacharacters that would re-interpret if the name leaked
#     unquoted into a shell command line ($ ` ; | & * ? ( ) {} ! ~ #)
#     We DO permit a single trailing `$` because that's the standard
#     marker for a hidden SMB share and is common in real deployments
#     (e.g. `Engineering$`).
#
# Prints an error to stderr on rejection and returns non-zero.
share_name_validate() {
    local name="$1"
    if [[ -z "$name" ]]; then
        echo "share name cannot be empty" >&2; return 1
    fi
    # Bash =~ with a literal char class can be brittle once you start
    # backslash-escaping inside [...]. Storing the regex in a variable
    # AND the char list in a plain glob check sidesteps the entire
    # quoting problem. We just iterate the bad-chars string.
    local bad_chars=$'/\\[]<>"\''
    local i ch
    for (( i=0; i<${#bad_chars}; i++ )); do
        ch="${bad_chars:i:1}"
        # Use globbing to test substring presence — neutral to ERE quirks.
        case "$name" in
            *"$ch"*)
                echo "share name '$name' contains a character not allowed in SMB share names (one of: / \\ [ ] < > \" ')" >&2
                return 1
                ;;
        esac
    done
    if [[ "$name" =~ [[:space:]] ]]; then
        echo "share name '$name' contains whitespace; not supported (would break fstab parsing)" >&2
        return 1
    fi
    # Shell metas. Special-case: a SINGLE trailing `$` is the SMB
    # hidden-share marker and is allowed; a `$` anywhere else is
    # rejected because it would expand if the name ever reached a
    # double-quoted shell context.
    local stripped="${name%\$}"
    local meta_chars='$`;|&*?(){}!~#'
    for (( i=0; i<${#meta_chars}; i++ )); do
        ch="${meta_chars:i:1}"
        case "$stripped" in
            *"$ch"*)
                echo "share name '$name' contains shell metacharacters" >&2
                return 1
                ;;
        esac
    done
    return 0
}

# Reject a proposed share name if its safe form collides with another
# already-registered share's safe form. Without this, both `A-B` and
# `A_B` map to `A_B.env` and the second add would silently overwrite
# the first's state file. Returns 0 on collision (caller must reject),
# 1 on no collision (safe to add). On collision the offending peer name
# is printed to stdout so the caller can include it in the error.
#
# Idempotency: the proposed name colliding with ITSELF (operator
# re-uses an existing exact name) is NOT a safe-name collision — it's
# a duplicate-name collision, and that's caught earlier by the
# duplicate-name check in the add-wizard / cli_add_share. We exclude
# self-match here so an Edit operation doesn't false-positive.
share_safe_name_collides_with_existing() {
    local proposed="$1"
    local proposed_safe; proposed_safe=$(share_safe_name "$proposed")
    local existing
    while IFS= read -r existing; do
        [[ -z "$existing" ]] && continue
        [[ "$existing" == "$proposed" ]] && continue
        if [[ "$(share_safe_name "$existing")" == "$proposed_safe" ]]; then
            printf '%s' "$existing"
            return 0
        fi
    done < <(list_shares 2>/dev/null)
    return 1
}

share_state_file() {
    echo "${SHARES_DIR}/$(share_safe_name "$1").env"
}

share_creds_file() {
    echo "${CREDS_DIR}/${CREDS_PREFIX}$(share_safe_name "$1")"
}

# Offline behavior is orthogonal to the backend protocol/locking
# profile. Legacy ISAM shares must stay direct because replaying
# cached writes would violate their live locking contract.
offline_mode_validate() {
    local profile="$1" mode="$2"
    case "$mode" in
        "$OFFLINE_DIRECT") return 0 ;;
        "$OFFLINE_QUEUED")
            [[ "$profile" == "$PROFILE_MODERN" ]]
            return
            ;;
        *) return 2 ;;
    esac
}

data_mount_ready() {
    local target
    target=$(findmnt -rn -T "$DATA_ROOT" -o TARGET 2>/dev/null || true)
    [[ "$target" == "$DATA_ROOT" ]]
}

# Print unmounted whole disks suitable for the appliance data volume.
# Mounted disks (including the OS disk, which has mounted descendants)
# are omitted from the interactive picker.
data_disk_candidates() {
    local device size model mountpoint
    while read -r device size model; do
        [[ -n "$device" ]] || continue
        while IFS= read -r mountpoint; do
            [[ -n "$mountpoint" ]] && continue 2
        done < <(lsblk -nrpo MOUNTPOINT "$device" 2>/dev/null)
        printf '%s\t%s %s\n' "$device" "$size" "${model:-unlabelled disk}"
    done < <(lsblk -dnpo NAME,SIZE,MODEL -e 7,11 2>/dev/null)
}

# Destructive by design and called only after the CLI/TUI has required
# an explicit erase confirmation. The whole secondary disk is ext4 so
# resize2fs can grow it directly after the hypervisor expands it.
initialize_data_disk() {
    local device="$1"
    [[ -b "$device" ]] || {
        echo "not a block device: $device" >&2
        return 2
    }
    [[ "$(lsblk -dnro TYPE "$device" 2>/dev/null)" == "disk" ]] || {
        echo "data device must be a whole disk, not a partition: $device" >&2
        return 2
    }
    if data_mount_ready; then
        echo "$DATA_ROOT is already mounted; refusing to replace it" >&2
        return 2
    fi

    local mountpoint
    while IFS= read -r mountpoint; do
        if [[ -n "$mountpoint" ]]; then
            echo "$device or one of its children is mounted at $mountpoint" >&2
            return 2
        fi
    done < <(lsblk -nrpo MOUNTPOINT "$device" 2>/dev/null)

    local command_name
    for command_name in wipefs mkfs.ext4 blkid findmnt mount; do
        command -v "$command_name" >/dev/null 2>&1 || {
            echo "required command not installed: $command_name" >&2
            return 2
        }
    done

    wipefs -a -- "$device" || return
    mkfs.ext4 -F -L SMBPROXY_DATA "$device" || return
    udevadm settle 2>/dev/null || true

    local uuid
    uuid=$(blkid -s UUID -o value "$device" 2>/dev/null)
    [[ -n "$uuid" ]] || {
        echo "formatted $device but could not read its UUID" >&2
        return 3
    }

    install -d -o root -g root -m 0755 "$DATA_ROOT"
    sed -i "\|[[:space:]]${DATA_ROOT}[[:space:]]|d" /etc/fstab
    printf 'UUID=%s %s ext4 defaults,nofail,x-systemd.device-timeout=10s 0 2\n' \
        "$uuid" "$DATA_ROOT" >> /etc/fstab
    systemctl daemon-reload
    mount "$DATA_ROOT" || return
    data_mount_ready || {
        echo "$device did not mount at $DATA_ROOT" >&2
        return 3
    }
    install -d -o root -g root -m 0755 \
        "${DATA_ROOT}/shares" "${DATA_ROOT}/state"
}

grow_data_disk() {
    data_mount_ready || {
        echo "no data filesystem mounted at $DATA_ROOT" >&2
        return 2
    }
    local source fstype
    source=$(findmnt -nro SOURCE -T "$DATA_ROOT" 2>/dev/null)
    fstype=$(findmnt -nro FSTYPE -T "$DATA_ROOT" 2>/dev/null)
    [[ "$fstype" == "ext4" ]] || {
        echo "data filesystem must be ext4 to grow (found: ${fstype:-unknown})" >&2
        return 2
    }
    resize2fs "$source"
}

# The frontend serves the live static cifs mount for modern/direct shares,
# the data disk for queued shares, and a VFS-replaced placeholder for legacy
# shares. Optional fourth arg is a test seam; fifth is profile.
share_frontend_path() {
    local name="$1" mode="$2" backend_mount="$3"
    local data_root="${4:-$DATA_ROOT}"
    local profile="${5:-$PROFILE_LEGACY}"
    case "$mode" in
        "$OFFLINE_QUEUED") echo "${data_root}/shares/$(share_safe_name "$name")" ;;
        *)
            if [[ "$profile" == "$PROFILE_LEGACY" ]]; then
                echo "$SESSION_ROOT"
            else
                echo "$backend_mount"
            fi
            ;;
    esac
}

# Profile-aware default mount path. The legacy profile keeps the
# historical /mnt/legacy/<safe> path so prior installs don't move
# around; the modern profile lives under /mnt/backend/<safe> to
# reflect that the backend may be on the domain LAN, not in a
# dedicated legacy zone. Caller passes profile as the second arg;
# absent = legacy.
share_default_mount() {
    local name="$1" profile="${2:-$PROFILE_LEGACY}"
    case "$profile" in
        modern) echo "/mnt/backend/$(share_safe_name "$name")" ;;
        *)      echo "/mnt/legacy/$(share_safe_name "$name")" ;;
    esac
}

# Map (profile, --locking override) -> effective locking kind. The
# effective kind is what frontend_locking_stanza branches on. Two
# kinds today: tps-strict (the ISAM-style (e.g. Clarion .TPS) profile) and
# relaxed (suitable for routine file-copy backends like CNCs and NAS).
# Override "profile-default" (or empty) defers to the profile's
# default. Returns 2 on an unrecognized override.
resolve_locking_kind() {
    local profile="$1" override="${2:-profile-default}"
    case "$override" in
        tps-strict|relaxed) echo "$override" ;;
        profile-default|"")
            case "$profile" in
                modern) echo "relaxed" ;;
                *)      echo "tps-strict" ;;
            esac ;;
        *) return 2 ;;
    esac
}

# Emits the comma-separated cifs option list for the given profile,
# using the per-share globals CREDS / FU_UID / FU_GID / BACKEND_SEAL.
# The mode/automount/uid/gid/credentials options are common; the
# version, caching, locking, and encryption options diverge.
backend_mount_opts() {
    local profile="$1"
    local common="credentials=${CREDS},nosharesock,serverino,uid=${FU_UID},gid=${FU_GID},file_mode=0660,dir_mode=0770,_netdev,x-systemd.automount,x-systemd.requires=network-online.target"
    case "$profile" in
        modern)
            # cache=strict is the kernel default for cifs and is correct
            # when the proxy is one of several clients hitting a modern
            # backend (the device may have its own writers). seal=
            # SMB3 wire encryption; ~10-30% CPU but cheap enough for
            # the slow IO patterns these devices generate. seal is
            # SMB3-only and is auto-suppressed when the negotiated
            # version is below SMB3 (see vers handling below).
            #
            # soft + echo_interval=10: when the backend device is off
            # (CNC powered down, NAS rebooted), the kernel cifs default
            # of `hard` blocks indefinitely waiting for the TCP
            # connection to come back. Windows clients that have a
            # drive letter to the proxied share then see Open Dialog /
            # Explorer hang for ~60-75s on every directory listing —
            # the dominant offline-device annoyance reported on the
            # shop floor 2026-05. With `soft`, the kernel returns I/O
            # errors after `echo_interval=10`s of failed heartbeats,
            # Samba forwards a clean SMB error to Windows, and Open
            # Dialog grays out the share immediately instead of
            # freezing. This is safe for the modern profile because
            # the access pattern is file-copy (CNC programs, NAS
            # archive); a mid-copy retry is preferable to a 60s freeze.
            # NOT applicable to the legacy profile — see below.
            #
            # vers: defaults to 3 (the modern-profile assumption) but
            # is overridable via BACKEND_VERS. Real-world need surfaced
            # 2026-05-07 with an HMI device that only speaks SMB1/SMB2;
            # forcing vers=3 made the cifs negotiation fail. The
            # override keeps the modern profile's other semantics
            # (relaxed locking, soft mount, automount) intact while
            # letting the version match the device's capability.
            local vers="${BACKEND_VERS:-3}"
            # `default` means "let cifs negotiate" — emit no vers= token
            # at all (passing literal vers=default would make cifs reject
            # the mount). Build the version fragment accordingly.
            local versopt=""
            if [[ "$vers" != "default" ]]; then
                versopt=",vers=${vers}"
            fi
            local sealopt=""
            # seal is SMB3-only. Drop it silently for older versions
            # — the encryption simply isn't part of the SMB1/2 wire
            # format, so emitting `seal` would make the cifs mount
            # fail to negotiate. With `default`, cifs may negotiate
            # any version including pre-SMB3, so be conservative and
            # also drop seal when no explicit vers is asserted.
            if [[ "${BACKEND_SEAL:-yes}" == "yes" ]] && [[ "$vers" =~ ^3 ]]; then
                sealopt=",seal"
            fi
            # x-systemd.mount-timeout=4: caps each automount attempt at
            # 4 seconds so an offline device (ARP probe cycle on the same
            # /24 takes ~6s by default) fails fast. 4s is enough for a
            # responsive device on the LAN to complete mount+auth in <1s.
            echo "${common}${versopt}${sealopt},soft,echo_interval=10,x-systemd.mount-timeout=4"
            ;;
        *)
            # Legacy mounts are created dynamically by smbproxy_session,
            # never by fstab. Each tree gets its own mount point, while
            # nosharesock gives it a distinct SMB1 transport/session.
            # `nobrl` is intentionally absent: POSIX byte-range locks from
            # smbd must become SMB1 LOCKING_ANDX requests at the backend.
            # `hard` is explicit because the deployed Debian CIFS client
            # otherwise reports a soft mount; TPS writes must wait rather
            # than turn a transient backend outage into an I/O error.
            echo "credentials=${CREDS},vers=1.0,cache=none,hard,nosharesock,serverino,uid=${FU_UID},gid=${FU_GID},file_mode=0660,dir_mode=0770"
            ;;
    esac
}

# Emit the VFS stanza that replaces SESSION_ROOT with one exact mount keyed by
# Samba's authenticated session id and tree id. Modern/queued shares do not use
# the module.
frontend_session_stanza() {
    local profile="${1:-$PROFILE_LEGACY}" mode="${2:-$OFFLINE_DIRECT}"
    if [[ "$profile" == "$PROFILE_LEGACY" && "$mode" == "$OFFLINE_DIRECT" ]]; then
        cat <<'STANZA'
    # Maps this downstream authenticated tree to its own SMB1 session, then
    # normalizes the separate CIFS superblocks into one Samba lock identity.
    vfs objects = smbproxy_session fileid
    fileid:algorithm = fsname
STANZA
    fi
}

# Emits the smb.conf locking-stanza lines (already indented for the
# share section) for the given effective locking kind.
frontend_locking_stanza() {
    local kind="$1"
    case "$kind" in
        relaxed)
            cat <<'STANZA'
    # Relaxed locking for routine file-copy backends (CNC, NAS,
    # archive). The proxy is not assumed to be the sole writer;
    # oplocks let modern Windows clients cache locally for speed.
    oplocks = yes
    level2 oplocks = yes
    strict locking = no
    kernel oplocks = no
    posix locking = yes
STANZA
            ;;
        *)
            cat <<'STANZA'
    # Strict locking for ISAM/.TPS multi-user databases; do NOT relax
    # without reading AGENTS.md first.
    oplocks = no
    level2 oplocks = no
    strict locking = yes
    kernel oplocks = no
    posix locking = yes
STANZA
            ;;
    esac
}

# Emits the share's `root preexec` probe stanza for every direct share.
# Queued shares serve the local data disk and therefore do not probe the
# delivery backend when an office client connects.
#
# Direct mode: a 1s TCP probe of the backend at tree-connect time,
# with `close = yes` so an offline device aborts the tree connect
# immediately. Without this, an offline backend produces ~60s of
# Windows retries — Samba returns NT_STATUS_ACCESS_DENIED on every
# chdir (because the automount fails after our 4s mount-timeout cap),
# Windows interprets that as "transient, retry," and loops ~12 times.
# The probe short-circuits to ~1s.
#
frontend_offline_probe_stanza() {
    local profile="${1:-$PROFILE_LEGACY}"
    local mode="${2:-$OFFLINE_DIRECT}"
    if [[ "$mode" == "$OFFLINE_DIRECT" ]]; then
        cat <<'STANZA'
    # Pre-connect backend probe (see smbproxy-probe-backend). Aborts
    # the tree connect in ~1s if the backend device is powered off,
    # so the client sees one fast error instead of cycling ~12 times
    # through automount-fails-then-ACCESS_DENIED for ~60s.
    # %S is quoted so a share name containing spaces (or other
    # shell-metas; share-name validation should already reject those
    # but quoting is defense in depth) reaches the probe as one argv.
    root preexec = /usr/local/sbin/smbproxy-probe-backend "%S"
    root preexec close = yes
STANZA
    fi
}

# Returns 0 if any configured share uses the legacy profile. Used by
# the firewall step: legacy NIC role assignment is required only when
# at least one legacy-profile share is configured.
any_legacy_profile_shares() {
    [[ -d "$SHARES_DIR" ]] || return 1
    shopt -s nullglob
    local f p
    for f in "$SHARES_DIR"/*.env; do
        # shellcheck disable=SC1090
        p=$( PROFILE=""; source "$f" 2>/dev/null; printf '%s' "${PROFILE:-$PROFILE_LEGACY}" )
        if [[ "$p" == "$PROFILE_LEGACY" ]]; then
            shopt -u nullglob
            return 0
        fi
    done
    shopt -u nullglob
    return 1
}

# list_shares emits one SHARE_NAME per line. Empty output = no shares.
# Reads SHARE_NAME from each env file rather than using the safe name,
# so the output preserves $-suffixes etc.
list_shares() {
    [[ -d "$SHARES_DIR" ]] || return 0
    shopt -s nullglob
    local f
    for f in "$SHARES_DIR"/*.env; do
        # shellcheck disable=SC1090
        ( SHARE_NAME=""; source "$f" 2>/dev/null; printf '%s\n' "$SHARE_NAME" )
    done
    shopt -u nullglob
}

# load_share clears all per-share globals first, then sources the env
# file for the named share. Returns 1 if the share doesn't exist.
# Pre-profile env files (no PROFILE field) load as the legacy profile
# with no seal/locking overrides — clean migration for existing installs.
load_share() {
    local name="$1"
    SHARE_NAME="" BACKEND_IP="" BACKEND_USER="" BACKEND_DOMAIN=""
    BACKEND_MOUNT="" FRONT_GROUP="" FRONT_FORCE_USER=""
    PROFILE="" OFFLINE_MODE="" BACKEND_SEAL="" LOCKING_OVERRIDE="" BACKEND_VERS=""
    local f
    f=$(share_state_file "$name")
    [[ -f "$f" ]] || return 1
    # shellcheck disable=SC1090
    source "$f"
    # Migration default: missing PROFILE = legacy.
    PROFILE="${PROFILE:-$PROFILE_LEGACY}"
    # Migration default: existing shares continue serving the live backend.
    OFFLINE_MODE="${OFFLINE_MODE:-$OFFLINE_DIRECT}"
}

# save_share persists a share's non-credential fields. Caller must have
# all the relevant globals set (SHARE_NAME, BACKEND_IP, etc.). Creds
# are NEVER written here — they live in the per-share creds file.
save_share() {
    [[ -n "${SHARE_NAME:-}" ]] || return 2
    install -d -o root -g root -m 0755 "$SHARES_DIR"
    local f
    f=$(share_state_file "$SHARE_NAME")
    cat > "$f" <<EOF
# Generated by $SCRIPT_NAME. Safe to edit by hand if you know why.
# Credentials live in $(share_creds_file "$SHARE_NAME") (mode 0600), not here.
SHARE_NAME="${SHARE_NAME}"
PROFILE="${PROFILE:-$PROFILE_LEGACY}"
OFFLINE_MODE="${OFFLINE_MODE:-$OFFLINE_DIRECT}"
BACKEND_IP="${BACKEND_IP:-}"
BACKEND_USER="${BACKEND_USER:-}"
BACKEND_DOMAIN="${BACKEND_DOMAIN:-}"
BACKEND_MOUNT="${BACKEND_MOUNT:-}"
BACKEND_VERS="${BACKEND_VERS:-}"
BACKEND_SEAL="${BACKEND_SEAL:-}"
FRONT_GROUP="${FRONT_GROUP:-}"
FRONT_FORCE_USER="${FRONT_FORCE_USER:-}"
LOCKING_OVERRIDE="${LOCKING_OVERRIDE:-}"
EOF
    chmod 0644 "$f"
}

# remove_share tears down everything for one share: state file, creds
# file, fstab line, smb.conf section. Caller must confirm. Returns 0
# even if some pieces were already absent — idempotent.
remove_share() {
    local name="$1"
    [[ -n "$name" ]] || return 2

    # Best-effort unmount before stripping the fstab line — otherwise
    # an active mount lingers without a way to be referenced.
    local mount_path queued_state="" share_profile=""
    if load_share "$name" 2>/dev/null && [[ -n "$BACKEND_MOUNT" ]]; then
        mount_path="$BACKEND_MOUNT"
        share_profile="${PROFILE:-$PROFILE_LEGACY}"
        if [[ "${OFFLINE_MODE:-$OFFLINE_DIRECT}" == "$OFFLINE_QUEUED" ]]; then
            if ! data_mount_ready; then
                echo "cannot remove queued share '$name' while $DATA_ROOT is not mounted" >&2
                return 3
            fi
            queued_state="${DATA_ROOT}/state/$(share_safe_name "$name")"
        fi
    fi

    if [[ "$share_profile" == "$PROFILE_LEGACY" ]]; then
        if [[ ! -x "$SESSION_HELPER" ]]; then
            echo "cannot remove legacy share '$name': session helper is missing" >&2
            return 4
        fi
        # Close active trees first so every open/FID and backend lock is
        # released before the corresponding SMB1 session is unmounted.
        smbcontrol smbd close-share "$name" 2>/dev/null || true
        local _wait
        for _wait in 1 2 3 4 5; do
            [[ "$(legacy_session_count "$name")" == "0" ]] && break
            sleep 1
        done
        if ! "$SESSION_HELPER" cleanup-share "$name"; then
            echo "cannot remove legacy share '$name': upstream sessions are still active" >&2
            return 4
        fi
    fi

    local worker_lock_fd smb_lock_fd
    install -d -m 0755 "$(dirname "$WORKER_LOCK")"
    exec {worker_lock_fd}>"$WORKER_LOCK"
    flock -x "$worker_lock_fd"

    if [[ -n "${mount_path:-}" ]]; then
        if [[ "$share_profile" != "$PROFILE_LEGACY" ]] \
            && backend_mount_active "$mount_path" 2>/dev/null; then
            umount "$mount_path" 2>/dev/null || true
        fi
        # Also removes a pre-session-design legacy line during upgrade/removal.
        sed -i "\| ${mount_path} cifs |d" /etc/fstab 2>/dev/null || true
    fi

    # Strip the [SHARE_NAME] section from smb.conf, if present and
    # smb.conf exists.
    if [[ -f "$SMB_CONF" ]]; then
        exec {smb_lock_fd}>"$SMB_CONF_LOCK"
        flock -x "$smb_lock_fd"
        awk -v sname="[$name]" '
            BEGIN { in_share=0 }
            $0 == sname { in_share=1; next }
            /^\[/ && in_share { in_share=0 }
            !in_share { print }
        ' "$SMB_CONF" > "${SMB_CONF}.new" && mv "${SMB_CONF}.new" "$SMB_CONF"
        chmod 0644 "$SMB_CONF" 2>/dev/null || true
        exec {smb_lock_fd}>&-
    fi

    rm -f "$(share_state_file "$name")"
    rm -f "$(share_creds_file "$name")"
    # Retain office files for recovery but discard delivery history so a
    # later re-add cannot replay stale delete intent.
    if [[ -n "$queued_state" ]]; then
        rm -rf -- "$queued_state"
    fi
    systemctl daemon-reload 2>/dev/null || true
    if systemctl is-active --quiet smbd 2>/dev/null; then
        systemctl reload smbd 2>/dev/null || systemctl restart smbd 2>/dev/null || true
    fi
    exec {worker_lock_fd}>&-
    return 0
}

save_deploy() {
    # Domain-level state only. Per-share state (BACKEND_*/FRONT_*) is
    # written by save_share() into $SHARES_DIR/<safe>.env; per-share
    # creds live in $(share_creds_file ...) at mode 0600. Nothing
    # credential-shaped ever lands here.
    mkdir -p "$STATE_DIR"
    cat > "$DEPLOY_FILE" <<EOF
# Generated by smbproxy-sconfig. Safe to edit by hand if you know why.
# Per-share state lives under $SHARES_DIR/; never edit creds here.
REALM="${REALM:-}"
DOMAIN_SHORT="${DOMAIN_SHORT:-}"
DC_HOST="${DC_HOST:-}"
DC_IP="${DC_IP:-}"
EOF
    chmod 0644 "$DEPLOY_FILE"
}

get_hostname()  { hostname -s 2>/dev/null || echo "(not set)"; }
get_fqdn()      { hostname -f 2>/dev/null || echo "(not set)"; }
get_default_iface() {
    ip -4 route show default 2>/dev/null | awk '/default/{print $5; exit}'
}

# Resolve a hostname to an IPv4 using the CURRENT system resolver. Same
# rationale as the AD-DC appliance: doing this BEFORE rewriting
# /etc/resolv.conf is the difference between a DC IP we can talk to and
# a literal hostname string that breaks DNS entirely.
resolve_dc_ip() {
    local host="$1"
    if [[ "$host" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]]; then
        printf '%s' "$host"
        return 0
    fi
    local ip
    ip=$(getent ahostsv4 "$host" 2>/dev/null | awk 'NR==1 {print $1}')
    [[ -n "$ip" ]] || return 1
    printf '%s' "$ip"
}

# Take exclusive ownership of /etc/resolv.conf. systemd-resolved manages
# it as a symlink and rewrites the target on its own schedule; that
# clobbers our DC-pointed nameserver and breaks Samba.
take_over_resolv_conf() {
    if systemctl is-active systemd-resolved &>/dev/null 2>&1; then
        systemctl disable --now systemd-resolved >/dev/null 2>&1 || true
    fi
    if [[ -L /etc/resolv.conf ]]; then
        rm -f /etc/resolv.conf
    fi
}

is_joined() {
    [[ -f "$SMB_CONF" ]] && grep -q '^[[:space:]]*security[[:space:]]*=[[:space:]]*ads' "$SMB_CONF" 2>/dev/null
}

backend_mount_active() {
    local mp="$1"
    [[ -n "$mp" ]] || return 1
    # mountpoint -q returns true for the automount filesystem itself
    # (which is always present as long as the unit is active), even
    # when the underlying cifs mount has not been established. Check
    # /proc/mounts for an actual cifs entry at this path instead.
    grep -q " ${mp} cifs " /proc/mounts 2>/dev/null
}

# Count active dynamic SMB1 session mounts for one legacy share. State files
# are root-owned runtime records written only after a CIFS mount succeeds.
legacy_session_count() {
    local name="$1" count=0 f recorded
    [[ -d "$SESSION_STATE" ]] || { echo 0; return; }
    shopt -s nullglob
    for f in "$SESSION_STATE"/*.env; do
        recorded=$(sed -n 's/^SHARE_NAME="\(.*\)"$/\1/p' "$f" 2>/dev/null | head -1)
        [[ "$recorded" == "$name" ]] && count=$((count + 1))
    done
    shopt -u nullglob
    echo "$count"
}

# True (rc=0) if smb.conf has a `[share_name]` section header. Uses
# awk's literal string compare ($0 == target) so share names with
# regex metacharacters — most importantly the trailing `$` that's
# common on Windows hidden shares like Engineering$ — match correctly.
# The previous `grep -qE "^\[$name\]"` form interpreted `$` as
# end-of-line and silently reported every $-bearing share as
# "smb_section: no" even when the section was present and serving
# traffic. Caught 2026-05-07 on the production proxy.
share_section_present() {
    local name="$1"
    # Second arg lets tests point at a fixture file; production calls
    # default to $SMB_CONF.
    local conf="${2:-$SMB_CONF}"
    [[ -n "$name" && -f "$conf" ]] || return 1
    awk -v target="[$name]" '
        $0 == target { found=1; exit }
        END { exit !found }
    ' "$conf"
}

read_smbconf_param() {
    awk -v key="$1" -F= '
        $1 ~ "^[[:space:]]*"key"[[:space:]]*$" {
            sub(/^[[:space:]]+/, "", $2); sub(/[[:space:]]+$/, "", $2)
            print $2; exit
        }
    ' "$SMB_CONF" 2>/dev/null
}

get_realm_status() {
    if is_joined; then
        local r; r=$(read_smbconf_param "realm")
        echo "${r:-(joined, realm unreadable)}"
    else
        echo "(not joined)"
    fi
}

get_smbd_status() {
    systemctl is-active smbd 2>/dev/null || echo "stopped"
}

get_winbind_status() {
    systemctl is-active winbind 2>/dev/null || echo "stopped"
}

#===============================================================================
# MAIN MENU
#===============================================================================
main_menu() {
    while true; do
        load_roles
        load_deploy
        local hostname fqdn realm_str smbd_str backend_str front_str
        hostname=$(get_hostname)
        fqdn=$(get_fqdn)
        realm_str=$(get_realm_status)
        smbd_str=$(get_smbd_status)
        local shares_str; shares_str=$(get_shares_status)

        local domain_nic_str="${DOMAIN_NIC_NAME:-NOT-ASSIGNED}"
        local legacy_nic_str="${LEGACY_NIC_NAME:-NOT-ASSIGNED}"

        local choice
        choice=$(whiptail --title "SMB1↔SMB3 Proxy [$hostname] v${VERSION}" \
            --menu "\n  Host: $fqdn\n  NICs: domain=$domain_nic_str  legacy=$legacy_nic_str\n  Realm: $realm_str  smbd: $smbd_str\n  Shares: $shares_str\n" \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "System Configuration" \
            "2" "NIC Roles" \
            "3" "Domain Operations (join / leave)" \
            "4" "Proxied Shares (add / edit / remove / mount)" \
            "5" "Firewall (nftables)" \
            "6" "Diagnostics & Sanity Check" \
            "7" "Service Management" \
            "8" "Reboot / Shutdown" \
            "Q" "Exit" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1) menu_system_config ;;
            2) menu_nic_roles ;;
            3) menu_domain_ops ;;
            4) menu_shares ;;
            5) menu_firewall ;;
            6) menu_diagnostics ;;
            7) menu_services ;;
            8) menu_power ;;
            Q|q) clear; exit 0 ;;
        esac
    done
}

#===============================================================================
# 1. SYSTEM CONFIGURATION
#===============================================================================
menu_system_config() {
    while true; do
        local choice
        choice=$(whiptail --title "System Configuration" \
            --menu "Hostname: $(get_fqdn)\nNetwork:  $(ip -br addr show | grep -v '^lo' | head -3 | tr '\n' ';' | sed 's/;$//')" \
            $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
            "1" "Set Hostname" \
            "2" "Set Timezone" \
            "3" "Run apt update + upgrade" \
            "4" "Show System Info" \
            "5" "Offline-share Data Disk" \
            "B" "Back to Main Menu" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) config_hostname ;;
            2) config_timezone ;;
            3) run_updates_now ;;
            4) show_system_info ;;
            5) menu_data_disk ;;
            B|b) return ;;
        esac
    done
}

menu_data_disk() {
    while true; do
        local status="not mounted"
        if data_mount_ready; then
            status=$(df -h "$DATA_ROOT" 2>/dev/null | awk 'NR==2 {print $2 " total, " $4 " free"}')
        fi
        local choice
        choice=$(whiptail --title "Offline-share Data Disk" \
            --menu "Mount: ${DATA_ROOT}\nStatus: ${status}\n\nQueued shares require this separate persistent disk." \
            "$WT_HEIGHT" "$WT_WIDTH" 5 \
            "1" "Initialize an attached disk (ERASES it)" \
            "2" "Grow ext4 after expanding the virtual disk" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) tui_initialize_data_disk ;;
            2)
                if ! data_mount_ready; then
                    info "No data filesystem is mounted at ${DATA_ROOT}."
                elif yesno "Grow the ext4 filesystem at ${DATA_ROOT} to fill its expanded virtual disk?"; then
                    if grow_data_disk >/tmp/smbproxy-grow.$$ 2>&1; then
                        info "Data filesystem grown successfully."
                    else
                        whiptail --title "Data disk grow failed" --textbox \
                            /tmp/smbproxy-grow.$$ 18 "$WT_WIDTH"
                    fi
                    rm -f /tmp/smbproxy-grow.$$
                fi
                ;;
            B|b) return ;;
        esac
    done
}

tui_initialize_data_disk() {
    if data_mount_ready; then
        info "A data filesystem is already mounted at ${DATA_ROOT}.\nIt must not be replaced while queued shares may contain data."
        return
    fi
    local candidates menu_args=() device description
    candidates=$(data_disk_candidates)
    [[ -n "$candidates" ]] || {
        info "No unmounted whole disks were found.\n\nAttach a secondary virtual disk in the hypervisor, then return here."
        return
    }
    while IFS=$'\t' read -r device description; do
        menu_args+=("$device" "$description")
    done <<< "$candidates"
    device=$(whiptail --title "Initialize offline-share data disk" \
        --menu "Pick the secondary disk to ERASE and dedicate to queued shares." \
        "$WT_HEIGHT" "$WT_WIDTH" "$WT_MENU_HEIGHT" \
        "${menu_args[@]}" 3>&1 1>&2 2>&3) || return

    local expected="ERASE ${device}" confirmation
    confirmation=$(whiptail --title "CONFIRM DATA LOSS" \
        --inputbox "ALL DATA on ${device} will be destroyed.\n\nType exactly:\n${expected}" \
        14 72 "" 3>&1 1>&2 2>&3) || return
    [[ "$confirmation" == "$expected" ]] || {
        info "Confirmation did not match. Nothing was changed."
        return
    }
    if initialize_data_disk "$device" >/tmp/smbproxy-data-init.$$ 2>&1; then
        info "Data disk initialized and mounted at ${DATA_ROOT}.\nQueued shares can now be configured."
    else
        whiptail --title "Data disk initialization failed" --textbox \
            /tmp/smbproxy-data-init.$$ 18 "$WT_WIDTH"
    fi
    rm -f /tmp/smbproxy-data-init.$$
}

config_hostname() {
    # Hostname changes after a domain join break Kerberos keytabs,
    # the machine account, and SPNs. Block them post-join and send
    # the operator to leave the domain first.
    if is_joined; then
        info "This proxy is already joined to a domain.\n\nChanging the hostname here would break Kerberos and the machine account. Leave the domain first via Domain Operations, set the new hostname, then re-join."
        return
    fi

    # The actual rename flow lives in the appliance-core hostname.sh
    # lib (LAN-scoped DHCP/PTR domain detection,
    # NetBIOS-rules short-name validation, safe /etc/hosts rewrite,
    # .local rejection). The is_joined guard above is the only
    # product-specific bit; everything else is shared with samba-addc
    # and any future appliance.
    if ! command -v appcore_hostname_change_tui >/dev/null 2>&1; then
        info "appliance-core libs not vendored on this image.\nRebuild via lab/build-fresh-base.sh, or copy ../appliance-core/lib/*.sh to /usr/local/lib/appliance-core/ by hand."
        return
    fi

    refresh_proxy_network_context
    if appcore_hostname_change_tui "" \
            "${APPCORE_DET_EFFECTIVE_DOMAIN:-}" "${DOMAIN_NIC_NAME:-}"; then
        info "Hostname set to: ${APPCORE_HOSTNAME_NEW_FQDN}\n\nReboot recommended after the join is complete."
    fi
}

config_timezone() {
    local cur suggested="" failure="" new prompt
    cur=$(timedatectl show --property=Timezone --value 2>/dev/null || echo Etc/UTC)
    cur="${cur:-Etc/UTC}"
    if command -v appcore_timezone_suggest >/dev/null 2>&1; then
        if appcore_timezone_suggest >/dev/null; then
            suggested="$APPCORE_TIMEZONE_SUGGESTION"
        else
            failure="$APPCORE_TIMEZONE_ERROR"
        fi
    else
        failure="Automatic suggestion unavailable on this image."
    fi
    prompt="Current timezone: ${cur}"
    if [[ -n "$suggested" ]]; then
        prompt+="\nDetected suggestion: ${suggested}"
    else
        prompt+="\n${failure}"
    fi
    prompt+="\n\nEnter Region/City. Examples:\n  America/Los_Angeles  Europe/London  Asia/Tokyo  Etc/UTC"
    new=$(whiptail --inputbox \
        "$prompt" 14 70 "${suggested:-$cur}" 3>&1 1>&2 2>&3) || return
    [[ -z "$new" ]] && return
    if timedatectl list-timezones 2>/dev/null | grep -qx "$new"; then
        timedatectl set-timezone "$new"
        info "Timezone is now: $(timedatectl show --property=Timezone --value)"
    else
        info "Unknown timezone: $new"
    fi
}

run_updates_now() {
    clear
    echo "[sconfig] apt full-upgrade..."
    echo "[sconfig]   note: full-upgrade can install new dependencies"
    echo "[sconfig]   (e.g. new kernel packages). Plain 'apt-get upgrade'"
    echo "[sconfig]   would silently keep them back."
    echo "[sconfig]   Samba stays at its current version; it is updated"
    echo "[sconfig]   separately, together with its session module."
    echo
    if [[ -x "$SAMBA_HOLD_HELPER" ]] && ! "$SAMBA_HOLD_HELPER" apply; then
        echo "[sconfig] Samba packages could not be held; update cancelled."
        echo "  Press Enter to continue."
        read -r _
        return
    fi
    if command -v appcore_apt_run_full_upgrade >/dev/null 2>&1; then
        DEBIAN_FRONTEND=noninteractive appcore_apt_run_full_upgrade
    else
        apt-get update && DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
    fi
    echo
    echo "=============================================================="
    local rb=""
    if command -v appcore_apt_reboot_banner_line >/dev/null 2>&1; then
        rb=$(appcore_apt_reboot_banner_line)
    elif [[ -f /var/run/reboot-required ]]; then
        rb="REBOOT REQUIRED"
    fi
    if [[ -n "$rb" ]]; then
        echo "  $rb"
        echo "  A kernel or library that's currently loaded was upgraded."
        echo "  Run 'sudo reboot' to apply."
    else
        echo "  Done. No reboot required."
    fi
    echo "=============================================================="
    echo "  Press Enter to continue."
    read -r _
}

show_system_info() {
    refresh_proxy_network_context
    {
        echo "=== Identity ==="
        echo "Host:    $(hostname -f)"
        echo "Realm:   $(get_realm_status)"
        echo
        echo "=== Domain/LAN environment ==="
        echo "Interface: ${APPCORE_DET_IFACE:-(not detected)}"
        echo "IPv4:     ${APPCORE_DET_IP:-(not detected)}"
        echo "Gateway:  ${APPCORE_DET_GATEWAY:-(not detected)}"
        echo "DNS:      ${APPCORE_DET_DHCP_DNS:-(not detected)}"
        echo "Domain:   ${APPCORE_DET_EFFECTIVE_DOMAIN:-(not detected)} (${APPCORE_DET_EFFECTIVE_DOMAIN_SOURCE:-no source})"
        echo "PTR:      ${APPCORE_DET_PTR_FQDN:-(not detected)}"
        echo
        echo "=== Network interfaces ==="
        ip -br addr show
        echo
        echo "=== NIC roles ==="
        cat "$ROLES_FILE" 2>/dev/null || echo "(not assigned)"
        echo
        echo "=== Default route ==="
        ip route show default
        echo
        echo "=== DNS ==="
        cat /etc/resolv.conf
        echo
        echo "=== chrony tracking ==="
        chronyc tracking 2>/dev/null || echo "(chrony not running)"
        echo
        echo "=== smbd / winbind / mounts ==="
        systemctl is-active smbd winbind 2>/dev/null || true
        mount | grep -E 'cifs|smb' || echo "(no cifs/smb mounts)"
    } > /tmp/smbproxy-info.$$
    whiptail --title "System Information" --scrolltext \
        --textbox /tmp/smbproxy-info.$$ "$WT_HEIGHT" "$WT_WIDTH"
    rm -f /tmp/smbproxy-info.$$
}

#===============================================================================
# 2. NIC ROLES
#===============================================================================
menu_nic_roles() {
    while true; do
        load_roles
        local choice
        choice=$(whiptail --title "NIC Roles" \
            --menu "Current assignment:\n  domain: ${DOMAIN_NIC_NAME:-(unset)}  mac=${DOMAIN_NIC_MAC:-?}\n  legacy: ${LEGACY_NIC_NAME:-(unset)}  mac=${LEGACY_NIC_MAC:-?}" \
            $WT_HEIGHT $WT_WIDTH 6 \
            "1" "Show interface table" \
            "2" "Re-assign roles by MAC" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) show_iface_table ;;
            2) reassign_roles ;;
            B|b) return ;;
        esac
    done
}

show_iface_table() {
    local f=/tmp/smbproxy-iface.$$
    {
        printf '%-12s %-19s %-7s %s\n' "NAME" "MAC" "STATE" "IPv4"
        local _net_path
    for _net_path in /sys/class/net/*; do
        local n="${_net_path##*/}"
        [[ "$n" == "lo" ]] && continue
            local typ
            typ=$(cat "/sys/class/net/$n/type" 2>/dev/null || echo 0)
            [[ "$typ" == "1" ]] || continue
            local mac st ip
            mac=$(cat "/sys/class/net/$n/address" 2>/dev/null)
            st=$(cat "/sys/class/net/$n/operstate" 2>/dev/null)
            ip=$(ip -o -4 addr show dev "$n" scope global 2>/dev/null | awk 'NR==1 {print $4}')
            printf '%-12s %-19s %-7s %s\n' "$n" "$mac" "$st" "${ip:-<none>}"
        done
    } > "$f"
    whiptail --title "Network Interfaces" --scrolltext --textbox "$f" "$WT_HEIGHT" "$WT_WIDTH"
    rm -f "$f"
}

reassign_roles() {
    # Build a menu of NIC choices.
    local menu_args=()
    local _net_path
    for _net_path in /sys/class/net/*; do
        local n="${_net_path##*/}"
        [[ "$n" == "lo" ]] && continue
        local typ
        typ=$(cat "/sys/class/net/$n/type" 2>/dev/null || echo 0)
        [[ "$typ" == "1" ]] || continue
        local mac st ip dhcp
        mac=$(cat "/sys/class/net/$n/address" 2>/dev/null)
        st=$(cat "/sys/class/net/$n/operstate" 2>/dev/null)
        ip=$(ip -o -4 addr show dev "$n" scope global 2>/dev/null | awk 'NR==1 {print $4}')
        dhcp="static"
        ip -4 addr show dev "$n" 2>/dev/null | grep -q dynamic && dhcp="dhcp"
        menu_args+=("$n" "$mac link=$st ${ip:-no-ip} ($dhcp)")
    done
    if [[ ${#menu_args[@]} -lt 4 ]]; then
        info "Need at least 2 ethernet interfaces."; return
    fi

    local pick_dom pick_leg
    # Body text repeats the role being assigned so the operator never has
    # to look at the title bar to know which NIC they're picking. (Per
    # dev-commons/STYLE.md §7 / §3 — title-only context is too subtle.)
    pick_dom=$(whiptail --title "Assign role: Domain NIC" --notags \
        --menu "Assigning the DOMAIN NIC (AD-LAN side).\n\nPick the interface that is on the same network as the Windows DC." \
        $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
        "${menu_args[@]}" 3>&1 1>&2 2>&3) || return
    pick_leg=$(whiptail --title "Assign role: Legacy NIC" --notags \
        --menu "Assigning the LEGACY NIC (LegacyZone, gateway-less).\n\nPick the interface that connects to the legacy SMB1 backend." \
        $WT_HEIGHT $WT_WIDTH $WT_MENU_HEIGHT \
        "${menu_args[@]}" 3>&1 1>&2 2>&3) || return
    if [[ "$pick_dom" == "$pick_leg" ]]; then
        info "Domain and Legacy must be different interfaces."; return
    fi
    local dom_mac leg_mac
    dom_mac=$(cat "/sys/class/net/$pick_dom/address" 2>/dev/null)
    leg_mac=$(cat "/sys/class/net/$pick_leg/address" 2>/dev/null)
    install -d -o root -g root -m 0755 /etc/smbproxy
    cat > "$ROLES_FILE" <<EOF
DOMAIN_NIC_NAME="$pick_dom"
DOMAIN_NIC_MAC="$dom_mac"
LEGACY_NIC_NAME="$pick_leg"
LEGACY_NIC_MAC="$leg_mac"
EOF
    chmod 0644 "$ROLES_FILE"
    info "Roles updated:\n  domain: $pick_dom (mac=$dom_mac)\n  legacy: $pick_leg (mac=$leg_mac)\n\nThe firewall menu will install new nftables rules for these interface names."
}

#===============================================================================
# 3. DOMAIN OPERATIONS
#===============================================================================
menu_domain_ops() {
    while true; do
        local choice
        choice=$(whiptail --title "Domain Operations" \
            --menu "Realm: $(get_realm_status)" \
            $WT_HEIGHT $WT_WIDTH 6 \
            "1" "Probe a DC (DNS + LDAP rootDSE)" \
            "2" "Join existing forest as a member server" \
            "3" "Leave the domain" \
            "4" "Show join state (net ads info / wbinfo -t)" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) probe_dc_tui ;;
            2) join_domain_tui ;;
            3) leave_domain_tui ;;
            4) show_join_state ;;
            B|b) return ;;
        esac
    done
}

probe_dc_tui() {
    load_deploy
    refresh_proxy_domain_defaults
    local realm dc
    realm=$(whiptail --inputbox "AD realm (e.g. example.com):" 10 64 \
        "${REALM:-$PROXY_DEFAULT_REALM}" 3>&1 1>&2 2>&3) || return
    dc=$(whiptail --inputbox "DC hostname or IP (e.g. dc1.example.com or 10.0.0.10):" 10 70 \
        "${DC_HOST:-$PROXY_DEFAULT_DC}" 3>&1 1>&2 2>&3) || return
    [[ -z "$realm" || -z "$dc" ]] && return
    local ip
    if ! ip=$(resolve_dc_ip "$dc"); then
        info "Could not resolve $dc — check DNS or supply an IP."; return
    fi
    local out=/tmp/smbproxy-probe.$$
    {
        echo "=== Probe of $dc ($ip) ==="
        echo
        echo "--- ICMP ---"
        ping -c 2 -W 2 "$ip" || echo "ping failed"
        echo
        echo "--- TCP/445 ---"
        timeout 3 bash -c "</dev/tcp/$ip/445" 2>&1 && echo "open" || echo "445 not reachable"
        echo
        echo "--- TCP/389 (LDAP) ---"
        timeout 3 bash -c "</dev/tcp/$ip/389" 2>&1 && echo "open" || echo "389 not reachable"
        echo
        echo "--- LDAP rootDSE (anonymous) ---"
        ldapsearch -x -LLL -H "ldap://$ip" -s base -b "" defaultNamingContext forestFunctionality 2>&1 | head -20
        echo
        echo "--- SRV _kerberos._tcp.${realm} ---"
        dig +short -t SRV "_kerberos._tcp.${realm}" 2>&1
        echo
        echo "--- chronyc sources (current view) ---"
        chronyc sources 2>/dev/null | head -10 || echo "(chrony not active)"
    } > "$out"
    whiptail --title "DC probe" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
    rm -f "$out"
}

# Headless-friendly form of the join. Uses the global REALM, DOMAIN_SHORT,
# DC_HOST, AD_USER, AD_PASS that callers must populate.
do_domain_join() {
    local logf=/var/log/smbproxy-join.log
    : > "$logf"
    chmod 0600 "$logf"
    log_join() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" >> "$logf"; }

    [[ -n "$REALM" && -n "$DOMAIN_SHORT" && -n "$DC_HOST" && -n "$AD_USER" && -n "${AD_PASS:-}" ]] \
        || { log_join "missing parameters"; return 2; }

    log_join "starting join: realm=$REALM short=$DOMAIN_SHORT dc=$DC_HOST user=$AD_USER"

    if ! DC_IP=$(resolve_dc_ip "$DC_HOST"); then
        log_join "ERROR: cannot resolve DC host $DC_HOST"
        return 3
    fi
    log_join "  DC IP resolved to $DC_IP"

    # 1. Stop services that would interfere with the join sequence.
    systemctl stop smbd winbind 2>/dev/null || true

    # 2. krb5.conf — minimal, dns_lookup_kdc=true so the join can find
    #    other DCs through SRV records.
    local realm_uc="${REALM^^}"
    cat > "$KRB5_CONF" <<EOF
[libdefaults]
    default_realm = ${realm_uc}
    dns_lookup_realm = false
    dns_lookup_kdc = true
    ticket_lifetime = 24h
    renew_lifetime = 7d
    forwardable = true

[realms]
    ${realm_uc} = {
        kdc = ${DC_HOST}
        admin_server = ${DC_HOST}
    }

[domain_realm]
    .${REALM,,} = ${realm_uc}
    ${REALM,,} = ${realm_uc}
EOF

    # 3. Take exclusive ownership of /etc/resolv.conf and point at the DC.
    take_over_resolv_conf
    {
        echo "search ${REALM,,}"
        echo "nameserver ${DC_IP}"
    } > /etc/resolv.conf
    chmod 0644 /etc/resolv.conf

    # 4. chrony — Kerberos is intolerant of clock skew (>5 min by default).
    #
    # Source priority, written in this order:
    #   1. AD PDC emulator. Microsoft convention is that the PDC holds
    #      the authoritative time for the forest. We discover it via
    #      DNS (_ldap._tcp.pdc._msdcs.<realm>) rather than assuming
    #      it's the same as the joined DC, because in many AD
    #      deployments the PDC role is held by a different DC than
    #      the one a member server happens to be talking to.
    #   2. The DC the proxy joined. Often the same as the PDC (in
    #      single-DC labs) but not always.
    #   3. Public NTP pool fallback. Critical because in practice
    #      neither the PDC nor the joined DC always has W32Time
    #      configured to *serve* NTP — the appliance discovered this
    #      the hard way during 2026-05-05 testing, where neither AD
    #      time source responded to NTP UDP/123 and the clock drifted
    #      ~83 minutes before Kerberos broke. Falling back to a
    #      public source is dramatically better than letting Kerberos
    #      die mysteriously.
    #
    # Plus `makestep 1.0 3` so chrony will step (not just slew) the
    # initial offset on a freshly-deployed VM with a wrong clock —
    # without this directive chrony refuses corrections > 1s, the
    # behavior the original join code triggered in production.
    local pdc_host pdc_ip
    pdc_host=$(host -t SRV "_ldap._tcp.pdc._msdcs.${REALM,,}" 2>/dev/null \
                | awk '/SRV record/ {gsub(/\.$/, "", $NF); print $NF; exit}')
    if [[ -n "$pdc_host" ]]; then
        pdc_ip=$(host -t A "$pdc_host" 2>/dev/null | awk '/has address/ {print $NF; exit}')
    fi
    log_join "chrony source policy: PDC=${pdc_host:-(not found via DNS)} ip=${pdc_ip:-?}; joined DC=${DC_IP}; pool=2.debian.pool.ntp.org"
    {
        echo "# Managed by smbproxy-sconfig. Source priority: PDC -> joined DC -> public pool."
        echo "# Adjust /etc/chrony/sources.d/*.sources to add per-deployment sources."
        if [[ -n "$pdc_ip" ]]; then
            echo "# Primary: AD PDC emulator (${pdc_host} resolved via _ldap._tcp.pdc._msdcs SRV)"
            echo "server ${pdc_ip} iburst prefer"
        else
            echo "# (PDC SRV record not resolvable at join time; relying on joined DC + pool)"
        fi
        echo "# Secondary: the DC the proxy joined"
        echo "server ${DC_IP} iburst"
        echo "# Tertiary: public NTP pool — used when the AD time sources do not serve NTP"
        echo "pool 2.debian.pool.ntp.org iburst"
        echo
        echo "driftfile /var/lib/chrony/drift"
        echo
        echo "# Step (not just slew) the clock on first sync. Without this"
        echo "# chrony refuses corrections > 1s, breaking fresh deploys with"
        echo "# a wrong-time VM."
        echo "makestep 1.0 3"
        echo
        echo "# Keep RTC in sync so reboots come up close to correct."
        echo "rtcsync"
    } > /etc/chrony/chrony.conf
    systemctl restart chrony 2>/dev/null || systemctl restart chronyd 2>/dev/null || true
    chronyc -a 'burst 4/4' >/dev/null 2>&1 || true
    chronyc -a makestep   >/dev/null 2>&1 || true
    sleep 4

    # Post-sync verification — warn (don't fail the join) if no source
    # became selectable within the burst window. Operator gets a clear
    # log line they can grep for; symptom is otherwise mystery-Kerberos.
    local ref_id
    ref_id=$(chronyc tracking 2>/dev/null | awk '/^Reference ID/ {print $4; exit}')
    if [[ -z "$ref_id" || "$ref_id" == "(00000000)" || "$ref_id" == "()" ]]; then
        log_join "WARN: chrony has not selected a source — clock will drift; Kerberos auth will fail at >5min skew"
        log_join "WARN: check /var/log/syslog for chronyd; also check UDP/123 reachability to PDC ${pdc_ip:-?} and DC ${DC_IP}"
    else
        log_join "chrony reference: ${ref_id}"
    fi

    # 5. smb.conf — write a minimal [global] only. Per-share sections
    #    are added later by configure_share() (one per proxied share).
    #    The locking-strict stanza is applied when each share is added.
    cat > "$SMB_CONF" <<EOF
[global]
    workgroup = ${DOMAIN_SHORT}
    realm = ${realm_uc}
    security = ads
    netbios name = $(hostname -s | tr '[:lower:]' '[:upper:]' | cut -c1-15)

    # The legacy NIC is a private backend link. Restrict SMB service and AD
    # DNS registration to the domain-facing interface.
    interfaces = lo ${DOMAIN_NIC_NAME}
    bind interfaces only = yes

    # Winbind identity (RID for single-domain forests).
    winbind use default domain = yes
    winbind enum users = yes
    winbind enum groups = yes
    winbind refresh tickets = yes
    idmap config * : backend = tdb
    idmap config * : range = 3000-7999
    idmap config ${DOMAIN_SHORT} : backend = rid
    idmap config ${DOMAIN_SHORT} : range = 10000-999999
    template shell = /bin/bash

    # SMB3 only on the wire facing AD-joined clients.
    server min protocol = SMB3
    client min protocol = SMB3
    # A legacy backend is single-channel and the session VFS serializes reads.
    # Reject extra channels from client VPN/VM adapters that can stall I/O.
    server multi channel support = no
    server signing = mandatory
    client signing = mandatory
    server smb encrypt = desired
    client smb encrypt = desired
    ntlm auth = ntlmv2-only
    restrict anonymous = 2
    kerberos method = secrets and keytab

    # NetBIOS off — the WS2025 forest does not use it.
    disable netbios = yes
    smb ports = 445
EOF

    if ! testparm -s "$SMB_CONF" >/dev/null 2>>"$logf"; then
        log_join "ERROR: testparm rejected the smb.conf"
        return 4
    fi

    # 6. kinit, then net ads join -k. Pipe the password through kinit.
    if ! echo "$AD_PASS" | kinit "${AD_USER}@${realm_uc}" 2>>"$logf"; then
        log_join "ERROR: kinit failed for ${AD_USER}@${realm_uc}"
        return 5
    fi
    if ! net ads join -k 2>>"$logf"; then
        log_join "ERROR: 'net ads join -k' failed (see $logf)"
        return 6
    fi

    if command -v appcore_hostname_align_to_realm >/dev/null 2>&1; then
        appcore_hostname_align_to_realm "${REALM,,}" 2>>"$logf" || \
            log_join "WARN: failed to align hostname and /etc/hosts to ${REALM,,}"
    fi

    # 6b. Register cifs/ SPNs in AD and re-sync into the local keytab.
    #
    # `net ads join` registers HOST/<short>, HOST/<fqdn>,
    # RestrictedKrbHost/<short>, and RestrictedKrbHost/<fqdn> only. It
    # does NOT register cifs/<short> or cifs/<fqdn>. Older Windows
    # forests fell back to HOST/ for SMB Kerberos service tickets;
    # WS2025-hardened forests prefer cifs/ specifically and refuse
    # the fallback. Without these SPNs the appliance kerb-auths fine
    # but every Windows client gets a "logon failure" with
    # "Failed to find cifs/<host>@<REALM>(kvno N) in keytab" in
    # /var/log/samba/log.smbd. This was real, hit during 2026-05-05
    # testing.
    local short_host fqdn
    short_host=$(hostname -s | tr '[:upper:]' '[:lower:]')
    fqdn=$(hostname -f | tr '[:upper:]' '[:lower:]')
    local short_upper
    short_upper=$(hostname -s | tr '[:lower:]' '[:upper:]')
    log_join "registering cifs/ SPNs in AD"
    if ! net ads setspn add "$short_upper" "cifs/${short_host}" -k 2>>"$logf"; then
        log_join "WARN: failed to register cifs/${short_host} SPN — Windows clients may hit logon failures"
    fi
    if ! net ads setspn add "$short_upper" "cifs/${fqdn}" -k 2>>"$logf"; then
        log_join "WARN: failed to register cifs/${fqdn} SPN — Windows clients may hit logon failures"
    fi
    log_join "re-syncing keytab from AD (picks up new cifs/ entries)"
    net ads keytab create -k >>"$logf" 2>&1 || \
        log_join "WARN: 'net ads keytab create' failed — keytab may be missing cifs/ keys"

    # 7. NSS wiring (winbind-aware passwd/group).
    sed -i 's/^passwd:.*$/passwd:         files systemd winbind/' /etc/nsswitch.conf
    sed -i 's/^group:.*$/group:          files systemd winbind/'  /etc/nsswitch.conf

    systemctl enable --now winbind 2>>"$logf"
    systemctl unmask smbd 2>/dev/null || true
    systemctl enable --now smbd    2>>"$logf"
    systemctl disable --now nmbd 2>/dev/null || true

    # 8. Sanity ping.
    if ! wbinfo -t >>"$logf" 2>&1; then
        log_join "WARN: wbinfo -t reports trust is not yet healthy"
    fi

    DC_IP="$DC_IP"
    save_deploy
    log_join "join complete"
    return 0
}

join_domain_tui() {
    load_deploy
    refresh_proxy_domain_defaults
    if is_joined; then
        if ! whiptail --yesno "This host appears to be joined already.\n\nRe-running the join will overwrite smb.conf, krb5.conf, chrony.conf, and resolv.conf. Continue?" 12 64; then
            return
        fi
    fi
    REALM=$(whiptail --inputbox "AD realm (e.g. example.com):" 10 64 \
        "${REALM:-$PROXY_DEFAULT_REALM}" 3>&1 1>&2 2>&3) || return
    DOMAIN_SHORT=$(whiptail --inputbox "NetBIOS short domain name (pre-Win2000):" 10 64 \
        "${DOMAIN_SHORT:-${PROXY_DEFAULT_DOMAIN_SHORT:-${REALM%%.*}}}" 3>&1 1>&2 2>&3) || return
    DOMAIN_SHORT="${DOMAIN_SHORT^^}"
    DC_HOST=$(whiptail --inputbox "DC hostname or IP:" 10 64 \
        "${DC_HOST:-$PROXY_DEFAULT_DC}" 3>&1 1>&2 2>&3) || return
    AD_USER=$(whiptail --inputbox "Domain admin username (e.g. Administrator):" 10 64 "Administrator" 3>&1 1>&2 2>&3) || return
    AD_PASS=$(whiptail --passwordbox "Password for ${AD_USER}@${REALM^^}:" 10 64 3>&1 1>&2 2>&3) || return
    [[ -z "$AD_PASS" ]] && { info "Password required."; return; }

    yesno "Joining ${REALM^^} via DC ${DC_HOST} as ${AD_USER}.\n\nThis will rewrite smb.conf, krb5.conf, chrony.conf, and /etc/resolv.conf. Proceed?" || return

    clear
    echo "=== Joining ${REALM^^} ==="
    echo "Log: /var/log/smbproxy-join.log"
    if do_domain_join; then
        AD_PASS=""; unset AD_PASS
        info "Join succeeded.\n\nNext: Backend SMB1 Mount, then Frontend SMB3 Share."
    else
        AD_PASS=""; unset AD_PASS
        info "Join FAILED — see /var/log/smbproxy-join.log"
    fi
}

# run_with_auth_file USER SECRET COMMAND ARGS...
#   Runs COMMAND ARGS... -A <file> so the password never reaches a process
#   argument vector (/proc/<pid>/cmdline is world-readable; code-review
#   session plan 01). The file lives in a root-only directory and is removed
#   when the command returns. Samba trims whitespace around authentication
#   file values, so secrets with leading/trailing blanks are refused.
run_with_auth_file() {
    local user="$1" secret="$2"
    shift 2
    if [[ "$secret" =~ ^[[:space:]]|[[:space:]]$ ]]; then
        echo "passwords with leading or trailing spaces are not supported here" >&2
        return 2
    fi
    local dir rc=0
    dir=$(mktemp -d "${SCONFIG_AUTH_DIR:-/run}/smbproxy-auth.XXXXXX") || return 1
    chmod 0700 "$dir"
    # Redirect inside the subshell so the file is created under umask 077.
    ( umask 077; printf 'username = %s\npassword = %s\n' "$user" "$secret" > "$dir/auth" )
    "$@" -A "$dir/auth" || rc=$?
    rm -rf "$dir"
    return "$rc"
}

leave_domain_tui() {
    if ! is_joined; then
        info "Not joined."; return
    fi
    load_deploy
    yesno "Leave the AD domain?\n\nThis stops smbd, removes the machine account from AD (if reachable), wipes /etc/samba/smb.conf, and disables winbind." || return
    local user
    user=$(whiptail --inputbox "AD user with permission to delete the machine account:" 10 64 "Administrator" 3>&1 1>&2 2>&3) || return
    local pass
    pass=$(whiptail --passwordbox "Password:" 10 64 3>&1 1>&2 2>&3) || return
    clear
    systemctl stop smbd winbind 2>/dev/null || true
    if ! run_with_auth_file "$user" "$pass" net ads leave 2>&1 | tee /tmp/smbproxy-leave.log; then
        info "leave failed (machine may still be in AD).\nSee /tmp/smbproxy-leave.log"
    fi
    rm -f "$SMB_CONF"
    systemctl disable winbind 2>/dev/null || true
    info "Local state cleaned. krb5.conf left in place; remove manually if you want."
}

show_join_state() {
    local out=/tmp/smbproxy-state.$$
    {
        echo "=== net ads info ==="
        net ads info 2>&1 || echo "(net ads info failed)"
        echo
        echo "=== wbinfo -t ==="
        wbinfo -t 2>&1 || echo "(wbinfo -t failed)"
        echo
        echo "=== klist (root) ==="
        klist 2>&1 || echo "(no ticket)"
        echo
        echo "=== smb.conf [global] ==="
        sed -n '/^\[global\]/,/^\[/p' "$SMB_CONF" 2>/dev/null | head -40 || echo "(no smb.conf)"
    } > "$out"
    whiptail --title "Domain state" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
    rm -f "$out"
}

#===============================================================================
# 5. SMB.CONF UTILITIES (used by §5M Proxied Shares)
#===============================================================================
show_smbconf() {
    if [[ -f "$SMB_CONF" ]]; then
        whiptail --title "Live smb.conf — $SMB_CONF" --scrolltext --textbox "$SMB_CONF" "$WT_HEIGHT" "$WT_WIDTH"
    else
        info "No smb.conf yet — add a share via Proxied Shares first."
    fi
}

run_testparm() {
    local out=/tmp/smbproxy-tp.$$
    testparm -s 2>&1 | head -200 > "$out"
    whiptail --title "testparm -s" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
    rm -f "$out"
}

#===============================================================================
# 5M. PROXIED SHARES (MULTI-SHARE)
#
# Replaces the singleton "Backend SMB1 Mount" + "Frontend SMB3 Share"
# menus. The operator manages an arbitrary number of proxied shares
# from one place — each share has its own backend creds, mount, fstab
# line, smb.conf section, AD access group, and local force-user (per
# the multi-share data model in load_share / save_share above).
#===============================================================================

# Status summary string for the main menu header. Format adapts to the
# count: zero shares → "(none)"; small N → comma-separated names; many
# → first three + count.
get_shares_status() {
    local names; names=$(list_shares 2>/dev/null)
    if [[ -z "$names" ]]; then
        echo "(none configured)"
        return
    fi
    local count first
    count=$(echo "$names" | wc -l | tr -d ' ')
    if [[ "$count" -le 3 ]]; then
        echo "$count: $(echo "$names" | paste -sd ', ' -)"
    else
        first=$(echo "$names" | head -3 | paste -sd ', ' -)
        echo "$count: $first, ..."
    fi
}

# pick_share emits the chosen SHARE_NAME on stdout and returns 0; rc=1
# when the operator cancels or no shares exist. Caller decides whether
# absence is an error or a normal "do nothing" case.
pick_share() {
    local prompt="${1:-Pick a share:}"
    local names menu_args=()
    names=$(list_shares 2>/dev/null) || return 1
    [[ -n "$names" ]] || return 1
    while IFS= read -r n; do
        # Whiptail menu wants tag/item pairs. Tag = SHARE_NAME, item =
        # a brief status string so the operator can tell shares apart
        # when they have many.
        load_share "$n" 2>/dev/null
        local mp_status="unmounted"
        if [[ "${PROFILE:-$PROFILE_LEGACY}" == "$PROFILE_LEGACY" ]]; then
            mp_status="sessions=$(legacy_session_count "$n")"
        elif [[ -n "$BACKEND_MOUNT" ]] && backend_mount_active "$BACKEND_MOUNT" 2>/dev/null; then
            mp_status="mounted"
        fi
        menu_args+=("$n" "${BACKEND_IP:-?}/${n}  ${mp_status}")
    done <<< "$names"
    whiptail --title "Pick a proxied share" --notags \
        --menu "$prompt" \
        "$WT_HEIGHT" "$WT_WIDTH" "$WT_MENU_HEIGHT" \
        "${menu_args[@]}" 3>&1 1>&2 2>&3
}

# shares_list_status renders a textbox showing every share's current
# state: backend IP/share, mount path, mount status, smb.conf section
# present?, AD group, force-user. Read-only.
shares_list_status() {
    local out=/tmp/smbproxy-shares.$$
    {
        local names
        names=$(list_shares 2>/dev/null)
        if [[ -z "$names" ]]; then
            echo "No proxied shares configured."
            echo
            echo "Add one from the Proxied Shares menu."
        else
            echo "Configured proxied shares:"
            echo
            local n
            while IFS= read -r n; do
                load_share "$n" 2>/dev/null
                printf '== %s ==\n' "$n"
                printf '  offline mode:   %s\n' "${OFFLINE_MODE:-$OFFLINE_DIRECT}"
                printf '  backend:        //%s/%s\n' "${BACKEND_IP:-?}" "$n"
                printf '  backend user:   %s (domain: %s)\n' \
                    "${BACKEND_USER:-?}" "${BACKEND_DOMAIN:-?}"
                printf '  mount point:    %s' "${BACKEND_MOUNT:-?}"
                if [[ "${PROFILE:-$PROFILE_LEGACY}" == "$PROFILE_LEGACY" ]]; then
                    printf '  [dynamic sessions=%s]\n' "$(legacy_session_count "$n")"
                elif backend_mount_active "${BACKEND_MOUNT:-/dev/null}" 2>/dev/null; then
                    printf '  [mounted]\n'
                else
                    printf '  [unmounted]\n'
                fi
                printf '  frontend path:  %s\n' \
                    "$(share_frontend_path "$n" "${OFFLINE_MODE:-$OFFLINE_DIRECT}" "${BACKEND_MOUNT:-}" "$DATA_ROOT" "${PROFILE:-$PROFILE_LEGACY}")"
                if [[ "${OFFLINE_MODE:-$OFFLINE_DIRECT}" == "$OFFLINE_QUEUED" ]]; then
                    if data_mount_ready; then
                        printf '  data disk:      mounted\n'
                    else
                        printf '  data disk:      MISSING — queued share unavailable\n'
                    fi
                fi
                printf '  AD access:      %s\n' "${FRONT_GROUP:-?}"
                printf '  force user:     %s\n' "${FRONT_FORCE_USER:-?}"
                if share_section_present "$n"; then
                    printf '  smb.conf:       [%s] section present\n' "$n"
                else
                    printf '  smb.conf:       [%s] section MISSING\n' "$n"
                fi
                echo
            done <<< "$names"
        fi
    } > "$out"
    whiptail --title "Proxied shares: status" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
    rm -f "$out"
}

# configure_share is the unified per-share writer. Operates on the
# per-share globals (SHARE_NAME, BACKEND_IP, BACKEND_USER,
# BACKEND_DOMAIN, BACKEND_MOUNT, BACKEND_PASS, FRONT_GROUP,
# FRONT_FORCE_USER) and writes:
#   - per-share creds file (mode 0600 root:root)
#   - modern/direct: per-share fstab line (replacing any prior mount point)
#   - legacy/direct: no fstab line; the VFS owns transient session mounts
#   - per-share smb.conf section (replacing any prior [SHARE_NAME])
#   - per-share env file via save_share()
# Frontend pieces are skipped if not domain-joined (the operator can
# add the share's backend pre-join and publish the frontend later).
# BACKEND_PASS is consumed and then unset — never persisted to disk.
# Return codes:
#   0  success
#   2  missing required field, or invalid --locking value
#   4  testparm rejected the rendered smb.conf (see /tmp/smbproxy-tp.*)
#   5  could not resolve LOCAL UID/GID for FRONT_FORCE_USER from
#      /etc/passwd (no local account)
#   6  could not resolve FRONT_GROUP to a SID via wbinfo (group missing,
#      winbind unreachable, or NSS-only group with no AD presence)
#   7  legacy-profile share but no LEGACY_NIC_NAME role assigned
#   8  unknown PROFILE value (expected: $PROFILE_LEGACY|$PROFILE_MODERN)
#   9  AD-name-collision REFUSAL — the chosen FRONT_FORCE_USER also
#      exists in AD; the share is not configured. See AGENTS.md
#      "force-user contract" and lab/scenarios/collision-refused.sh.
#  10  invalid offline behavior, including queued mode on legacy
#  11  queued mode requested without the secondary data filesystem
#  12  legacy session VFS/helper is missing or built for another Samba version
#
# Pre-flight semantics (commit 2368853): all validations that can fail
# (UID/GID lookup, AD group SID resolve, smb.conf candidate +
# testparm) run BEFORE any persistent writes (creds, fstab, smb.conf,
# share-state). A non-zero return therefore leaves the filesystem
# unchanged from the call's pre-state.
configure_share() {
    [[ -n "$SHARE_NAME" && -n "$BACKEND_IP" && -n "$BACKEND_USER" \
        && -n "${BACKEND_PASS:-}" && -n "$BACKEND_DOMAIN" \
        && -n "$BACKEND_MOUNT" && -n "$FRONT_FORCE_USER" ]] \
        || return 2

    # Profile guard. Default to legacy for backward compat; a missing
    # profile field on a pre-existing share's env file already loaded
    # as legacy via load_share().
    PROFILE="${PROFILE:-$PROFILE_LEGACY}"
    case "$PROFILE" in
        "$PROFILE_LEGACY"|"$PROFILE_MODERN") : ;;
        *) log_share "ERROR: unknown profile '${PROFILE}' (expected: $PROFILE_LEGACY|$PROFILE_MODERN)"; return 8 ;;
    esac
    OFFLINE_MODE="${OFFLINE_MODE:-$OFFLINE_DIRECT}"
    if ! offline_mode_validate "$PROFILE" "$OFFLINE_MODE"; then
        log_share "ERROR: offline mode '${OFFLINE_MODE}' is invalid for profile '${PROFILE}'."
        log_share "ERROR: queued mode is supported only for modern file-copy shares."
        return 10
    fi
    if [[ "$OFFLINE_MODE" == "$OFFLINE_QUEUED" ]] && ! data_mount_ready; then
        log_share "ERROR: queued mode requires a mounted secondary data filesystem at ${DATA_ROOT}."
        log_share "ERROR: initialize it from System Configuration before configuring the share."
        return 11
    fi

    # Legacy profile assumes a dedicated backend NIC (the air-gapped
    # LegacyZone subnet). Refuse to configure a legacy share if that
    # NIC role isn't assigned yet — the cifs mount would silently
    # route through the domain NIC and the isolation guarantee is
    # gone. Modern profile has no such requirement; the backend is
    # reached via normal domain-LAN routing.
    if [[ "$PROFILE" == "$PROFILE_LEGACY" ]]; then
        load_roles
        if [[ -z "$LEGACY_NIC_NAME" ]]; then
            log_share "ERROR: legacy-profile share requires a legacy NIC role assignment."
            log_share "ERROR: run 'smbproxy-sconfig' and assign the legacy NIC, or use --profile modern."
            return 7
        fi
        local module_root module_path fileid_module expected_version actual_version
        module_root=$(smbd -b 2>/dev/null | awk -F': ' '/MODULESDIR/ {gsub(/^[[:space:]]+/, "", $2); print $2; exit}')
        module_path="${module_root}/vfs/smbproxy_session.so"
        fileid_module="${module_root}/vfs/fileid.so"
        if [[ -r /usr/share/smbproxy-session-vfs/samba-package-version ]]; then
            expected_version=$(cat /usr/share/smbproxy-session-vfs/samba-package-version)
        else
            # Compatibility with the frozen pre-component updater.
            expected_version=$(cat /usr/lib/smbproxy/samba-version 2>/dev/null || true)
        fi
        actual_version=$(dpkg-query -W -f='${Version}' samba 2>/dev/null || true)
        if [[ ! -x "$SESSION_HELPER" || ! -x "$VFS_VERSION_HELPER" \
            || ! -r "$module_path" || ! -r "$fileid_module" \
            || -z "$expected_version" || "$expected_version" != "$actual_version" ]]; then
            log_share "ERROR: legacy session VFS is unavailable or does not match installed Samba."
            log_share "ERROR: expected='${expected_version:-missing}' actual='${actual_version:-missing}' modules='${module_path} ${fileid_module}'."
            log_share "ERROR: rebuild the appliance image/module; refusing a non-isolated SMB1 path."
            return 12
        fi
    fi

    # Resolve the effective locking kind (profile default unless
    # overridden via --locking). A bad override value comes back rc=2.
    local locking_kind
    locking_kind=$(resolve_locking_kind "$PROFILE" "${LOCKING_OVERRIDE:-}") \
        || { log_share "ERROR: invalid --locking value '${LOCKING_OVERRIDE}'"; return 2; }

    # Local backend force-user must exist as a *local* /etc/passwd
    # entry before we set the cifs uid/gid mount options against it.
    #
    # IMPORTANT: check /etc/passwd directly, not via `id` or `getent`.
    # With `winbind use default domain = yes` (which we set in
    # do_domain_join), winbind publishes every AD account to NSS under
    # its bare lowercased name. If the operator picks a force-user
    # name that happens to also exist in AD, `id NAME` returns the AD
    # account's UID and useradd is silently skipped — leaving the
    # share's force-user pointing at the AD account instead of a local
    # account. The cifs mount then ends up with an AD UID, smb.conf's
    # `force user` resolves to the AD account, and Samba's tree-connect
    # path corrupts under the resulting double-mapping. Hit this in
    # production 2026-05-05 — the operator chose a local force-user
    # name that happened to match an existing AD account, and the
    # silent capture went undetected until tree-connect failures.
    # Refuse — not just warn — if the chosen force-user name also
    # exists as an AD account. With `winbind use default domain =
    # yes`, every AD account is published via NSS under its bare
    # lowercased name, and Samba's `getpwnam`-based force-user
    # resolution has been observed in production to bind to the AD
    # account even when /etc/passwd carries a local entry of the
    # same name (incident 2026-05-05). The numeric-UID workaround
    # was itself broken — `force user = 1003` fails `getpwnam` at
    # tree-connect with NT_STATUS_NO_SUCH_USER (confirmed
    # 2026-05-07). The only robust defense is to keep collisions
    # out of the configuration in the first place.
    #
    # Use `wbinfo --name-to-sid` rather than `id` / `getent`. Those
    # go through NSS and a local entry shadows the winbind one,
    # masking the collision. wbinfo queries winbind directly and
    # reports AD presence regardless of /etc/passwd state.
    if wbinfo --name-to-sid "$FRONT_FORCE_USER" >/dev/null 2>&1; then
        log_share "ERROR: force-user '${FRONT_FORCE_USER}' collides with an AD account of the same name."
        log_share "ERROR: Samba's force-user resolution can bind to the AD account instead of the local"
        log_share "ERROR: backend identity, corrupting the share's identity mapping (incident 2026-05-05)."
        log_share "ERROR: pick a force-user name that does not exist in AD."
        return 9
    fi

    # Safe to ensure the local /etc/passwd and /etc/group entries.
    if ! grep -q "^${FRONT_FORCE_USER}:" /etc/passwd 2>/dev/null; then
        useradd -M -s /usr/sbin/nologin "$FRONT_FORCE_USER"
    fi
    if ! grep -q "^${FRONT_FORCE_USER}:" /etc/group 2>/dev/null; then
        groupadd "$FRONT_FORCE_USER" 2>/dev/null || true
    fi

    install -d -o root -g root -m 0755 "$(dirname "$BACKEND_MOUNT")"
    install -d -o "$FRONT_FORCE_USER" -g "$FRONT_FORCE_USER" -m 0755 \
        "$BACKEND_MOUNT" 2>/dev/null \
        || install -d -m 0755 "$BACKEND_MOUNT"
    install -d -o root -g root -m 0755 "$SESSION_ROOT" "$SESSION_STATE"
    local frontend_path
    frontend_path=$(share_frontend_path "$SHARE_NAME" "$OFFLINE_MODE" "$BACKEND_MOUNT" "$DATA_ROOT" "$PROFILE")

    # ---- PRE-FLIGHT VALIDATION (no persistent writes yet) ----
    # The previous shape wrote creds + fstab line BEFORE running the
    # AD-group SID resolve and the testparm validation. A failure on
    # either of those left orphan creds + an orphan fstab line whose
    # share state was never saved — operator had to clean up by hand.
    # Compute everything we'll need first, run the high-risk
    # validations, and only then commit any writes.

    local creds; creds=$(share_creds_file "$SHARE_NAME")

    local FU_UID FU_GID CREDS
    FU_UID=$(awk -F: -v u="$FRONT_FORCE_USER" '$1==u {print $3; exit}' /etc/passwd)
    FU_GID=$(awk -F: -v u="$FRONT_FORCE_USER" '$1==u {print $4; exit}' /etc/passwd)
    if [[ -z "$FU_UID" || -z "$FU_GID" ]]; then
        log_share "ERROR: failed to resolve LOCAL UID/GID for force-user '${FRONT_FORCE_USER}'"
        return 5
    fi
    CREDS="$creds"
    # Aliases for downstream comments / smb.conf section.
    local fu_uid="$FU_UID" fu_gid="$FU_GID"

    # The cifs option string is profile-driven (see backend_mount_opts):
    #   legacy: dynamic per-tree SMB1 mount with cache=none,
    #           nosharesock, and lock forwarding enabled.
    #           No fstab line is written for this profile.
    #   modern: vers=3 (auto-negotiate 3.0/3.1.1) + kernel default
    #           caching + optional SMB3 sealing. Suitable for routine
    #           file-copy backends (CNC, NAS) on the domain LAN.
    # Common to both: numeric uid/gid and a per-share credentials file.
    local mount_opts; mount_opts=$(backend_mount_opts "$PROFILE")
    local fstab_line="//${BACKEND_IP}/${SHARE_NAME} ${BACKEND_MOUNT} cifs ${mount_opts} 0 0"

    # Keep the periodic worker from observing a half-written transition
    # between direct and queued state. Lock ordering is worker -> smb.conf,
    # matching the worker itself and remove_share().
    local worker_lock_fd
    install -d -m 0755 "$(dirname "$WORKER_LOCK")"
    exec {worker_lock_fd}>"$WORKER_LOCK"
    flock -x "$worker_lock_fd"

    # Frontend smb.conf section — only validated/built if domain-joined
    # AND FRONT_GROUP is set. Operator can add a share's backend pre-join
    # and publish the frontend later.
    local group_sid="" smb_conf_pending="" smb_lock_fd=""
    if is_joined && [[ -n "$FRONT_GROUP" ]]; then
        # Resolve the AD group to its SID at config time. SID-based
        # `valid users` is unambiguous, NSS-independent, and immune
        # to the `winbind use default domain = yes` parsing quirk that
        # makes `valid users = @"DOMAIN\Group"` fail to match in
        # Samba 4.22 on this appliance.
        group_sid=$(wbinfo --name-to-sid="$FRONT_GROUP" 2>/dev/null | awk '{print $1}')
        if [[ -z "$group_sid" || ! "$group_sid" =~ ^S-1- ]]; then
            log_share "ERROR: cannot resolve AD group '${FRONT_GROUP}' to a SID via winbind."
            log_share "ERROR: is the group name correct? Is winbind reachable? (try 'wbinfo --name-to-sid=\"${FRONT_GROUP}\"')"
            exec {worker_lock_fd}>&-
            return 6
        fi

        # Serialize smb.conf read/validate/replace with the periodic
        # health worker so neither process can overwrite the other's
        # newly rendered share state.
        install -d -m 0755 "$(dirname "$SMB_CONF_LOCK")"
        exec {smb_lock_fd}>"$SMB_CONF_LOCK"
        flock -x "$smb_lock_fd"

        # Build the candidate smb.conf in a temp file. Strip any prior
        # [SHARE_NAME] section, then append fresh.
        smb_conf_pending="${SMB_CONF}.new.$$"
        awk -v sname="[$SHARE_NAME]" '
            BEGIN { in_share=0 }
            $0 == sname { in_share=1; next }
            /^\[/ && in_share { in_share=0 }
            !in_share { print }
        ' "$SMB_CONF" > "$smb_conf_pending"

        cat >> "$smb_conf_pending" <<EOF

[${SHARE_NAME}]
    # profile=${PROFILE}; locking=${locking_kind}; offline=${OFFLINE_MODE}
    path = ${frontend_path}
    read only = no
    guest ok = no
    # AD-side ACL: only members of '${FRONT_GROUP}' (resolved at
    # config-time to its SID; SID is unambiguous and immune to the
    # default-domain NSS-name quirk that breaks @"DOMAIN\Group" form).
    valid users = ${group_sid}

    # All AD identities authenticated to this share are mapped to
    # the LOCAL Linux account '${FRONT_FORCE_USER}' (uid=${fu_uid}),
    # whose creds in ${creds} authenticate the cifs mount to the
    # backend. Username written here (not numeric UID) because Samba
    # resolves force user via getpwnam(), which uses the NSS files-first
    # order and finds the local account before winbind. AD-collision
    # check was performed at config time above.
    force user = ${FRONT_FORCE_USER}
    force group = ${FRONT_FORCE_USER}

$(frontend_offline_probe_stanza "$PROFILE" "$OFFLINE_MODE")
$(frontend_session_stanza "$PROFILE" "$OFFLINE_MODE")
$(frontend_locking_stanza "$locking_kind")
EOF

        if ! testparm -s "$smb_conf_pending" >/dev/null 2>/tmp/smbproxy-tp.$$; then
            rm -f "$smb_conf_pending"
            exec {smb_lock_fd}>&-
            exec {worker_lock_fd}>&-
            return 4
        fi
    fi

    # ---- COMMIT (all validations passed; writes from here on) ----

    if [[ "$OFFLINE_MODE" == "$OFFLINE_QUEUED" ]]; then
        install -d -o "$FRONT_FORCE_USER" -g "$FRONT_FORCE_USER" -m 0770 \
            "$frontend_path"
        install -d -o root -g root -m 0755 \
            "${DATA_ROOT}/state/$(share_safe_name "$SHARE_NAME")/manifest"
    fi

    # Per-share creds file. NEVER log this file's contents.
    install -d -o root -g root -m 0755 "$CREDS_DIR"
    umask 077
    cat > "$creds" <<EOF
username=${BACKEND_USER}
password=${BACKEND_PASS}
domain=${BACKEND_DOMAIN}
EOF
    chmod 0600 "$creds"
    chown root:root "$creds"
    umask 022

    sed -i "\| ${BACKEND_MOUNT} cifs |d" /etc/fstab
    if [[ "$PROFILE" == "$PROFILE_MODERN" ]]; then
        echo "$fstab_line" >> /etc/fstab
    fi
    systemctl daemon-reload

    # Persist state before publishing/reloading the smb.conf section: the VFS
    # connect hook intentionally fails closed if its share state is absent.
    save_share

    if [[ -n "$smb_conf_pending" ]]; then
        mv "$smb_conf_pending" "$SMB_CONF"
        chmod 0644 "$SMB_CONF"
        systemctl reload smbd 2>/dev/null || systemctl restart smbd
        exec {smb_lock_fd}>&-
    fi

    BACKEND_PASS=""; unset BACKEND_PASS
    exec {worker_lock_fd}>&-
    return 0
}

# check_share — read-only diagnostic for one configured share. Reports:
#   - state file presence + key fields
#   - creds file existence + permissions (does NOT print contents)
#   - fstab line + the option list
#   - live mount state + live option list (from /proc/mounts)
#   - drift diff: which expected options are absent from the live mount
#   - smb.conf section presence + identity resolution
#       * force user / force group are non-numeric usernames matching
#         FRONT_FORCE_USER's local /etc/passwd entry
#       * valid_users is a SID that resolves via wbinfo
#   - backend reachability (TCP probe to BACKEND_IP:445)
#
# Read-only — no state mutation, no service restart. Safe to run
# during production traffic.
#
# Exit codes:
#   0 — all good (mounted, options match expected, identity resolves)
#   1 — drift (live options diverge from profile expectation, or
#       identity doesn't resolve cleanly, or smb.conf section missing
#       when it should be present)
#   2 — backend unreachable (TCP/445 probe fails) — informational
#       overlay on top of whatever else is reported; rc=2 wins over
#       rc=1 because reachability is the more actionable signal
#   3 — no such share (state file absent)
check_share() {
    local name="$1"
    [[ -n "$name" ]] || { echo "check_share: missing name" >&2; return 2; }

    if ! load_share "$name"; then
        echo "no such share: '$name'" >&2
        echo "configured shares: $(list_shares 2>/dev/null | tr '\n' ' ')" >&2
        return 3
    fi

    local profile="${PROFILE:-$PROFILE_LEGACY}"
    local creds; creds=$(share_creds_file "$SHARE_NAME")
    local rc=0
    local backend_unreachable=0

    printf '== share: %s\n' "$SHARE_NAME"
    printf '   profile:        %s\n' "$profile"
    printf '   offline mode:   %s\n' "${OFFLINE_MODE:-$OFFLINE_DIRECT}"
    printf '   backend:        //%s/%s  user=%s domain=%s\n' \
        "${BACKEND_IP:-?}" "$SHARE_NAME" "${BACKEND_USER:-?}" "${BACKEND_DOMAIN:-?}"
    printf '   mount path:     %s\n' "${BACKEND_MOUNT:-?}"
    printf '   frontend path:  %s\n' \
        "$(share_frontend_path "$SHARE_NAME" "${OFFLINE_MODE:-$OFFLINE_DIRECT}" "${BACKEND_MOUNT:-}" "$DATA_ROOT" "$profile")"
    if [[ "${OFFLINE_MODE:-$OFFLINE_DIRECT}" == "$OFFLINE_QUEUED" ]]; then
        if data_mount_ready; then
            printf '   data disk:      mounted at %s\n' "$DATA_ROOT"
        else
            printf '   data disk:      MISSING at %s\n' "$DATA_ROOT"
            rc=1
        fi
        local health_file
        health_file="${STATE_DIR}/health/$(share_safe_name "$SHARE_NAME").env"
        if [[ -r "$health_file" ]]; then
            local BACKEND_REACHABLE="" PENDING_UPLOADS="" PENDING_DELETES="" LAST_ERROR=""
            # shellcheck disable=SC1090
            source "$health_file"
            printf '   queue:          uploads=%s deletes=%s backend=%s\n' \
                "${PENDING_UPLOADS:-?}" "${PENDING_DELETES:-?}" \
                "${BACKEND_REACHABLE:-?}"
            [[ -z "${LAST_ERROR:-}" ]] || printf '   queue error:    %s\n' "$LAST_ERROR"
        fi
    fi
    printf '   force user:     %s\n' "${FRONT_FORCE_USER:-(unset)}"
    printf '   AD group:       %s\n' "${FRONT_GROUP:-(unset — backend-only share)}"

    # --- creds file --------------------------------------------------
    if [[ -f "$creds" ]]; then
        local creds_perm
        creds_perm=$(stat -c '%a %U:%G' "$creds" 2>/dev/null || echo '?')
        if [[ "$creds_perm" == "600 root:root" ]]; then
            printf '   creds file:     %s  (0600 root:root, OK)\n' "$creds"
        else
            printf '   creds file:     %s  (perms=%s — EXPECTED 600 root:root)\n' "$creds" "$creds_perm"
            rc=1
        fi
    else
        printf '   creds file:     %s  (MISSING)\n' "$creds"
        rc=1
    fi

    # --- mount strategy + expected options ----------------------------
    local fstab_line FU_UID FU_GID CREDS expected_opts=""
    fstab_line=$(grep -F " ${BACKEND_MOUNT} cifs " /etc/fstab 2>/dev/null | head -1 || true)
    FU_UID=$(awk -F: -v u="${FRONT_FORCE_USER:-}" '$1==u {print $3; exit}' /etc/passwd)
    FU_GID=$(awk -F: -v u="${FRONT_FORCE_USER:-}" '$1==u {print $4; exit}' /etc/passwd)
    CREDS="$creds"
    if [[ -n "$FU_UID" && -n "$FU_GID" ]]; then
        expected_opts=$(backend_mount_opts "$profile")
        printf '   profile would:  %s\n' "$expected_opts"
    else
        printf '   profile would:  (cannot render — local UID for "%s" not in /etc/passwd)\n' "${FRONT_FORCE_USER:-?}"
        rc=1
    fi

    local live_line live_opts
    if [[ "$profile" == "$PROFILE_LEGACY" ]]; then
        if [[ -n "$fstab_line" ]]; then
            printf '   DRIFT:          legacy share still has a static fstab mount\n'
            rc=1
        else
            printf '   fstab:          none (correct: session-managed)\n'
        fi

        local session_count=0 session_record recorded_share recorded_mount opt
        local session_devices="" distinct_devices=0
        shopt -s nullglob
        for session_record in "$SESSION_STATE"/*.env; do
            recorded_share=$(sed -n 's/^SHARE_NAME="\(.*\)"$/\1/p' "$session_record" 2>/dev/null | head -1)
            [[ "$recorded_share" == "$SHARE_NAME" ]] || continue
            recorded_mount=$(sed -n 's/^MOUNTPOINT="\(.*\)"$/\1/p' "$session_record" 2>/dev/null | head -1)
            live_line=$(awk -v mp="$recorded_mount" '$2==mp && $3=="cifs" {print; exit}' /proc/mounts 2>/dev/null || true)
            if [[ -n "$live_line" ]]; then
                live_opts=$(awk '{print $4}' <<< "$live_line")
                session_count=$((session_count + 1))
                session_devices+="$(stat -c '%d' "$recorded_mount" 2>/dev/null)"$'\n'
                printf '   session mount:  %s\n' "$recorded_mount"
                printf '   live options:   %s\n' "$live_opts"
                if grep -qE '(^|,)nobrl(,|$)' <<< "$live_opts"; then
                    printf '   DRIFT:          nobrl disables SMB1 lock forwarding\n'
                    rc=1
                fi
                for opt in 'vers=1.0' 'cache=none' 'nosharesock'; do
                    if ! grep -qE "(^|,)${opt//./\\.}(,|$)" <<< "$live_opts"; then
                        printf '   DRIFT:          session mount missing %s\n' "$opt"
                        rc=1
                    fi
                done
            else
                printf '   DRIFT:          state exists without CIFS mount: %s\n' "$recorded_mount"
                rc=1
            fi
        done
        shopt -u nullglob
        printf '   active sessions: %s (zero is normal while idle)\n' "$session_count"
        if (( session_count > 1 )); then
            distinct_devices=$(sed '/^$/d' <<< "$session_devices" | sort -u | wc -l)
            if [[ "$distinct_devices" -ne "$session_count" ]]; then
                printf '   DRIFT:          %s sessions but only %s CIFS filesystem identities\n' \
                    "$session_count" "$distinct_devices"
                rc=1
            else
                printf '   filesystem IDs: %s distinct for %s sessions — OK\n' \
                    "$distinct_devices" "$session_count"
            fi
        fi
        if ! "$VFS_VERSION_HELPER" 2>/dev/null; then
            printf '   VFS version:    MISMATCH — smbd will fail closed on restart\n'
            rc=1
        else
            printf '   VFS version:    matches installed Samba\n'
        fi
    else
        if [[ -z "$fstab_line" ]]; then
            printf '   fstab:          (NO LINE for %s)\n' "$BACKEND_MOUNT"
            rc=1
        else
            printf '   fstab options:  %s\n' "$(awk '{print $4}' <<< "$fstab_line")"
        fi

        live_line=$(awk -v mp="$BACKEND_MOUNT" '$2==mp && $3=="cifs" {print; exit}' /proc/mounts 2>/dev/null || true)
        if [[ -n "$live_line" ]]; then
            live_opts=$(awk '{print $4}' <<< "$live_line")
            printf '   live mount:     ACTIVE\n'
            printf '   live options:   %s\n' "$live_opts"
            local missing="" opt
            IFS=',' read -ra _expected_arr <<< "$expected_opts"
            for opt in "${_expected_arr[@]}"; do
                [[ "$opt" == x-systemd.* || "$opt" == _netdev || "$opt" == credentials=* ]] && continue
                if ! grep -qE "(^|,)${opt//./\\.}(,|$)" <<< "$live_opts"; then
                    missing+="${opt} "
                fi
            done
            if [[ -n "$missing" ]]; then
                printf '   DRIFT:          live mount missing: %s\n' "$missing"
                rc=1
            fi
        else
            printf '   live mount:     not currently mounted (automount on first access)\n'
        fi
    fi

    # --- backend reachability ----------------------------------------
    # Quick TCP/445 probe with a short timeout. Distinguishes "device
    # offline" from "config drift". Uses bash's /dev/tcp pseudo-device
    # so we don't need nc / socat installed.
    if [[ -n "${BACKEND_IP:-}" ]]; then
        if timeout 3 bash -c ">/dev/tcp/${BACKEND_IP}/445" 2>/dev/null; then
            printf '   backend tcp/445: REACHABLE\n'
        else
            printf '   backend tcp/445: UNREACHABLE  (device powered down, or routing/firewall)\n'
            backend_unreachable=1
        fi
    fi

    # --- smb.conf section --------------------------------------------
    if share_section_present "$SHARE_NAME"; then
        printf '   smb.conf:       [%s] section present\n' "$SHARE_NAME"
        local sec
        sec=$(awk -v s="[$SHARE_NAME]" 'BEGIN{p=0} $0==s{p=1; next} /^\[/{p=0} p' "$SMB_CONF" 2>/dev/null)
        if [[ "$profile" == "$PROFILE_LEGACY" ]]; then
            if grep -qE '^[[:space:]]*vfs objects[[:space:]]*=[[:space:]]*smbproxy_session[[:space:]]+fileid([[:space:]]|$)' <<< "$sec" \
                && grep -qEi '^[[:space:]]*fileid:algorithm[[:space:]]*=[[:space:]]*fsname[[:space:]]*$' <<< "$sec"; then
                printf '   session VFS:    smbproxy_session + fileid(fsname) — OK\n'
            else
                printf '   session VFS:    MISSING/UNNORMALIZED — legacy locking integrity is not enforced\n'
                rc=1
            fi
        fi

        # Identity resolution checks — only meaningful if joined.
        if is_joined && [[ -n "${FRONT_GROUP:-}" ]]; then
            # force user is now written as a username (not numeric UID)
            # because Samba resolves it via getpwnam(); numeric strings
            # don't resolve. The default-domain ambiguity defense lives
            # at write time (AD-collision check + NSS files-first
            # ordering) and is verified here:
            #   1. value is a username string (not numeric)
            #   2. it matches the saved FRONT_FORCE_USER state
            #   3. /etc/passwd resolves the same UID winbind would NOT
            #      override (we look at the LOCAL files entry directly,
            #      bypassing NSS) — confirms the local account exists.
            local smb_user
            smb_user=$(grep -oE 'force user[[:space:]]*=[[:space:]]*[^[:space:]]+' <<< "$sec" \
                | sed -E 's/^force user[[:space:]]*=[[:space:]]*//' | head -1)
            if [[ -z "$smb_user" ]]; then
                printf '   force_user:     smb.conf has no force user entry\n'
                rc=1
            elif [[ "$smb_user" =~ ^[0-9]+$ ]]; then
                # Numeric value would silently fail at tree-connect
                # (NT_STATUS_NO_SUCH_USER) because getpwnam("1003")
                # returns nothing even when getpwuid(1003) succeeds.
                printf '   force_user:     smb.conf force user is numeric (%s) — Samba getpwnam() will fail\n' "$smb_user"
                rc=1
            elif [[ -n "${FRONT_FORCE_USER:-}" && "$smb_user" != "$FRONT_FORCE_USER" ]]; then
                printf '   force_user:     smb.conf force user=%s but saved state has FRONT_FORCE_USER=%s — DRIFT\n' \
                    "$smb_user" "$FRONT_FORCE_USER"
                rc=1
            else
                # Resolve via /etc/passwd (files-only) so a winbind
                # outage / AD-side rename doesn't muddy the answer.
                local pw_uid
                pw_uid=$(awk -F: -v u="$smb_user" '$1==u {print $3; exit}' /etc/passwd)
                if [[ -z "$pw_uid" ]]; then
                    printf '   force_user:     %s has no /etc/passwd entry — local account is missing\n' "$smb_user"
                    rc=1
                elif [[ -n "${FU_UID:-}" && "$pw_uid" != "$FU_UID" ]]; then
                    printf '   force_user:     /etc/passwd UID=%s for %s, but loaded state has FU_UID=%s — MISMATCH\n' \
                        "$pw_uid" "$smb_user" "$FU_UID"
                    rc=1
                else
                    printf '   force_user:     %s (uid=%s, local /etc/passwd) — OK\n' "$smb_user" "$pw_uid"
                fi
            fi

            # valid users must be a SID and resolvable via wbinfo to FRONT_GROUP.
            local smb_sid
            smb_sid=$(grep -oE 'valid users[[:space:]]*=[[:space:]]*S-1-[0-9-]+' <<< "$sec" | awk -F= '{gsub(/^[[:space:]]+|[[:space:]]+$/,"",$2); print $2}')
            if [[ -z "$smb_sid" ]]; then
                printf '   valid_users:    not a SID — default-domain ambiguity defense violated\n'
                rc=1
            else
                local resolved
                resolved=$(wbinfo --sid-to-name="$smb_sid" 2>/dev/null | awk '{print $1}' || true)
                if [[ -z "$resolved" ]]; then
                    printf '   valid_users:    SID=%s does NOT resolve via wbinfo (winbind down? group deleted?)\n' "$smb_sid"
                    rc=1
                else
                    printf '   valid_users:    SID=%s -> %s — OK\n' "$smb_sid" "$resolved"
                fi
            fi
        elif [[ -z "${FRONT_GROUP:-}" ]]; then
            printf '   identity:       (no FRONT_GROUP — backend-only share, identity check skipped)\n'
        else
            printf '   identity:       (proxy not domain-joined — identity check skipped)\n'
        fi
    elif [[ -n "${FRONT_GROUP:-}" ]]; then
        printf '   smb.conf:       [%s] section MISSING (FRONT_GROUP set — should be published)\n' "$SHARE_NAME"
        rc=1
    else
        printf '   smb.conf:       (not published — no FRONT_GROUP set)\n'
    fi

    # Backend unreachable wins over drift in the exit code because
    # it's the more actionable signal. A drift report is meaningless
    # if the device is just powered down — fix the device first.
    if [[ "$backend_unreachable" -eq 1 ]]; then
        return 2
    fi
    return $rc
}

# shares_add_wizard — TUI flow to create a new share end-to-end.
# Prompts for SHARE_NAME first; subsequent dialogs all carry
# "Share: $SHARE_NAME" in the body so the operator never has to look
# at the title bar for context (per dev-commons/STYLE.md §3 / §15).
shares_add_wizard() {
    local existing_names
    existing_names=$(list_shares 2>/dev/null)

    # Initial share name. Reject collisions; allow $-suffixes; reject
    # path-hostile characters that would make the safe-name ambiguous.
    local SHARE_NAME=""
    while true; do
        SHARE_NAME=$(whiptail --title "Add proxied share" \
            --inputbox "Choose the share's name.\n\nThis is BOTH the legacy backend share name AND the published\nSMB3 share name (operator picks one; it appears at both ends).\nTrailing \$ marks it hidden in network browsing.\n\nExample: Engineering\$" \
            16 70 "" 3>&1 1>&2 2>&3) || return
        # Single point of truth for share-name validity (also used by
        # cli_configure_share). Captures empty, bad chars, whitespace,
        # and shell metas — the latter is the trailing fix for the
        # spaces-in-fstab bug + the trailing $-vs-other-$ distinction.
        local validate_err
        if ! validate_err=$(share_name_validate "$SHARE_NAME" 2>&1); then
            info "Invalid share name:\n${validate_err#*: }"
            continue
        fi
        if echo "$existing_names" | grep -qFx "$SHARE_NAME"; then
            info "A share named '$SHARE_NAME' already exists.\nUse Edit to change it, Remove to delete it first."
            continue
        fi
        # Safe-name collision check: `A-B` and `A_B` both encode to
        # `A_B`, which would silently overwrite the first share's
        # state file. share_safe_name_collides_with_existing prints
        # the colliding peer to stdout.
        local peer
        if peer=$(share_safe_name_collides_with_existing "$SHARE_NAME"); then
            info "Share name '$SHARE_NAME' would conflict with existing\nshare '$peer' on disk (both encode to the same state-file\nname). Pick a different name."
            continue
        fi
        break
    done

    local body_ctx="Share: ${SHARE_NAME}"
    local BACKEND_IP="" BACKEND_USER="" BACKEND_DOMAIN="" BACKEND_MOUNT=""
    local BACKEND_PASS="" FRONT_GROUP="" FRONT_FORCE_USER=""
    local PROFILE="" OFFLINE_MODE="" BACKEND_VERS="" BACKEND_SEAL="" LOCKING_OVERRIDE=""

    # Profile picker. The CLI supports both legacy and modern shares
    # but the TUI used to silently default to legacy, blocking the
    # CNC/NAS/HMI use case from console-only operators. Default selects
    # legacy so existing installs see no behavior change unless the
    # operator picks modern explicitly.
    PROFILE=$(whiptail --title "Add proxied share — profile" \
        --radiolist "${body_ctx}\n\nWhich backend profile?\n\n  legacy: SMB1 (e.g. Clarion .TPS) — vers=1.0, strict locking,\n          hard mount. Backend assumed always-on.\n  modern: SMB3 (CNC, NAS, HMI) — vers=3 default, optional sealing,\n          relaxed locking, soft+automount with offline-device fail-fast." \
        18 76 2 \
        legacy "Legacy SMB1 (Clarion .TPS, ISAM-style)" ON  \
        modern "Modern SMB3 (CNC / NAS / HMI)"          OFF \
        3>&1 1>&2 2>&3) || return

    if [[ "$PROFILE" == "modern" ]]; then
        OFFLINE_MODE=$(whiptail --title "Add proxied share — offline behavior" \
            --radiolist "${body_ctx}\n\nWhat should office users see when the machine is offline?\n\n  direct: serve the live machine share; fail quickly if unavailable.\n  queued: serve the appliance data disk at all times and deliver\n          office-managed changes when the machine returns." \
            19 76 2 \
            direct "Live backend; fail fast while machine is offline" ON \
            queued "Always available; queue one-way office deployments" OFF \
            3>&1 1>&2 2>&3) || return
        if [[ "$OFFLINE_MODE" == "$OFFLINE_QUEUED" ]] && ! data_mount_ready; then
            info "Queued mode requires a secondary data disk mounted at\n${DATA_ROOT}.\n\nAttach and initialize it under:\nSystem Configuration -> Offline-share Data Disk"
            return
        fi

        # Backend SMB version. `default` lets cifs negotiate (no vers=
        # token written). 3 is the appliance default.
        BACKEND_VERS=$(whiptail --title "Add proxied share — backend SMB version" \
            --radiolist "${body_ctx}\n\nProtocol version to negotiate with the backend.\nPick '3' if unsure (most modern devices); the device's spec\nsheet usually says SMB2/SMB3. 'default' lets cifs decide." \
            20 76 8 \
            3       "SMB3 — auto-negotiate 3.0/3.1.1 (recommended)"     ON  \
            3.0     "SMB3.0 only"                                       OFF \
            3.0.2   "SMB3.0.2 only"                                     OFF \
            3.1.1   "SMB3.1.1 only"                                     OFF \
            2.1     "SMB2.1 only (older HMIs)"                          OFF \
            2.0     "SMB2.0 only"                                       OFF \
            1.0     "SMB1 only (rare on modern profile; prefer legacy)" OFF \
            default "Let cifs negotiate (no vers= token)"               OFF \
            3>&1 1>&2 2>&3) || return

        # Sealing — SMB3-only wire encryption. Auto-suppressed on
        # non-SMB3 versions (see backend_mount_opts). Asking on every
        # modern share keeps the choice visible but defaults to ON
        # because that's the appliance's documented modern posture.
        if [[ "$BACKEND_VERS" =~ ^3 ]]; then
            local seal_pick
            seal_pick=$(whiptail --title "Add proxied share — backend SMB3 sealing" \
                --radiolist "${body_ctx}\n\nSMB3 wire encryption (cifs 'seal' option).\nRecommended ON for any backend on the domain LAN.\nAdds ~10-30% CPU on the slow IO patterns these devices generate." \
                14 70 2 \
                yes "Encrypt backend traffic (recommended)" ON  \
                no  "No encryption (lower CPU)"             OFF \
                3>&1 1>&2 2>&3) || return
            BACKEND_SEAL="$seal_pick"
        else
            # vers=1.0/2.x can't carry seal; skip the dialog and leave
            # BACKEND_SEAL empty (configure_share treats this as default-
            # off via backend_mount_opts' SMB3 guard).
            BACKEND_SEAL=""
        fi

        # Locking override — only relevant for modern (legacy is fixed
        # at tps-strict). 'profile-default' = relaxed for modern.
        LOCKING_OVERRIDE=$(whiptail --title "Add proxied share — locking" \
            --radiolist "${body_ctx}\n\nLocking semantics on the published SMB3 frontend.\nPick 'profile-default' (= relaxed) unless this share carries\nan ISAM-style multi-writer database that needs strict locking." \
            16 76 3 \
            profile-default "Relaxed (modern default — file-copy backends)" ON  \
            relaxed         "Relaxed (explicit)"                             OFF \
            tps-strict      "Strict — ISAM/.TPS multi-writer DB"             OFF \
            3>&1 1>&2 2>&3) || return

        # Translate 'profile-default' to empty for configure_share
        # (which interprets empty as "use the profile's default").
        [[ "$LOCKING_OVERRIDE" == "profile-default" ]] && LOCKING_OVERRIDE=""
    else
        OFFLINE_MODE="$OFFLINE_DIRECT"
    fi

    BACKEND_IP=$(whiptail --title "Add proxied share — backend IP" \
        --inputbox "${body_ctx}\n\nlegacy backend IPv4 (LegacyZone-side):" \
        12 64 "" 3>&1 1>&2 2>&3) || return

    # Note: same BACKEND_IP with a different SHARE_NAME is the
    # *intended* multi-share case (multiple shares from one backend
    # with independent creds), so we DON'T warn on (IP, SHARE_NAME)
    # combinations. Same SHARE_NAME couldn't get here — we rejected
    # duplicate names above. The only meaningful collision worth
    # warning on is mount-path overlap, which we check after BACKEND_MOUNT
    # is collected below.

    BACKEND_USER=$(whiptail --title "Add proxied share — backend user" \
        --inputbox "${body_ctx}\n\nLocal legacy SMB1 backend user with read/write access on the share:" \
        12 64 "" 3>&1 1>&2 2>&3) || return
    BACKEND_DOMAIN=$(whiptail --title "Add proxied share — backend domain" \
        --inputbox "${body_ctx}\n\nlegacy SMB1 backend NetBIOS domain (or workgroup) name:" \
        12 64 "LEGACY" 3>&1 1>&2 2>&3) || return

    local p1 p2
    p1=$(whiptail --title "Add proxied share — backend password" \
        --passwordbox "${body_ctx}\n\nPassword for ${BACKEND_USER}:" \
        12 64 3>&1 1>&2 2>&3) || return
    p2=$(whiptail --title "Add proxied share — confirm password" \
        --passwordbox "${body_ctx}\n\nConfirm password for ${BACKEND_USER}:" \
        12 64 3>&1 1>&2 2>&3) || return
    [[ "$p1" == "$p2" ]] || { info "Passwords don't match."; return; }
    BACKEND_PASS="$p1"

    # Default mount path is profile-aware: modern shares default to
    # /mnt/backend/<safe>, legacy to /mnt/legacy/<safe> (mirroring the
    # CLI default). Operator can edit either way.
    BACKEND_MOUNT=$(whiptail --title "Add proxied share — local mount point" \
        --inputbox "${body_ctx}\n\nLocal mount point on the proxy:" \
        12 64 "$(share_default_mount "$SHARE_NAME" "$PROFILE")" 3>&1 1>&2 2>&3) || { BACKEND_PASS=""; return; }

    # Mount-path collision check. The default mount path is derived
    # from SHARE_NAME so a default-vs-default collision is impossible
    # (we already rejected duplicate SHARE_NAMEs); the operator gets
    # here only if they typed a custom path that overlaps another
    # share's. Warn-but-allow per the user's stated preference.
    local n other_mount
    while IFS= read -r n; do
        [[ -z "$n" ]] && continue
        other_mount=$( load_share "$n" 2>/dev/null; printf '%s' "${BACKEND_MOUNT:-}" )
        if [[ -n "$other_mount" && "$other_mount" == "$BACKEND_MOUNT" ]]; then
            yesno "Mount path '${BACKEND_MOUNT}' is already used by share '${n}'.\n\nAdding this share will REPLACE that share's fstab entry.\nThe other share's smb.conf section is left alone but will\npoint at a path that no longer mounts what it expects.\n\nProceed anyway?" \
                || { BACKEND_PASS=""; return; }
            break
        fi
    done <<< "$existing_names"

    if is_joined; then
        # Loop on appcore_id_domgroup_validate so the operator can
        # type any of the accepted forms (literal space, '\ ' shell
        # escape, double-backslash, quoted) and a bad input gets a
        # clear retry instead of a silent acceptance that fails later
        # at wbinfo. The validator surfaces the same accept set as
        # the samba-addc sudo-grant site (field-bug Phase 1).
        local _raw_group _validate_err
        while true; do
            _raw_group=$(whiptail --title "Add proxied share — AD access group" \
                --inputbox "${body_ctx}\n\nAD security group authorized to use this share.\nFormat: DOMAIN_SHORT\\Group Name (e.g. ${DOMAIN_SHORT:-LAB}\\${SHARE_NAME%\$} Users).\nThe @\"\" wrapper in smb.conf is added automatically." \
                14 74 "${DOMAIN_SHORT:-DOMAIN}\\${SHARE_NAME%\$} Users" 3>&1 1>&2 2>&3) || { BACKEND_PASS=""; return; }
            if appcore_id_domgroup_validate "$_raw_group" 2>/dev/null; then
                # Canonicalize to the smb.conf-ready form so display +
                # config storage agree on the single form.
                FRONT_GROUP=$(appcore_id_domgroup_normalize "$_raw_group")
                break
            fi
            info_text "Invalid AD group" "Invalid AD group name. Examples of accepted forms:
  ${DOMAIN_SHORT:-LAB}\\Domain Admins
  ${DOMAIN_SHORT:-LAB}\\Engineering Users"
        done
    else
        info "Not domain-joined — backend will be configured but the\nfrontend [smb.conf] section is skipped. Re-run Edit after\njoining the domain to publish the share."
    fi

    FRONT_FORCE_USER=$(whiptail --title "Add proxied share — local force-user" \
        --inputbox "${body_ctx}\n\nLocal Linux account that owns the cifs mount AND that AD\nidentities authenticated to this share are mapped to on the\nway out to legacy SMB1 backend. Created if absent (system user, nologin)." \
        14 74 "${BACKEND_USER}" 3>&1 1>&2 2>&3) || { BACKEND_PASS=""; return; }

    # Compose a profile-aware confirmation summary so the operator
    # can sanity-check the modern-only knobs before committing.
    local _confirm_extra=""
    if [[ "$PROFILE" == "modern" ]]; then
        local _vers_disp="${BACKEND_VERS:-3}"
        local _seal_disp="${BACKEND_SEAL:-(default)}"
        local _lock_disp="${LOCKING_OVERRIDE:-relaxed (profile default)}"
        _confirm_extra=$'\n'"  vers:        ${_vers_disp}"$'\n'"  sealing:     ${_seal_disp}"$'\n'"  locking:     ${_lock_disp}"
    fi
    yesno "Apply share '${SHARE_NAME}' (${PROFILE})?\n\n  backend://${BACKEND_IP}/${SHARE_NAME} -> ${BACKEND_MOUNT}\n  offline:     ${OFFLINE_MODE}\n  frontend:    $(share_frontend_path "$SHARE_NAME" "$OFFLINE_MODE" "$BACKEND_MOUNT" "$DATA_ROOT" "$PROFILE")\n  backend user: ${BACKEND_DOMAIN}\\${BACKEND_USER}\n  AD access:   ${FRONT_GROUP:-(skipped — not joined)}\n  force user:  ${FRONT_FORCE_USER}${_confirm_extra}" \
        || { BACKEND_PASS=""; return; }

    if configure_share; then
        if [[ "$OFFLINE_MODE" == "$OFFLINE_QUEUED" ]]; then
            info "Share '${SHARE_NAME}' configured in queued mode.\n\nOffice users now work from the appliance data disk. Files are\ndelivered one-way to the machine when its backend is reachable."
        elif [[ "$PROFILE" == "$PROFILE_LEGACY" ]]; then
            info "Share '${SHARE_NAME}' configured in legacy session mode.\n\nEach downstream SMB3 tree now creates a distinct upstream SMB1\nsession. Use 'Mount / unmount a share' to run a temporary\ncredential/readability probe."
        else
            info "Share '${SHARE_NAME}' configured in direct mode.\n\nUse 'Mount / unmount a share' to mount it, or just access\n${BACKEND_MOUNT} — automount triggers."
        fi
    else
        local rc=$?
        info "configure_share failed (rc=$rc).\n  rc=2: missing required field / bad --locking value\n  rc=4: testparm rejected the smb.conf — see /tmp/smbproxy-tp.*\n  rc=5: no /etc/passwd entry for the force-user\n  rc=6: AD group could not be resolved to a SID (winbind down? group missing?)\n  rc=7: legacy profile but no legacy NIC role assigned\n  rc=8: invalid profile value\n  rc=9: AD-name collision — '${FRONT_FORCE_USER}' also exists in AD\n  rc=10: invalid offline mode (queued requires modern profile)\n  rc=11: queued mode requires the secondary data disk\n  rc=12: session VFS missing or built for another Samba version."
    fi
    BACKEND_PASS=""
}

# shares_edit_picker — pick a share, then a per-field edit menu. Body
# of every field-edit dialog carries "Share: $name".
shares_edit_picker() {
    local name
    name=$(pick_share "Pick a share to edit:") || return
    [[ -n "$name" ]] || return
    load_share "$name" || { info "Share '$name' state file missing."; return; }
    local body_ctx="Share: ${name}"

    while true; do
        # Show modern-only fields in the summary header so the operator
        # sees them at a glance for modern shares.
        local _modern_summary=""
        if [[ "${PROFILE:-}" == "modern" ]]; then
            _modern_summary=$'\n  vers: '"${BACKEND_VERS:-3 (default)}"$'  seal: '"${BACKEND_SEAL:-default}"$'  locking: '"${LOCKING_OVERRIDE:-relaxed (default)}"
        fi
        local choice
        choice=$(whiptail --title "Edit share: $name" \
            --menu "${body_ctx} (${PROFILE:-legacy})\n\n  backend://${BACKEND_IP:-?}/${name} -> ${BACKEND_MOUNT:-?}\n  offline: ${OFFLINE_MODE:-$OFFLINE_DIRECT}\n  AD group: ${FRONT_GROUP:-(unset)}\n  force user: ${FRONT_FORCE_USER:-?}${_modern_summary}\n\nPick a field to update:" \
            "$WT_HEIGHT" "$WT_WIDTH" 11 \
            "1" "Backend password (most common edit)" \
            "2" "AD access group (FRONT_GROUP)" \
            "3" "Local force-user (FRONT_FORCE_USER)" \
            "4" "Backend IP (BACKEND_IP)" \
            "5" "Backend user (BACKEND_USER)" \
            "6" "Backend domain (BACKEND_DOMAIN)" \
            "7" "Backend SMB version (modern only)" \
            "8" "Backend sealing (modern only)" \
            "9" "Locking override (modern only)" \
            "10" "Offline behavior (direct / queued)" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return

        case "$choice" in
            1)
                local p1 p2
                p1=$(whiptail --title "Edit share: $name — new password" \
                    --passwordbox "${body_ctx}\n\nNew password for ${BACKEND_USER}:" 12 64 \
                    3>&1 1>&2 2>&3) || continue
                p2=$(whiptail --title "Edit share: $name — confirm" \
                    --passwordbox "${body_ctx}\n\nConfirm:" 12 64 \
                    3>&1 1>&2 2>&3) || continue
                [[ "$p1" == "$p2" ]] || { info "Passwords don't match."; continue; }
                BACKEND_PASS="$p1"
                if configure_share; then
                    info "Password updated for '$name'."
                else
                    info "configure_share failed (rc=$?)"
                fi
                BACKEND_PASS=""
                ;;
            2)
                # Same validate-loop as the add-wizard: accept any
                # form, canonicalize via appcore, retry on bad input.
                local _raw_grp _err
                while true; do
                    _raw_grp=$(whiptail --title "Edit share: $name — AD group" \
                        --inputbox "${body_ctx}\n\nAD security group authorized:" 12 70 \
                        "$FRONT_GROUP" 3>&1 1>&2 2>&3) || continue 2
                    if appcore_id_domgroup_validate "$_raw_grp" 2>/dev/null; then
                        FRONT_GROUP=$(appcore_id_domgroup_normalize "$_raw_grp")
                        break
                    fi
                    info_text "Invalid AD group" "Invalid AD group name. Examples:
  LAB\\Domain Admins
  LAB\\Engineering Users"
                done
                save_share
                # Need a re-write of smb.conf, which configure_share does.
                # But it requires BACKEND_PASS — re-prompt.
                local p
                p=$(whiptail --title "Edit share: $name — confirm with password" \
                    --passwordbox "${body_ctx}\n\nRe-enter backend password to apply (creds file is\nrewritten to keep state consistent):" 13 64 \
                    3>&1 1>&2 2>&3) || continue
                BACKEND_PASS="$p"
                configure_share && info "AD group updated for '$name'." || info "configure_share failed (rc=$?)"
                BACKEND_PASS=""
                ;;
            3)
                FRONT_FORCE_USER=$(whiptail --title "Edit share: $name — force-user" \
                    --inputbox "${body_ctx}\n\nLocal Linux force-user account:" 12 70 \
                    "$FRONT_FORCE_USER" 3>&1 1>&2 2>&3) || continue
                local p
                p=$(whiptail --title "Edit share: $name — confirm with password" \
                    --passwordbox "${body_ctx}\n\nRe-enter backend password to apply:" 12 64 \
                    3>&1 1>&2 2>&3) || continue
                BACKEND_PASS="$p"
                configure_share && info "Force-user updated for '$name'." || info "configure_share failed (rc=$?)"
                BACKEND_PASS=""
                ;;
            4)
                BACKEND_IP=$(whiptail --title "Edit share: $name — backend IP" \
                    --inputbox "${body_ctx}\n\nlegacy backend IPv4:" 12 64 \
                    "$BACKEND_IP" 3>&1 1>&2 2>&3) || continue
                local p
                p=$(whiptail --title "Edit share: $name — confirm with password" \
                    --passwordbox "${body_ctx}\n\nRe-enter backend password to apply:" 12 64 \
                    3>&1 1>&2 2>&3) || continue
                BACKEND_PASS="$p"
                configure_share && info "Backend IP updated for '$name'." || info "configure_share failed (rc=$?)"
                BACKEND_PASS=""
                ;;
            5)
                BACKEND_USER=$(whiptail --title "Edit share: $name — backend user" \
                    --inputbox "${body_ctx}\n\nlegacy SMB1 backend user with r/w access:" 12 64 \
                    "$BACKEND_USER" 3>&1 1>&2 2>&3) || continue
                local p
                p=$(whiptail --title "Edit share: $name — new password" \
                    --passwordbox "${body_ctx}\n\nNew password for ${BACKEND_USER}:" 12 64 \
                    3>&1 1>&2 2>&3) || continue
                BACKEND_PASS="$p"
                configure_share && info "Backend user updated for '$name'." || info "configure_share failed (rc=$?)"
                BACKEND_PASS=""
                ;;
            6)
                BACKEND_DOMAIN=$(whiptail --title "Edit share: $name — backend domain" \
                    --inputbox "${body_ctx}\n\nlegacy SMB1 backend NetBIOS domain or workgroup:" 12 64 \
                    "$BACKEND_DOMAIN" 3>&1 1>&2 2>&3) || continue
                local p
                p=$(whiptail --title "Edit share: $name — confirm with password" \
                    --passwordbox "${body_ctx}\n\nRe-enter backend password to apply:" 12 64 \
                    3>&1 1>&2 2>&3) || continue
                BACKEND_PASS="$p"
                configure_share && info "Backend domain updated for '$name'." || info "configure_share failed (rc=$?)"
                BACKEND_PASS=""
                ;;
            7)
                if [[ "${PROFILE:-}" != "modern" ]]; then
                    info "Backend SMB version is fixed at 1.0 for legacy profile.\nConvert this share to modern (remove + re-add) to choose a version."
                    continue
                fi
                # Pre-compute the per-version selection state. Inlining
                # `$([[ ... ]] && echo ON || echo OFF)` between the
                # whiptail args works but trips shellcheck SC2046 (word-
                # split risk if the substitution ever yielded a multi-
                # token string). The flat var pattern is unambiguous.
                local cur_vers="${BACKEND_VERS:-3}"
                local v_3 v_30 v_302 v_311 v_21 v_20 v_10 v_def
                [[ "$cur_vers" == 3       ]] && v_3=ON   || v_3=OFF
                [[ "$cur_vers" == 3.0     ]] && v_30=ON  || v_30=OFF
                [[ "$cur_vers" == 3.0.2   ]] && v_302=ON || v_302=OFF
                [[ "$cur_vers" == 3.1.1   ]] && v_311=ON || v_311=OFF
                [[ "$cur_vers" == 2.1     ]] && v_21=ON  || v_21=OFF
                [[ "$cur_vers" == 2.0     ]] && v_20=ON  || v_20=OFF
                [[ "$cur_vers" == 1.0     ]] && v_10=ON  || v_10=OFF
                [[ "$cur_vers" == default ]] && v_def=ON || v_def=OFF
                local newvers
                newvers=$(whiptail --title "Edit share: $name — backend SMB version" \
                    --radiolist "${body_ctx}\n\nProtocol version to negotiate with the backend:" \
                    20 76 8 \
                    3       "SMB3 — auto-negotiate 3.0/3.1.1"          "$v_3"   \
                    3.0     "SMB3.0 only"                              "$v_30"  \
                    3.0.2   "SMB3.0.2 only"                            "$v_302" \
                    3.1.1   "SMB3.1.1 only"                            "$v_311" \
                    2.1     "SMB2.1 only"                              "$v_21"  \
                    2.0     "SMB2.0 only"                              "$v_20"  \
                    1.0     "SMB1 only"                                "$v_10"  \
                    default "Let cifs negotiate (no vers= token)"      "$v_def" \
                    3>&1 1>&2 2>&3) || continue
                BACKEND_VERS="$newvers"
                local p
                p=$(whiptail --title "Edit share: $name — confirm with password" \
                    --passwordbox "${body_ctx}\n\nRe-enter backend password to apply:" 12 64 \
                    3>&1 1>&2 2>&3) || continue
                BACKEND_PASS="$p"
                configure_share && info "Backend version updated for '$name' (vers=${BACKEND_VERS})." \
                    || info "configure_share failed (rc=$?)"
                BACKEND_PASS=""
                ;;
            8)
                if [[ "${PROFILE:-}" != "modern" ]]; then
                    info "Sealing is SMB3-only and not applicable to the legacy profile."
                    continue
                fi
                local cur_seal="${BACKEND_SEAL:-yes}"
                local s_yes s_no
                [[ "$cur_seal" == yes ]] && s_yes=ON || s_yes=OFF
                [[ "$cur_seal" == no  ]] && s_no=ON  || s_no=OFF
                local newseal
                newseal=$(whiptail --title "Edit share: $name — sealing" \
                    --radiolist "${body_ctx}\n\nSMB3 wire encryption (cifs 'seal' option):" \
                    14 70 2 \
                    yes "Encrypt backend traffic (recommended)" "$s_yes" \
                    no  "No encryption"                         "$s_no"  \
                    3>&1 1>&2 2>&3) || continue
                BACKEND_SEAL="$newseal"
                local p
                p=$(whiptail --title "Edit share: $name — confirm with password" \
                    --passwordbox "${body_ctx}\n\nRe-enter backend password to apply:" 12 64 \
                    3>&1 1>&2 2>&3) || continue
                BACKEND_PASS="$p"
                configure_share && info "Sealing updated for '$name' (seal=${BACKEND_SEAL})." \
                    || info "configure_share failed (rc=$?)"
                BACKEND_PASS=""
                ;;
            9)
                if [[ "${PROFILE:-}" != "modern" ]]; then
                    info "Locking override is fixed at tps-strict for the legacy profile.\nConvert this share to modern to choose a different override."
                    continue
                fi
                local cur_lock="${LOCKING_OVERRIDE:-}"
                local l_def l_relaxed l_strict
                [[ -z "$cur_lock"           ]] && l_def=ON     || l_def=OFF
                [[ "$cur_lock" == relaxed   ]] && l_relaxed=ON || l_relaxed=OFF
                [[ "$cur_lock" == tps-strict ]] && l_strict=ON || l_strict=OFF
                local newlock
                newlock=$(whiptail --title "Edit share: $name — locking" \
                    --radiolist "${body_ctx}\n\nLocking semantics on the published frontend:" \
                    16 76 3 \
                    profile-default "Relaxed (modern default)"           "$l_def"     \
                    relaxed         "Relaxed (explicit)"                 "$l_relaxed" \
                    tps-strict      "Strict — ISAM/.TPS multi-writer DB" "$l_strict"  \
                    3>&1 1>&2 2>&3) || continue
                LOCKING_OVERRIDE="$newlock"
                [[ "$LOCKING_OVERRIDE" == "profile-default" ]] && LOCKING_OVERRIDE=""
                local p
                p=$(whiptail --title "Edit share: $name — confirm with password" \
                    --passwordbox "${body_ctx}\n\nRe-enter backend password to apply:" 12 64 \
                    3>&1 1>&2 2>&3) || continue
                BACKEND_PASS="$p"
                configure_share && info "Locking updated for '$name'." \
                    || info "configure_share failed (rc=$?)"
                BACKEND_PASS=""
                ;;
            10)
                if [[ "${PROFILE:-}" != "$PROFILE_MODERN" ]]; then
                    info "Legacy ISAM shares must use direct mode.\nQueued replay would violate their live locking contract."
                    continue
                fi
                local cur_mode="${OFFLINE_MODE:-$OFFLINE_DIRECT}"
                local m_direct m_queued
                [[ "$cur_mode" == "$OFFLINE_DIRECT" ]] && m_direct=ON || m_direct=OFF
                [[ "$cur_mode" == "$OFFLINE_QUEUED" ]] && m_queued=ON || m_queued=OFF
                local newmode
                newmode=$(whiptail --title "Edit share: $name — offline behavior" \
                    --radiolist "${body_ctx}\n\nDirect serves the live machine share and fails fast offline.\nQueued serves the local data disk and deploys office changes\none-way whenever the machine returns." \
                    17 76 2 \
                    direct "Live backend; fail fast while offline" "$m_direct" \
                    queued "Always available; queue office deployments" "$m_queued" \
                    3>&1 1>&2 2>&3) || continue
                [[ "$newmode" != "$cur_mode" ]] || continue
                if [[ "$newmode" == "$OFFLINE_QUEUED" ]] && ! data_mount_ready; then
                    info "Queued mode requires the secondary data disk at\n${DATA_ROOT}.\nInitialize it under System Configuration first."
                    continue
                fi
                if [[ "$newmode" == "$OFFLINE_QUEUED" ]]; then
                    yesno "Switch '${name}' to queued mode?\n\nThe queued office-side folder starts empty; no files are pulled\nfrom the machine. Copy the office-authoritative program set to\nthe published share after switching." || continue
                else
                    yesno "Switch '${name}' to direct mode?\n\nThe published share will point at the live machine again.\nAny local queued data is retained on the data disk, but pending\nchanges will stop being delivered." || continue
                fi
                OFFLINE_MODE="$newmode"
                local p
                p=$(whiptail --title "Edit share: $name — confirm with password" \
                    --passwordbox "${body_ctx}\n\nRe-enter backend password to apply:" 12 64 \
                    3>&1 1>&2 2>&3) || { OFFLINE_MODE="$cur_mode"; continue; }
                BACKEND_PASS="$p"
                if configure_share; then
                    info "Offline behavior updated for '$name' (${OFFLINE_MODE})."
                else
                    local rc=$?
                    OFFLINE_MODE="$cur_mode"
                    info "configure_share failed (rc=$rc)"
                fi
                BACKEND_PASS=""
                ;;
            B|b) return ;;
        esac
    done
}

shares_remove_picker() {
    local name
    name=$(pick_share "Pick a share to REMOVE:") || return
    [[ -n "$name" ]] || return
    yesno "Remove share '${name}'?\n\nThis will:\n  - umount it (best-effort)\n  - strip its fstab line\n  - strip its [${name}] section from smb.conf\n  - delete its state, creds, and queued delivery manifest\n  - reload smbd\n\nBackend files are NOT touched. Any queued office-side files on\nthe appliance data disk are retained for manual recovery." \
        || return
    if remove_share "$name"; then
        info "Share '${name}' removed."
    else
        info "remove_share returned non-zero (rc=$?). Inspect /var/log/syslog."
    fi
}

shares_mount_picker() {
    local name
    name=$(pick_share "Pick a share to mount/unmount:") || return
    [[ -n "$name" ]] || return
    load_share "$name" || { info "Share '$name' state file missing."; return; }
    [[ -n "$BACKEND_MOUNT" ]] || { info "Share '$name' has no mount point set."; return; }

    if [[ "${PROFILE:-$PROFILE_LEGACY}" == "$PROFILE_LEGACY" ]]; then
        local session_count
        session_count=$(legacy_session_count "$name")
        if yesno "Share: ${name}\n\nLegacy mounts are session-managed and cannot be mounted persistently.\nActive upstream SMB1 sessions: ${session_count}\n\nRun a temporary credential/readability probe now?"; then
            local out=/tmp/smbproxy-session-probe.$$
            if "$SESSION_HELPER" probe "$name" >"$out" 2>&1; then
                info "Share '${name}' SMB1 credential probe succeeded."
            else
                whiptail --title "SMB1 probe failed: $name" --textbox "$out" 18 "$WT_WIDTH"
            fi
            rm -f "$out"
        fi
        return
    fi

    local body_ctx="Share: ${name}    mount: ${BACKEND_MOUNT}"
    local active="no"
    backend_mount_active "$BACKEND_MOUNT" 2>/dev/null && active="yes"

    local choice
    choice=$(whiptail --title "Mount: $name" \
        --menu "${body_ctx}\n  currently mounted: ${active}" \
        16 "$WT_WIDTH" 5 \
        "1" "Mount now" \
        "2" "Unmount now" \
        "3" "List share contents (read-only)" \
        "B" "Back" \
        3>&1 1>&2 2>&3) || return
    case "$choice" in
        1)
            if [[ "$active" == "yes" ]]; then info "Already mounted."; return; fi
            if mount "$BACKEND_MOUNT" 2>&1 | tee /tmp/smbproxy-mount.$$; then
                info "Mounted '$name' at ${BACKEND_MOUNT}."
            else
                whiptail --title "mount failed: $name" --textbox /tmp/smbproxy-mount.$$ 18 "$WT_WIDTH"
            fi
            rm -f /tmp/smbproxy-mount.$$
            ;;
        2)
            if [[ "$active" != "yes" ]]; then info "Not mounted."; return; fi
            if umount "$BACKEND_MOUNT" 2>&1 | tee /tmp/smbproxy-umount.$$; then
                info "Unmounted '$name'."
            else
                whiptail --title "umount failed: $name" --textbox /tmp/smbproxy-umount.$$ 18 "$WT_WIDTH"
            fi
            rm -f /tmp/smbproxy-umount.$$
            ;;
        3)
            if [[ "$active" != "yes" ]]; then
                if ! mount "$BACKEND_MOUNT"; then
                    info "Cannot mount '$name' — see system logs."
                    return
                fi
            fi
            local out=/tmp/smbproxy-ls.$$
            ls -lah "$BACKEND_MOUNT" 2>&1 | head -200 > "$out"
            whiptail --title "Share contents: $name (${BACKEND_MOUNT})" \
                --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
            rm -f "$out"
            ;;
    esac
}

menu_shares() {
    while true; do
        load_deploy
        local header; header="Shares: $(get_shares_status)"
        local choice
        choice=$(whiptail --title "Proxied Shares" \
            --menu "${header}" \
            "$WT_HEIGHT" "$WT_WIDTH" 10 \
            "1" "List shares (status)" \
            "2" "Add a new proxied share" \
            "3" "Edit an existing share" \
            "4" "Remove a share" \
            "5" "Mount / unmount a share / list contents" \
            "6" "Show smb.conf" \
            "7" "Run testparm -s" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) shares_list_status ;;
            2) shares_add_wizard ;;
            3) shares_edit_picker ;;
            4) shares_remove_picker ;;
            5) shares_mount_picker ;;
            6) show_smbconf ;;
            7) run_testparm ;;
            B|b) return ;;
        esac
    done
}

#===============================================================================
# 6. FIREWALL
#===============================================================================
menu_firewall() {
    while true; do
        local choice
        choice=$(whiptail --title "Firewall (nftables)" \
            --menu "Live ruleset: $([[ $(systemctl is-active nftables 2>/dev/null) == active ]] && echo active || echo inactive)" \
            $WT_HEIGHT $WT_WIDTH 6 \
            "1" "Render and install ruleset (uses NIC roles)" \
            "2" "Show live ruleset" \
            "3" "Disable nftables" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) install_firewall ;;
            2) show_firewall ;;
            3) disable_firewall ;;
            B|b) return ;;
        esac
    done
}

install_firewall() {
    load_roles
    if [[ -z "$DOMAIN_NIC_NAME" ]]; then
        info "Domain NIC role not assigned — go to NIC Roles first."
        return
    fi
    # Legacy NIC role is required only if at least one legacy-profile
    # share is configured (the legacy egress isolation depends on that
    # NIC). A modern-only proxy needs no legacy NIC.
    if any_legacy_profile_shares && [[ -z "$LEGACY_NIC_NAME" ]]; then
        info "A legacy-profile share is configured but no legacy NIC role assigned.\nAssign the legacy NIC first, or remove the legacy share."
        return
    fi
    if [[ ! -f "$NFT_TEMPLATE" ]]; then
        info "Template missing: $NFT_TEMPLATE"; return
    fi
    sed -e "s|%DOMAIN_IFACE%|$DOMAIN_NIC_NAME|g" \
        -e "s|%LEGACY_IFACE%|${LEGACY_NIC_NAME:-lo}|g" \
        "$NFT_TEMPLATE" > "$NFT_LIVE"
    chmod 0644 "$NFT_LIVE"
    if ! nft -c -f "$NFT_LIVE" 2>/tmp/smbproxy-nft.$$; then
        whiptail --title "nft -c failed" --textbox /tmp/smbproxy-nft.$$ 18 "$WT_WIDTH"
        rm -f /tmp/smbproxy-nft.$$
        return
    fi
    rm -f /tmp/smbproxy-nft.$$
    systemctl enable --now nftables
    nft -f "$NFT_LIVE"
    info "Firewall active. Rules constrain SMB3 listener to ${DOMAIN_NIC_NAME}; the legacy NIC accepts only ICMP + established/related."
}

show_firewall() {
    local full=/tmp/smbproxy-nft-full.$$
    local view=/tmp/smbproxy-nft-view.$$

    # Capture once, no streaming. nft itself is one-shot — `list ruleset`
    # emits the current ruleset and exits — so any "never stops" symptom
    # comes from below, not from nft.
    if ! nft list ruleset > "$full" 2>&1; then
        whiptail --title "nftables not loaded" --msgbox \
            "$(cat "$full")\n\n(use 'Render and install ruleset' first)" \
            14 "$WT_WIDTH"
        rm -f "$full"
        return
    fi

    # Suppress kernel console messages while the textbox is up. nftables
    # `log` rules can fire to /dev/console mid-display and look as if the
    # textbox is endlessly streaming text — the screen fills, you can't
    # tell where the textbox ended. printk level 3 keeps WARNING+ only,
    # which is rarely chatty. Restored on exit even if whiptail dies.
    local prev_printk
    prev_printk=$(awk '{print $1}' /proc/sys/kernel/printk 2>/dev/null)
    [[ -n "$prev_printk" ]] && echo 3 > /proc/sys/kernel/printk 2>/dev/null
    # shellcheck disable=SC2064
    trap "[[ -n '$prev_printk' ]] && echo $prev_printk > /proc/sys/kernel/printk 2>/dev/null; rm -f '$full' '$view'" RETURN

    # Cap the in-textbox view. Whiptail's --textbox can wedge or trash
    # the terminal on very large files (anecdotally over a few thousand
    # lines, with --scrolltext). Showing the head + a pointer to the
    # full file gives the operator the relevant 99% inline and an exit
    # path for the long tail.
    local total
    total=$(wc -l < "$full" 2>/dev/null | tr -d ' ')
    {
        echo "# Live nftables ruleset (first 200 lines of $total)"
        echo "# Full output saved to: $full  (run 'sudo less $full' on a separate session)"
        echo
        head -200 "$full"
        if [[ "${total:-0}" -gt 200 ]]; then
            echo
            echo "# ...output truncated at 200 lines, see $full for the rest..."
        fi
    } > "$view"

    # Run whiptail; if it exits non-zero (terminal too small, no curses,
    # binary garbled output), fall back to a pager so the operator
    # always gets something useful.
    if ! whiptail --title "Live nftables ruleset" --scrolltext \
            --textbox "$view" "$WT_HEIGHT" "$WT_WIDTH" 2>/dev/null; then
        clear 2>/dev/null || true
        echo "(whiptail textbox failed; falling back to less. Press 'q' to exit.)" >&2
        if command -v less >/dev/null 2>&1; then
            less -F -X "$view" || true
        else
            cat "$view"
            read -rp "press Enter to continue " _ </dev/tty
        fi
    fi
    # Note: trap RETURN handles cleanup including printk restore.
}

disable_firewall() {
    yesno "Disable nftables? The proxy will accept inbound on every port that has a listener — useful for debugging but NOT for production." || return
    systemctl disable --now nftables 2>/dev/null || true
    nft flush ruleset 2>/dev/null || true
    info "nftables stopped and flushed."
}

#===============================================================================
# 7. DIAGNOSTICS
#===============================================================================
menu_diagnostics() {
    while true; do
        local choice
        choice=$(whiptail --title "Diagnostics & Sanity Check" \
            --menu "Pick what to inspect." \
            $WT_HEIGHT $WT_WIDTH 8 \
            "1" "Identity (wbinfo -t / -u / -g)" \
            "2" "Backend reach (ping + TCP/445 + smbclient -L)" \
            "3" "Frontend reach (smbstatus + lsof on smbd)" \
            "4" "Time (chronyc tracking)" \
            "5" "Locks (smbstatus -L)" \
            "6" "Tail join log + smbd journal" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) diag_identity ;;
            2) diag_backend ;;
            3) diag_frontend ;;
            4) diag_time ;;
            5) diag_locks ;;
            6) diag_logs ;;
            B|b) return ;;
        esac
    done
}

diag_identity() {
    local out=/tmp/smbproxy-id.$$
    {
        echo "=== wbinfo -t ===";       wbinfo -t 2>&1
        echo
        echo "=== wbinfo -u | head ==="; wbinfo -u 2>&1 | head -30
        echo
        echo "=== wbinfo -g | head ==="; wbinfo -g 2>&1 | head -30
        echo
        echo "=== getent passwd <DOMAIN_SHORT>\\Administrator ==="
        load_deploy
        if [[ -n "$DOMAIN_SHORT" ]]; then
            getent passwd "${DOMAIN_SHORT}\\Administrator" 2>&1 || true
        fi
    } > "$out"
    whiptail --title "Identity" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
    rm -f "$out"
}

diag_backend() {
    local name
    name=$(pick_share "Pick a share to diagnose its backend:") || return
    [[ -n "$name" ]] || { info "No proxied shares configured."; return; }
    load_share "$name" || { info "Share '$name' state file missing."; return; }
    local creds; creds=$(share_creds_file "$name")
    local out=/tmp/smbproxy-be.$$
    {
        echo "=== Share: $name ==="
        echo "    backend: //${BACKEND_IP}/${name}"
        echo "    mount:   ${BACKEND_MOUNT}"
        echo "    creds:   ${creds}"
        echo
        echo "=== ping ${BACKEND_IP} ==="
        ping -c 2 -W 2 "$BACKEND_IP" 2>&1
        echo
        echo "=== TCP/445 to ${BACKEND_IP} ==="
        timeout 3 bash -c "</dev/tcp/${BACKEND_IP}/445" 2>&1 && echo "open" || echo "445 not reachable"
        echo
        echo "=== smbclient -L //${BACKEND_IP} -A ${creds} -m SMB1 ==="
        smbclient -L "//${BACKEND_IP}" -A "${creds}" -m SMB1 2>&1 | head -40 || true
        echo
        echo "=== mount status ==="
        if [[ "${PROFILE:-$PROFILE_LEGACY}" == "$PROFILE_LEGACY" ]]; then
            echo "SESSION-MANAGED: $(legacy_session_count "$name") active upstream SMB1 session(s)"
            awk -v root="$SESSION_ROOT/" '$2 ~ "^"root && $3=="cifs" {print}' /proc/mounts 2>/dev/null
            echo
            echo "Run: sudo smbproxy-session-mount probe '$name'"
        elif backend_mount_active "${BACKEND_MOUNT:-/dev/null}"; then
            echo "MOUNTED at $BACKEND_MOUNT"
            ls "$BACKEND_MOUNT" 2>&1 | head -5
        else
            echo "NOT MOUNTED"
        fi
    } > "$out"
    whiptail --title "Backend diag — $name" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
    rm -f "$out"
}

diag_frontend() {
    local out=/tmp/smbproxy-fe.$$
    {
        echo "=== smbstatus -b ==="
        smbstatus -b 2>&1 | head -30
        echo
        echo "=== smbstatus -S ==="
        smbstatus -S 2>&1 | head -30
        echo
        echo "=== ss -ltn (445 listeners) ==="
        ss -ltn '( sport = :445 )' 2>&1
    } > "$out"
    whiptail --title "Frontend diag" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
    rm -f "$out"
}

diag_time() {
    local out=/tmp/smbproxy-time.$$
    {
        echo "=== chronyc tracking ===";  chronyc tracking 2>&1
        echo
        echo "=== chronyc sources ===";  chronyc sources 2>&1
        echo
        echo "=== timedatectl ===";       timedatectl 2>&1
    } > "$out"
    whiptail --title "Time diag" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
    rm -f "$out"
}

diag_locks() {
    local out=/tmp/smbproxy-locks.$$
    {
        echo "=== frontend Samba lock table ==="
        smbstatus -L 2>&1
        echo
        echo "=== active upstream SMB1 session mounts ==="
        awk -v root="$SESSION_ROOT/" '$2 ~ "^"root && $3=="cifs" {print}' /proc/mounts 2>/dev/null
        echo
        echo "=== session lifecycle (tail) ==="
        tail -80 /var/log/smbproxy-session-mount.log 2>/dev/null || echo "(no sessions recorded yet)"
    } > "$out"
    whiptail --title "Lock and SMB1 session state" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
    rm -f "$out"
}

diag_logs() {
    local out=/tmp/smbproxy-logs.$$
    {
        echo "=== /var/log/smbproxy-join.log (tail) ==="
        tail -60 /var/log/smbproxy-join.log 2>/dev/null || echo "(no join log yet)"
        echo
        echo "=== journalctl -u smbd (last 60) ==="
        journalctl -u smbd -n 60 --no-pager 2>&1 | tail -60
        echo
        echo "=== journalctl -u winbind (last 30) ==="
        journalctl -u winbind -n 30 --no-pager 2>&1 | tail -30
    } > "$out"
    whiptail --title "Logs" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
    rm -f "$out"
}

#===============================================================================
# 8. SERVICE MANAGEMENT
#===============================================================================
menu_services() {
    while true; do
        local choice
        choice=$(whiptail --title "Service Management" \
            --menu "smbd: $(get_smbd_status)   winbind: $(get_winbind_status)" \
            $WT_HEIGHT $WT_WIDTH 8 \
            "1" "Restart smbd" \
            "2" "Restart winbind" \
            "3" "Restart both" \
            "4" "Stop smbd" \
            "5" "Stop winbind" \
            "6" "Show systemctl status (smbd, winbind, chrony)" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) systemctl restart smbd; info "smbd restarted." ;;
            2) systemctl restart winbind; info "winbind restarted." ;;
            3) systemctl restart winbind smbd; info "both restarted." ;;
            4) systemctl stop smbd; info "smbd stopped." ;;
            5) systemctl stop winbind; info "winbind stopped." ;;
            6) show_svc_status ;;
            B|b) return ;;
        esac
    done
}

show_svc_status() {
    local out=/tmp/smbproxy-svc.$$
    {
        for svc in smbd winbind chrony chronyd nftables; do
            echo "=== $svc ==="
            systemctl status "$svc" --no-pager 2>&1 | head -10
            echo
        done
    } > "$out"
    whiptail --title "Service status" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
    rm -f "$out"
}

#===============================================================================
# 9. POWER
#===============================================================================
menu_power() {
    local choice
    choice=$(whiptail --title "Reboot / Shutdown" \
        --menu "Pick a power action." 14 60 4 \
        "1" "Reboot" \
        "2" "Shutdown" \
        "B" "Back" \
        3>&1 1>&2 2>&3) || return
    case "$choice" in
        1) yesno "Reboot now?" && systemctl reboot ;;
        2) yesno "Shut down now?" && systemctl poweroff ;;
    esac
}

#===============================================================================
# HEADLESS CLI
#===============================================================================
print_help() {
    cat <<HLP
$SCRIPT_NAME v$VERSION

Usage:
  sudo smbproxy-sconfig                        Interactive whiptail TUI.

  sudo smbproxy-sconfig --status               Print summary + per-share state, exit 0.

  sudo smbproxy-sconfig --join-domain \\
        --realm REALM --short SHORT --dc DC \\
        --user AD_USER [--pass-stdin]
        Headless join. Reads the AD admin password from stdin.

  sudo smbproxy-sconfig --list-shares
        Print one SHARE_NAME per line.

  sudo smbproxy-sconfig --configure-share \\
        --name SHARE_NAME \\
        [--profile legacy|modern] \\
        [--offline-mode direct|queued] \\
        --backend-ip IP --backend-user USER --backend-domain NETBIOS \\
        [--mount /mnt/.../X] \\
        [--group "DOM\\Group"] [--force-user engineering_user] \\
        [--backend-vers 1.0|2.0|2.1|3|3.0|3.0.2|3.1.1|default]  (modern only) \\
        [--backend-seal | --no-backend-seal]   (modern only) \\
        [--locking profile-default|tps-strict|relaxed] \\
        [--pass-stdin]
        Headless add or update of a single share. SHARE_NAME is used at
        BOTH ends (backend share name AND published SMB3 share name).
        Reads the backend user password from stdin.

        --profile picks the cifs / smb.conf preset:
          legacy (default) — one vers=1.0 session mount per downstream
            authenticated tree, cache=none, lock forwarding enabled,
            TPS-strict locking. Requires the legacy NIC role (the
            backend is assumed to live on the air-gapped LegacyZone
            subnet). Use this for the ISAM-style (e.g. Clarion .TPS) workload.
          modern — vers=3 (auto-negotiate 3.0/3.1.1) + relaxed locking
            + optional SMB3 sealing (--backend-seal / --no-backend-seal,
            default on). No legacy NIC required; backend is reached via
            the domain LAN. Use this for standalone modern devices
            (CNC, NAS, IoT) consolidated under DFS-N.

        --offline-mode is independent from the protocol profile:
          direct (default) — publish the live backend mount and fail
            new connections quickly while the backend is offline.
          queued — publish the local data-disk copy at all times and
            deliver office-managed changes one-way when the backend
            returns. Modern profile only. Machine-only files are never
            imported or deleted.

        --locking overrides the profile's locking stanza. profile-default
        (the default) picks tps-strict for legacy and relaxed for modern.

        --backend-vers overrides the modern profile's default vers=3.
        Use when the device only speaks SMB1/SMB2 (HMI panels, older
        NAS, embedded SMB stacks). seal is auto-suppressed for
        non-SMB3 versions since it's part of the SMB3 wire format.
        Legacy profile is fixed at vers=1.0 — override is rejected.

        --mount defaults to /mnt/legacy/<safe-name> for legacy and
        /mnt/backend/<safe-name> for modern. Legacy uses that value only
        as an administrative label; client I/O uses session mounts under
        $SESSION_ROOT. --force-user defaults to --backend-user. --group is
        REQUIRED to publish the smb.conf section.

  sudo smbproxy-sconfig --init-data-disk \\
        --device /dev/sdX --yes-really-erase
        ERASE and format one attached whole disk as the queued-share
        ext4 data filesystem at $DATA_ROOT.

  sudo smbproxy-sconfig --grow-data-disk
        Grow the mounted ext4 filesystem after expanding its virtual disk.

  sudo smbproxy-sconfig --remove-share --name SHARE_NAME
        Tear down one share: close/unmount active sessions, strip fstab line, strip
        smb.conf section, delete state + creds files, reload smbd.
        For a queued share, the delivery manifest is removed while
        office-side files are retained for recovery. Idempotent
        against partial state.

  sudo smbproxy-sconfig --check-share --name SHARE_NAME
        Read-only diagnostic for one share. Reports state file fields,
        creds file perms, static or session-mount strategy, the option
        list the current profile would emit, live /proc/mounts options,
        backend TCP/445 reachability, and identity resolution
        (force_user / force_group are non-numeric usernames matching
        FRONT_FORCE_USER's local /etc/passwd entry; valid_users SID
        resolves via wbinfo). Safe to run during production traffic — no
        mutation, no service restart. Exit codes:
            0 — all good
            1 — drift or identity-resolution problem
            2 — backend unreachable (overlay over any other status)
            3 — no such share

  sudo smbproxy-sconfig --apply-firewall
        Render the nftables template using current NIC roles and load
        it into the kernel.

  sudo smbproxy-sconfig --version
HLP
}

cli_status() {
    load_roles
    load_deploy
    cat <<EOF
hostname:        $(get_fqdn)
domain_nic:      ${DOMAIN_NIC_NAME:-?}  mac=${DOMAIN_NIC_MAC:-?}
legacy_nic:      ${LEGACY_NIC_NAME:-?}  mac=${LEGACY_NIC_MAC:-?}
realm:           $(get_realm_status)
joined:          $(is_joined && echo yes || echo no)
smbd:            $(get_smbd_status)
winbind:         $(get_winbind_status)
data_disk:       $(data_mount_ready && df -h "$DATA_ROOT" 2>/dev/null | awk 'NR==2 {print "mounted (" $2 " total, " $4 " free)"}' || echo "not mounted")
EOF
    local names; names=$(list_shares 2>/dev/null)
    if [[ -z "$names" ]]; then
        echo "shares:          (none configured)"
    else
        echo "shares:"
        local n
        while IFS= read -r n; do
            load_share "$n" 2>/dev/null
            local active="no"
            if [[ "${PROFILE:-$PROFILE_LEGACY}" == "$PROFILE_LEGACY" ]]; then
                active="sessions=$(legacy_session_count "$n")"
            else
                backend_mount_active "${BACKEND_MOUNT:-/dev/null}" 2>/dev/null && active="yes"
            fi
            local has_section="no"
            share_section_present "$n" && has_section="yes"
            printf '  - %s\n' "$n"
            printf '      profile:        %s%s\n' "${PROFILE:-$PROFILE_LEGACY}" \
                "$([[ -n "${BACKEND_VERS:-}" ]] && printf ' (vers=%s)' "$BACKEND_VERS")"
            printf '      offline_mode:   %s\n' "${OFFLINE_MODE:-$OFFLINE_DIRECT}"
            printf '      backend:        //%s/%s\n' "${BACKEND_IP:-?}" "$n"
            printf '      mount:          %s  (active=%s)\n' "${BACKEND_MOUNT:-?}" "$active"
            printf '      frontend_path:  %s\n' \
                "$(share_frontend_path "$n" "${OFFLINE_MODE:-$OFFLINE_DIRECT}" "${BACKEND_MOUNT:-}" "$DATA_ROOT" "${PROFILE:-$PROFILE_LEGACY}")"
            printf '      ad_group:       %s\n' "${FRONT_GROUP:-(unset)}"
            printf '      force_user:     %s\n' "${FRONT_FORCE_USER:-?}"
            printf '      smb_section:    %s\n' "$has_section"
        done <<< "$names"
    fi
}

# Argument parsers for the headless modes.
cli_join_domain() {
    REALM="" DOMAIN_SHORT="" DC_HOST="" AD_USER="" PASS_STDIN=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --realm)       REALM="$2"; shift 2 ;;
            --short)       DOMAIN_SHORT="${2^^}"; shift 2 ;;
            --dc)          DC_HOST="$2"; shift 2 ;;
            --user)        AD_USER="$2"; shift 2 ;;
            --pass-stdin)  PASS_STDIN=1; shift ;;
            *) echo "unknown flag: $1" >&2; return 2 ;;
        esac
    done
    [[ -n "$REALM" && -n "$DOMAIN_SHORT" && -n "$DC_HOST" && -n "$AD_USER" ]] \
        || { echo "missing required flag" >&2; return 2; }
    if [[ "$PASS_STDIN" -eq 1 ]]; then
        IFS= read -r AD_PASS
    else
        echo "Password (will not echo): " >&2
        read -rs AD_PASS; echo >&2
    fi
    do_domain_join
    local rc=$?
    AD_PASS=""; unset AD_PASS
    return $rc
}

cli_list_shares() {
    list_shares
}

cli_configure_share() {
    SHARE_NAME=""
    BACKEND_IP="" BACKEND_USER="" BACKEND_DOMAIN="" BACKEND_MOUNT=""
    FRONT_GROUP="" FRONT_FORCE_USER=""
    PROFILE="" OFFLINE_MODE="" BACKEND_SEAL="" LOCKING_OVERRIDE="" BACKEND_VERS=""
    local PASS_STDIN=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name)             SHARE_NAME="$2"; shift 2 ;;
            --profile)          PROFILE="$2"; shift 2 ;;
            --offline-mode)     OFFLINE_MODE="$2"; shift 2 ;;
            --backend-ip)       BACKEND_IP="$2"; shift 2 ;;
            --backend-user)     BACKEND_USER="$2"; shift 2 ;;
            --backend-domain)   BACKEND_DOMAIN="$2"; shift 2 ;;
            --backend-vers)     BACKEND_VERS="$2"; shift 2 ;;
            --backend-seal)     BACKEND_SEAL="yes"; shift ;;
            --no-backend-seal)  BACKEND_SEAL="no"; shift ;;
            --mount)            BACKEND_MOUNT="$2"; shift 2 ;;
            --group)            FRONT_GROUP="$2"; shift 2 ;;
            --force-user)       FRONT_FORCE_USER="$2"; shift 2 ;;
            --locking)          LOCKING_OVERRIDE="$2"; shift 2 ;;
            --pass-stdin)       PASS_STDIN=1; shift ;;
            *) echo "unknown flag: $1" >&2; return 2 ;;
        esac
    done

    [[ -n "$SHARE_NAME" && -n "$BACKEND_IP" && -n "$BACKEND_USER" \
        && -n "$BACKEND_DOMAIN" ]] \
        || { echo "missing required flag (--name --backend-ip --backend-user --backend-domain)" >&2; return 2; }

    # Same validation as the TUI add-wizard. share_name_validate
    # rejects names with shell metas / whitespace; the collision
    # check rejects names that would overwrite an existing share's
    # on-disk state file via safe-name aliasing (e.g. `A-B` vs `A_B`).
    share_name_validate "$SHARE_NAME" || return 2
    local _peer
    if _peer=$(share_safe_name_collides_with_existing "$SHARE_NAME"); then
        echo "share name '$SHARE_NAME' would collide with existing share '$_peer' on disk (both encode to the same state-file name)" >&2
        return 2
    fi

    # Defaults. PROFILE defaults to legacy for backward compat.
    PROFILE="${PROFILE:-$PROFILE_LEGACY}"
    case "$PROFILE" in
        "$PROFILE_LEGACY"|"$PROFILE_MODERN") : ;;
        *) echo "invalid --profile '$PROFILE' (expected: $PROFILE_LEGACY|$PROFILE_MODERN)" >&2; return 2 ;;
    esac
    OFFLINE_MODE="${OFFLINE_MODE:-$OFFLINE_DIRECT}"
    if ! offline_mode_validate "$PROFILE" "$OFFLINE_MODE"; then
        echo "invalid --offline-mode '$OFFLINE_MODE'; queued is supported only with --profile modern" >&2
        return 2
    fi
    if [[ -n "$BACKEND_SEAL" && "$PROFILE" != "$PROFILE_MODERN" ]]; then
        echo "--backend-seal/--no-backend-seal only applies to --profile modern" >&2
        return 2
    fi
    if [[ -n "$BACKEND_VERS" ]]; then
        if [[ "$PROFILE" != "$PROFILE_MODERN" ]]; then
            echo "--backend-vers only applies to --profile modern (legacy is fixed at vers=1.0)" >&2
            return 2
        fi
        case "$BACKEND_VERS" in
            1.0|2.0|2.1|3|3.0|3.0.2|3.1.1|default) : ;;
            *) echo "invalid --backend-vers '$BACKEND_VERS' (expected: 1.0|2.0|2.1|3|3.0|3.0.2|3.1.1|default)" >&2; return 2 ;;
        esac
    fi
    [[ -n "$BACKEND_MOUNT"      ]] || BACKEND_MOUNT=$(share_default_mount "$SHARE_NAME" "$PROFILE")
    [[ -n "$FRONT_FORCE_USER"   ]] || FRONT_FORCE_USER="$BACKEND_USER"

    if [[ "$PASS_STDIN" -eq 1 ]]; then
        IFS= read -r BACKEND_PASS
    else
        echo "Password (will not echo): " >&2
        read -rs BACKEND_PASS; echo >&2
    fi
    [[ -n "$BACKEND_PASS" ]] || { echo "empty password" >&2; return 2; }

    configure_share
    local rc=$?
    BACKEND_PASS=""; unset BACKEND_PASS
    return $rc
}

cli_init_data_disk() {
    local device="" confirmed=0
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --device)           device="$2"; shift 2 ;;
            --yes-really-erase) confirmed=1; shift ;;
            *) echo "unknown flag: $1" >&2; return 2 ;;
        esac
    done
    [[ -n "$device" ]] || { echo "missing --device" >&2; return 2; }
    [[ "$confirmed" -eq 1 ]] || {
        echo "refusing to erase $device without --yes-really-erase" >&2
        return 2
    }
    initialize_data_disk "$device"
}

cli_remove_share() {
    local name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            *) echo "unknown flag: $1" >&2; return 2 ;;
        esac
    done
    [[ -n "$name" ]] || { echo "missing --name" >&2; return 2; }
    remove_share "$name"
}

cli_check_share() {
    local name=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --name) name="$2"; shift 2 ;;
            *) echo "unknown flag: $1" >&2; return 2 ;;
        esac
    done
    [[ -n "$name" ]] || { echo "missing --name" >&2; return 2; }
    check_share "$name"
}

cli_apply_firewall() {
    load_roles
    [[ -n "$DOMAIN_NIC_NAME" ]] \
        || { echo "domain NIC role not assigned" >&2; return 2; }
    if any_legacy_profile_shares && [[ -z "$LEGACY_NIC_NAME" ]]; then
        echo "legacy-profile share configured but no legacy NIC role assigned" >&2
        return 2
    fi
    sed -e "s|%DOMAIN_IFACE%|$DOMAIN_NIC_NAME|g" \
        -e "s|%LEGACY_IFACE%|${LEGACY_NIC_NAME:-lo}|g" \
        "$NFT_TEMPLATE" > "$NFT_LIVE"
    chmod 0644 "$NFT_LIVE"
    nft -c -f "$NFT_LIVE" || return 3
    systemctl enable --now nftables
    nft -f "$NFT_LIVE"
}

main_cli() {
    case "${1:-}" in
        --help|-h)             print_help ;;
        --version|-V)          echo "$SCRIPT_NAME $VERSION" ;;
        --status)              cli_status ;;
        --join-domain)         shift; cli_join_domain "$@" ;;
        --list-shares)         cli_list_shares ;;
        --configure-share)     shift; cli_configure_share "$@" ;;
        --init-data-disk)      shift; cli_init_data_disk "$@" ;;
        --grow-data-disk)      shift; [[ $# -eq 0 ]] || { echo "unexpected arguments" >&2; return 2; }; grow_data_disk ;;
        --remove-share)        shift; cli_remove_share "$@" ;;
        --check-share)         shift; cli_check_share "$@" ;;
        --apply-firewall)      cli_apply_firewall ;;
        *) echo "unknown subcommand: ${1:-}" >&2; print_help; return 2 ;;
    esac
}

#===============================================================================
# ENTRY POINT
#===============================================================================
# Library mode: when the file is sourced (not executed), skip the entry
# point so unit tests can call individual helpers without triggering
# check_root or main_menu. The standard bash sourced-vs-executed check.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    check_root

    if [[ $# -gt 0 ]]; then
        main_cli "$@"
        exit $?
    fi

    main_menu
fi
