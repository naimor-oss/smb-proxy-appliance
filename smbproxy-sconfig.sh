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
#     depends on realm, DC, WS2008 host, share name, or backend creds, set
#     it here.
#   - Read AGENTS.md before changing the locking semantics. The frontend
#     share is deliberately strict-locking + oplocks-off and the backend
#     cifs mount is deliberately nobrl + cache=none. Those two together
#     concentrate all locking at the proxy, which is what makes multi-user
#     .TPS files work over an SMB1 backend.
#===============================================================================
set -uo pipefail

readonly VERSION="0.1.0"
readonly SCRIPT_NAME="smbproxy-sconfig"
readonly WT_HEIGHT=22
readonly WT_WIDTH=78
readonly WT_MENU_HEIGHT=14

readonly ROLES_FILE="/etc/smbproxy/nic-roles.env"
readonly STATE_DIR="/var/lib/smbproxy"
readonly DEPLOY_FILE="${STATE_DIR}/deploy.env"
readonly SHARES_DIR="${STATE_DIR}/shares"
readonly CREDS_DIR="/etc/samba"
readonly CREDS_PREFIX=".creds-"
readonly SMB_CONF="/etc/samba/smb.conf"
readonly KRB5_CONF="/etc/krb5.conf"
readonly NFT_TEMPLATE="/etc/nftables-smbproxy.conf"
readonly NFT_LIVE="/etc/nftables.conf"

# Transitional during the multi-share refactor: the old singleton creds
# path. Existing TUI / CLI / diagnostics call sites still reference
# $CREDS_FILE; B2 / B3 migrate them to share_creds_file() and this
# constant goes away.
readonly CREDS_FILE="${CREDS_DIR}/.legacy_creds"

#===============================================================================
# UTILITIES
#===============================================================================
die()  { whiptail --msgbox "FATAL: $*" 10 60; exit 1; }
info() { whiptail --msgbox "$*" 12 64; }
yesno(){ whiptail --yesno "$*" 10 60; }

check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "ERROR: Run as root (sudo smbproxy-sconfig)." >&2
        exit 1
    fi
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
    # Domain-level state. Per-share state lives under $SHARES_DIR; see
    # load_share() below.
    REALM="" DOMAIN_SHORT="" DC_HOST="" DC_IP=""
    # Transitional singletons — kept zero-initialized so the as-yet-
    # unmigrated TUI / CLI call sites referencing $BACKEND_IP, etc.
    # don't trip `set -u`. Removed in B2 / B3 once those call sites
    # are migrated to load_share() / save_share().
    BACKEND_IP="" BACKEND_SHARE="" BACKEND_USER="" BACKEND_DOMAIN=""
    BACKEND_MOUNT="" FRONT_SHARE="" FRONT_GROUP="" FRONT_FORCE_USER=""
    if [[ -f "$DEPLOY_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$DEPLOY_FILE"
    fi
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
#   - one cifs entry in /etc/fstab keyed by the per-share BACKEND_MOUNT.
#   - one [SHARE_NAME] section in $SMB_CONF.
#
# By convention SHARE_NAME is used as both the WS2008 backend share name
# AND the published SMB3 frontend share name (per the user's deployment
# model — operator picks one name and it appears at both ends).
# <safe> is the SHARE_NAME with non-alphanumeric characters replaced by
# underscore, so a $-bearing share like "ProfitFab$" stores as
# ProfitFab_.env / .creds-ProfitFab_ on the filesystem while the literal
# name lives in SHARE_NAME.
#-------------------------------------------------------------------------------

share_safe_name() {
    # Sanitize SHARE_NAME for use in filesystem paths. Idempotent —
    # already-sanitized names pass through unchanged.
    echo "${1//[^A-Za-z0-9_]/_}"
}

share_state_file() {
    echo "${SHARES_DIR}/$(share_safe_name "$1").env"
}

share_creds_file() {
    echo "${CREDS_DIR}/${CREDS_PREFIX}$(share_safe_name "$1")"
}

share_default_mount() {
    echo "/mnt/legacy/$(share_safe_name "$1")"
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
load_share() {
    local name="$1"
    SHARE_NAME="" BACKEND_IP="" BACKEND_USER="" BACKEND_DOMAIN=""
    BACKEND_MOUNT="" FRONT_GROUP="" FRONT_FORCE_USER=""
    local f
    f=$(share_state_file "$name")
    [[ -f "$f" ]] || return 1
    # shellcheck disable=SC1090
    source "$f"
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
BACKEND_IP="${BACKEND_IP:-}"
BACKEND_USER="${BACKEND_USER:-}"
BACKEND_DOMAIN="${BACKEND_DOMAIN:-}"
BACKEND_MOUNT="${BACKEND_MOUNT:-}"
FRONT_GROUP="${FRONT_GROUP:-}"
FRONT_FORCE_USER="${FRONT_FORCE_USER:-}"
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
    local mount_path
    if load_share "$name" 2>/dev/null && [[ -n "$BACKEND_MOUNT" ]]; then
        mount_path="$BACKEND_MOUNT"
        if backend_mount_active "$mount_path" 2>/dev/null; then
            umount "$mount_path" 2>/dev/null || true
        fi
        # Strip fstab line for this mount point.
        sed -i "\| ${mount_path} cifs |d" /etc/fstab 2>/dev/null || true
    fi

    # Strip the [SHARE_NAME] section from smb.conf, if present and
    # smb.conf exists.
    if [[ -f "$SMB_CONF" ]]; then
        awk -v sname="[$name]" '
            BEGIN { in_share=0 }
            $0 == sname { in_share=1; next }
            /^\[/ && in_share { in_share=0 }
            !in_share { print }
        ' "$SMB_CONF" > "${SMB_CONF}.new" && mv "${SMB_CONF}.new" "$SMB_CONF"
        chmod 0644 "$SMB_CONF" 2>/dev/null || true
    fi

    rm -f "$(share_state_file "$name")"
    rm -f "$(share_creds_file "$name")"
    systemctl daemon-reload 2>/dev/null || true
    if systemctl is-active --quiet smbd 2>/dev/null; then
        systemctl reload smbd 2>/dev/null || systemctl restart smbd 2>/dev/null || true
    fi
    return 0
}

save_deploy() {
    mkdir -p "$STATE_DIR"
    cat > "$DEPLOY_FILE" <<EOF
# Generated by smbproxy-sconfig. Safe to edit by hand if you know why.
# Credentials live in $CREDS_FILE (mode 600), not here.
REALM="${REALM:-}"
DOMAIN_SHORT="${DOMAIN_SHORT:-}"
DC_HOST="${DC_HOST:-}"
DC_IP="${DC_IP:-}"
BACKEND_IP="${BACKEND_IP:-}"
BACKEND_SHARE="${BACKEND_SHARE:-}"
BACKEND_USER="${BACKEND_USER:-}"
BACKEND_DOMAIN="${BACKEND_DOMAIN:-}"
BACKEND_MOUNT="${BACKEND_MOUNT:-}"
FRONT_SHARE="${FRONT_SHARE:-}"
FRONT_GROUP="${FRONT_GROUP:-}"
FRONT_FORCE_USER="${FRONT_FORCE_USER:-}"
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
    mountpoint -q "$mp"
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

get_backend_status() {
    load_deploy
    if [[ -z "$BACKEND_MOUNT" ]]; then
        echo "(unconfigured)"
        return
    fi
    if backend_mount_active "$BACKEND_MOUNT"; then
        echo "mounted at $BACKEND_MOUNT"
    else
        echo "configured, not mounted"
    fi
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
            "B" "Back to Main Menu" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) config_hostname ;;
            2) config_timezone ;;
            3) run_updates_now ;;
            4) show_system_info ;;
            B|b) return ;;
        esac
    done
}

config_hostname() {
    local cur new
    cur=$(get_fqdn)
    new=$(whiptail --inputbox \
        "Enter the FQDN for this server.\n\nRules:\n- Short name max 15 characters (NetBIOS limit)\n- Use a real domain you control or .lan\n- NEVER use .local (mDNS conflict)\n\nCurrent: $cur" \
        14 64 "$cur" 3>&1 1>&2 2>&3) || return
    [[ -z "$new" ]] && return
    if [[ "$new" != *.* ]]; then
        info "ERROR: Must be a FQDN (e.g., smbproxy-1.example.lan)."; return
    fi
    if [[ "$new" == *.local ]]; then
        info "ERROR: .local conflicts with mDNS/Bonjour."; return
    fi
    local short="${new%%.*}"
    if [[ ${#short} -gt 15 ]]; then
        info "ERROR: Short name '$short' exceeds 15 chars."; return
    fi
    hostnamectl set-hostname "$new"
    echo "$new" > /etc/hostname
    sed -i "/\s${cur}\b/d" /etc/hosts 2>/dev/null || true
    info "Hostname set to: $new\nShort: $short\n\nReboot recommended after the join is complete."
}

config_timezone() {
    local cur new
    cur=$(timedatectl show --property=Timezone --value 2>/dev/null || echo Etc/UTC)
    new=$(whiptail --inputbox \
        "Region/City. Examples:\n  America/Los_Angeles  Europe/London  Asia/Tokyo  Etc/UTC\n\nCurrent: $cur" \
        14 64 "$cur" 3>&1 1>&2 2>&3) || return
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
    echo "[sconfig] apt update..."
    apt-get update
    echo "[sconfig] apt full-upgrade..."
    echo "[sconfig]   note: full-upgrade can install new dependencies"
    echo "[sconfig]   (e.g. new kernel packages). Plain 'apt-get upgrade'"
    echo "[sconfig]   would silently keep them back."
    echo
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y
    echo
    echo "=============================================================="
    if [[ -f /var/run/reboot-required ]]; then
        echo "  REBOOT REQUIRED — a kernel or library that's currently"
        echo "  loaded was upgraded. Run 'sudo reboot' to apply."
    else
        echo "  Done. No reboot required."
    fi
    echo "=============================================================="
    echo "  Press Enter to continue."
    read -r _
}

show_system_info() {
    {
        echo "=== Identity ==="
        echo "Host:    $(hostname -f)"
        echo "Realm:   $(get_realm_status)"
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
        for n in $(ls -1 /sys/class/net | grep -v '^lo$'); do
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
    for n in $(ls -1 /sys/class/net | grep -v '^lo$'); do
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
        --menu "Assigning the LEGACY NIC (LegacyZone, gateway-less).\n\nPick the interface that connects to the WS2008 SP2 backend." \
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
    local realm dc
    realm=$(whiptail --inputbox "AD realm (e.g. example.com):" 10 64 "${REALM:-}" 3>&1 1>&2 2>&3) || return
    dc=$(whiptail --inputbox "DC hostname or IP (e.g. dc1.example.com or 10.0.0.10):" 10 70 "${DC_HOST:-}" 3>&1 1>&2 2>&3) || return
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

    # 4. chrony — point at the DC and wait briefly for sync. Kerberos is
    #    intolerant of clock skew (>5 minutes by default).
    cat > /etc/chrony/chrony.conf <<EOF
# Managed by smbproxy-sconfig. Time source is the AD DC for the joined
# realm. Adjust /etc/chrony/sources.d/ if you need additional sources.
server ${DC_IP} iburst prefer
driftfile /var/lib/chrony/drift
makestep 1.0 3
EOF
    systemctl restart chrony 2>/dev/null || systemctl restart chronyd 2>/dev/null || true
    chronyc -a 'burst 4/4' >/dev/null 2>&1 || true
    chronyc -a makestep   >/dev/null 2>&1 || true
    sleep 2

    # 5. smb.conf — write a minimal [global] only. Shares are added later
    #    by configure_frontend_share. Locking-strict stanza is applied
    #    when the share is added.
    cat > "$SMB_CONF" <<EOF
[global]
    workgroup = ${DOMAIN_SHORT}
    realm = ${realm_uc}
    security = ads
    netbios name = $(hostname -s | tr '[:lower:]' '[:upper:]' | cut -c1-15)

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
    if is_joined; then
        if ! whiptail --yesno "This host appears to be joined already.\n\nRe-running the join will overwrite smb.conf, krb5.conf, chrony.conf, and resolv.conf. Continue?" 12 64; then
            return
        fi
    fi
    REALM=$(whiptail --inputbox "AD realm (e.g. example.com):" 10 64 "${REALM:-}" 3>&1 1>&2 2>&3) || return
    DOMAIN_SHORT=$(whiptail --inputbox "NetBIOS short domain name (pre-Win2000):" 10 64 "${DOMAIN_SHORT:-${REALM%%.*}}" 3>&1 1>&2 2>&3) || return
    DOMAIN_SHORT="${DOMAIN_SHORT^^}"
    DC_HOST=$(whiptail --inputbox "DC hostname or IP:" 10 64 "${DC_HOST:-}" 3>&1 1>&2 2>&3) || return
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
    if ! net ads leave -U "${user}%${pass}" 2>&1 | tee /tmp/smbproxy-leave.log; then
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
# 4. BACKEND SMB1 MOUNT (WS2008)
#===============================================================================
menu_backend() {
    while true; do
        load_deploy
        local choice
        choice=$(whiptail --title "Backend SMB1 Mount" \
            --menu "Backend: ${BACKEND_IP:-(unset)}/${BACKEND_SHARE:-?}\nMount:   ${BACKEND_MOUNT:-(unset)}\nStatus:  $(get_backend_status)" \
            $WT_HEIGHT $WT_WIDTH 8 \
            "1" "Configure backend (IP, share, user, password, NetBIOS domain)" \
            "2" "Mount now" \
            "3" "Unmount now" \
            "4" "Show share contents (read-only listing)" \
            "5" "Show fstab entry + creds-file owner/mode" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) configure_backend_tui ;;
            2) mount_backend ;;
            3) umount_backend ;;
            4) list_backend ;;
            5) show_backend_files ;;
            B|b) return ;;
        esac
    done
}

# Headless: relies on globals BACKEND_IP, BACKEND_SHARE, BACKEND_USER,
# BACKEND_PASS, BACKEND_DOMAIN, BACKEND_MOUNT.
configure_backend() {
    [[ -n "$BACKEND_IP" && -n "$BACKEND_SHARE" && -n "$BACKEND_USER" \
        && -n "${BACKEND_PASS:-}" && -n "$BACKEND_DOMAIN" && -n "$BACKEND_MOUNT" ]] \
        || return 2

    # Make sure the local backend force-user exists. Defaults to a name
    # derived from the share name; the frontend share step lets the
    # operator override.
    if [[ -n "$FRONT_FORCE_USER" ]] && ! id "$FRONT_FORCE_USER" &>/dev/null; then
        useradd -M -s /usr/sbin/nologin "$FRONT_FORCE_USER"
    fi

    install -d -o root -g root -m 0755 "$(dirname "$BACKEND_MOUNT")"
    install -d -o "${FRONT_FORCE_USER:-root}" -g "${FRONT_FORCE_USER:-root}" -m 0755 "$BACKEND_MOUNT" 2>/dev/null \
        || install -d -m 0755 "$BACKEND_MOUNT"

    # Write creds file (mode 600). NEVER log this file's contents.
    install -d -o root -g root -m 0755 /etc/samba
    umask 077
    cat > "$CREDS_FILE" <<EOF
username=${BACKEND_USER}
password=${BACKEND_PASS}
domain=${BACKEND_DOMAIN}
EOF
    chmod 0600 "$CREDS_FILE"
    chown root:root "$CREDS_FILE"
    umask 022

    # fstab entry. The cifs kernel module honors vers=1.0 independent of
    # Samba's `client min protocol`. Locking is deliberately disabled at
    # the mount layer (`nobrl`) so all locking is enforced at the Samba
    # share — see AGENTS.md for the rationale.
    local force_user_uid force_user_gid
    if [[ -n "$FRONT_FORCE_USER" ]] && id "$FRONT_FORCE_USER" &>/dev/null; then
        force_user_uid=$(id -u "$FRONT_FORCE_USER")
        force_user_gid=$(id -g "$FRONT_FORCE_USER")
    else
        force_user_uid=0
        force_user_gid=0
    fi

    local fstab_line="//${BACKEND_IP}/${BACKEND_SHARE} ${BACKEND_MOUNT} cifs credentials=${CREDS_FILE},vers=1.0,cache=none,serverino,nobrl,uid=${force_user_uid},gid=${force_user_gid},file_mode=0660,dir_mode=0770,_netdev,x-systemd.automount,x-systemd.requires=network-online.target 0 0"

    # Replace any prior line for the same mount point.
    sed -i "\| ${BACKEND_MOUNT} cifs |d" /etc/fstab
    echo "$fstab_line" >> /etc/fstab

    systemctl daemon-reload
    save_deploy
    return 0
}

configure_backend_tui() {
    load_deploy
    BACKEND_IP=$(whiptail --inputbox "WS2008 backend IPv4 (LegacyZone-side):" 10 64 "${BACKEND_IP:-}" 3>&1 1>&2 2>&3) || return
    BACKEND_SHARE=$(whiptail --inputbox "Share name on the WS2008 host (e.g. ProfitFab\$):" 10 64 "${BACKEND_SHARE:-}" 3>&1 1>&2 2>&3) || return
    BACKEND_USER=$(whiptail --inputbox "Local WS2008 user with read/write access:" 10 64 "${BACKEND_USER:-}" 3>&1 1>&2 2>&3) || return
    BACKEND_DOMAIN=$(whiptail --inputbox "WS2008 NetBIOS domain (or workgroup) name:" 10 64 "${BACKEND_DOMAIN:-LEGACY}" 3>&1 1>&2 2>&3) || return
    local p1 p2
    p1=$(whiptail --passwordbox "Password for ${BACKEND_USER}:" 10 64 3>&1 1>&2 2>&3) || return
    p2=$(whiptail --passwordbox "Confirm password:" 10 64 3>&1 1>&2 2>&3) || return
    [[ "$p1" == "$p2" ]] || { info "Passwords don't match."; return; }
    BACKEND_PASS="$p1"

    local default_mount
    default_mount="/mnt/legacy/${BACKEND_SHARE//[^A-Za-z0-9_]/_}"
    BACKEND_MOUNT=$(whiptail --inputbox "Local mount point:" 10 64 "${BACKEND_MOUNT:-$default_mount}" 3>&1 1>&2 2>&3) || return

    # The local force-user owns the cifs mount (via the uid/gid mount
    # options) AND is the 'force user' on the frontend Samba share. AD
    # identities authenticated to the frontend are mapped to this single
    # local account on the way out to SMB1. Default to the backend
    # user's name; override only if you have a reason.
    FRONT_FORCE_USER=$(whiptail --inputbox \
        "Local backend force-user.\n\nThis Linux account owns the cifs mount (uid/gid options) and is the\n'force user' on the frontend Samba share. All AD identities authenticated\nto the frontend are mapped to this single account when talking to WS2008.\n\nThe wizard creates the account if it doesn't exist (system user, nologin)." \
        16 76 "${FRONT_FORCE_USER:-${BACKEND_USER}}" 3>&1 1>&2 2>&3) || return

    yesno "Write creds + fstab for:\n  //${BACKEND_IP}/${BACKEND_SHARE} -> ${BACKEND_MOUNT}\nWS2008 user: ${BACKEND_DOMAIN}\\${BACKEND_USER}\nLocal force-user: ${FRONT_FORCE_USER}\n\nfstab options: vers=1.0,nobrl,cache=none,serverino,x-systemd.automount" || return

    if configure_backend; then
        BACKEND_PASS=""; unset BACKEND_PASS
        info "Backend configured.\n\nUse 'Mount now' from this menu, or simply access ${BACKEND_MOUNT} — automount will trigger."
    else
        BACKEND_PASS=""; unset BACKEND_PASS
        info "configure_backend failed (missing params or mkdir error)."
    fi
}

mount_backend() {
    load_deploy
    [[ -n "$BACKEND_MOUNT" ]] || { info "Backend not configured."; return; }
    if backend_mount_active "$BACKEND_MOUNT"; then
        info "Already mounted."; return
    fi
    if mount "$BACKEND_MOUNT" 2>&1 | tee /tmp/smbproxy-mount.$$; then
        info "Mounted at ${BACKEND_MOUNT}."
    else
        whiptail --title "mount failed" --textbox /tmp/smbproxy-mount.$$ 18 "$WT_WIDTH"
    fi
    rm -f /tmp/smbproxy-mount.$$
}

umount_backend() {
    load_deploy
    [[ -n "$BACKEND_MOUNT" ]] || { info "Backend not configured."; return; }
    if ! backend_mount_active "$BACKEND_MOUNT"; then
        info "Not mounted."; return
    fi
    if umount "$BACKEND_MOUNT" 2>&1 | tee /tmp/smbproxy-umount.$$; then
        info "Unmounted."
    else
        whiptail --title "umount failed" --textbox /tmp/smbproxy-umount.$$ 18 "$WT_WIDTH"
    fi
    rm -f /tmp/smbproxy-umount.$$
}

list_backend() {
    load_deploy
    [[ -n "$BACKEND_MOUNT" ]] || { info "Backend not configured."; return; }
    if ! backend_mount_active "$BACKEND_MOUNT"; then
        if ! mount "$BACKEND_MOUNT"; then
            info "Cannot mount $BACKEND_MOUNT — see system logs."; return
        fi
    fi
    local out=/tmp/smbproxy-ls.$$
    ls -lah "$BACKEND_MOUNT" 2>&1 | head -200 > "$out"
    whiptail --title "$BACKEND_MOUNT" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
    rm -f "$out"
}

show_backend_files() {
    load_deploy
    local out=/tmp/smbproxy-be-files.$$
    {
        echo "=== /etc/fstab (cifs entries) ==="
        grep cifs /etc/fstab 2>/dev/null || echo "(none)"
        echo
        echo "=== Credentials file ==="
        ls -l "$CREDS_FILE" 2>/dev/null || echo "(missing)"
        echo "(contents are intentionally not displayed here)"
        echo
        echo "=== Mount status ==="
        mount | grep -E "$(printf '%s' "${BACKEND_MOUNT:-NONEXISTENT}")" || echo "(not mounted)"
    } > "$out"
    whiptail --title "Backend files" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
    rm -f "$out"
}

#===============================================================================
# 5. FRONTEND SMB3 SHARE
#===============================================================================
menu_frontend() {
    while true; do
        load_deploy
        local choice
        choice=$(whiptail --title "Frontend SMB3 Share" \
            --menu "Share name : ${FRONT_SHARE:-(unset)}\nMount path : ${BACKEND_MOUNT:-(unset)}\nAccess group: ${FRONT_GROUP:-(unset)}\nForce user : ${FRONT_FORCE_USER:-(unset)}" \
            $WT_HEIGHT $WT_WIDTH 8 \
            "1" "Configure frontend share (writes smb.conf, restarts smbd)" \
            "2" "Show smb.conf" \
            "3" "Run testparm -s" \
            "B" "Back" \
            3>&1 1>&2 2>&3) || return
        case "$choice" in
            1) configure_frontend_tui ;;
            2) show_smbconf ;;
            3) run_testparm ;;
            B|b) return ;;
        esac
    done
}

configure_frontend() {
    [[ -n "$FRONT_SHARE" && -n "$BACKEND_MOUNT" && -n "$FRONT_GROUP" && -n "$FRONT_FORCE_USER" ]] \
        || return 2
    is_joined || return 3

    if ! id "$FRONT_FORCE_USER" &>/dev/null; then
        useradd -M -s /usr/sbin/nologin "$FRONT_FORCE_USER"
    fi
    if ! getent group "$FRONT_FORCE_USER" >/dev/null 2>&1; then
        groupadd "$FRONT_FORCE_USER" 2>/dev/null || true
    fi

    # Strip any previous occurrence of the share, then append the fresh
    # block. Safer than sed with line-range deletion.
    awk -v sname="[$FRONT_SHARE]" '
        BEGIN { in_share=0 }
        $0 == sname { in_share=1; next }
        /^\[/ && in_share { in_share=0 }
        !in_share { print }
    ' "$SMB_CONF" > "${SMB_CONF}.new"

    cat >> "${SMB_CONF}.new" <<EOF

[${FRONT_SHARE}]
    path = ${BACKEND_MOUNT}
    read only = no
    guest ok = no
    valid users = @"${FRONT_GROUP}"

    # Map all incoming AD identities to the local backend force-user.
    # That user's credentials are what the kernel cifs mount uses to
    # authenticate to the WS2008 host. AD-side ACLs are enforced by
    # 'valid users'; the WS2008-side ACL is enforced by what the
    # backend user is allowed to read/write on the share.
    force user = ${FRONT_FORCE_USER}
    force group = ${FRONT_FORCE_USER}

    # Strict locking for ISAM/.TPS multi-user databases. The proxy is
    # the single arbiter of locking; do NOT relax these without reading
    # AGENTS.md first.
    oplocks = no
    level2 oplocks = no
    strict locking = yes
    kernel oplocks = no
    posix locking = yes
EOF

    if ! testparm -s "${SMB_CONF}.new" >/dev/null 2>/tmp/smbproxy-tp.$$; then
        rm -f "${SMB_CONF}.new"
        return 4
    fi
    mv "${SMB_CONF}.new" "$SMB_CONF"
    chmod 0644 "$SMB_CONF"

    systemctl restart smbd
    save_deploy
    return 0
}

configure_frontend_tui() {
    load_deploy
    if ! is_joined; then
        info "Join an AD domain first (Domain Operations menu)."; return
    fi
    if [[ -z "$BACKEND_MOUNT" ]]; then
        info "Configure the backend mount first."; return
    fi
    FRONT_SHARE=$(whiptail --inputbox \
        "Frontend SMB3 share name (what AD clients see). Trailing \$ marks it hidden in network browsing.\n\nExample: ProfitFab\$" \
        12 70 "${FRONT_SHARE:-${BACKEND_SHARE:-}}" 3>&1 1>&2 2>&3) || return
    FRONT_GROUP=$(whiptail --inputbox \
        "AD security group authorized to use this share.\n\nFormat: DOMAIN_SHORT\\Group Name (e.g. NAIMOR\\ProfitFab Users).\nThe @\"\" wrapper around it in smb.conf is added automatically." \
        13 70 "${FRONT_GROUP:-${DOMAIN_SHORT:-DOMAIN}\\Users}" 3>&1 1>&2 2>&3) || return
    FRONT_FORCE_USER=$(whiptail --inputbox \
        "Local backend force-user.\n\nThis is the local Linux account whose credentials sit in $CREDS_FILE and connect to the WS2008 backend. All AD identities authenticated to the frontend share are mapped to this single account on the way out to SMB1." \
        14 74 "${FRONT_FORCE_USER:-${BACKEND_USER:-pfuser}}" 3>&1 1>&2 2>&3) || return

    yesno "Write share [$FRONT_SHARE] -> $BACKEND_MOUNT\nvalid users = @\"$FRONT_GROUP\"\nforce user/group = $FRONT_FORCE_USER\n\nThis restarts smbd. Proceed?" || return

    if configure_frontend; then
        info "Frontend share is live.\n\nFrom an AD-joined Windows 11:\n  \\\\$(hostname -s)\\$FRONT_SHARE"
    else
        info "configure_frontend failed.\nLikely causes: not joined yet, missing backend mount, or testparm rejected the config (see /tmp/smbproxy-tp.*)"
    fi
}

show_smbconf() {
    if [[ -f "$SMB_CONF" ]]; then
        whiptail --title "$SMB_CONF" --scrolltext --textbox "$SMB_CONF" "$WT_HEIGHT" "$WT_WIDTH"
    else
        info "No smb.conf yet."
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
# This section supersedes the singleton §4 / §5 menus for the TUI. The
# operator now manages an arbitrary number of proxied shares from one
# place — each share has its own backend creds, mount, fstab line,
# smb.conf section, AD access group, and local force-user (per the
# multi-share data model in load_share / save_share above).
#
# §4 / §5 functions are retained because the headless CLI dispatcher
# still calls configure_backend / configure_frontend; B3 retires those
# call paths, after which §4 / §5 can be deleted entirely.
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
        if [[ -n "$BACKEND_MOUNT" ]] && backend_mount_active "$BACKEND_MOUNT" 2>/dev/null; then
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
                printf '  backend:        //%s/%s\n' "${BACKEND_IP:-?}" "$n"
                printf '  backend user:   %s (domain: %s)\n' \
                    "${BACKEND_USER:-?}" "${BACKEND_DOMAIN:-?}"
                printf '  mount point:    %s' "${BACKEND_MOUNT:-?}"
                if backend_mount_active "${BACKEND_MOUNT:-/dev/null}" 2>/dev/null; then
                    printf '  [mounted]\n'
                else
                    printf '  [unmounted]\n'
                fi
                printf '  AD access:      %s\n' "${FRONT_GROUP:-?}"
                printf '  force user:     %s\n' "${FRONT_FORCE_USER:-?}"
                if grep -qE "^\[$n\]" "$SMB_CONF" 2>/dev/null; then
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
#   - per-share fstab line (replacing any prior with same mount point)
#   - per-share smb.conf section (replacing any prior [SHARE_NAME])
#   - per-share env file via save_share()
# Frontend pieces are skipped if not domain-joined (the operator can
# add the share's backend pre-join and publish the frontend later).
# BACKEND_PASS is consumed and then unset — never persisted to disk.
# Returns 0 on success, 2 on missing required fields, 4 on testparm
# rejection.
configure_share() {
    [[ -n "$SHARE_NAME" && -n "$BACKEND_IP" && -n "$BACKEND_USER" \
        && -n "${BACKEND_PASS:-}" && -n "$BACKEND_DOMAIN" \
        && -n "$BACKEND_MOUNT" && -n "$FRONT_FORCE_USER" ]] \
        || return 2

    # Local backend force-user must exist before we set the cifs
    # uid/gid mount options against it.
    if ! id "$FRONT_FORCE_USER" &>/dev/null; then
        useradd -M -s /usr/sbin/nologin "$FRONT_FORCE_USER"
    fi
    if ! getent group "$FRONT_FORCE_USER" >/dev/null 2>&1; then
        groupadd "$FRONT_FORCE_USER" 2>/dev/null || true
    fi

    install -d -o root -g root -m 0755 "$(dirname "$BACKEND_MOUNT")"
    install -d -o "$FRONT_FORCE_USER" -g "$FRONT_FORCE_USER" -m 0755 \
        "$BACKEND_MOUNT" 2>/dev/null \
        || install -d -m 0755 "$BACKEND_MOUNT"

    # Per-share creds file. NEVER log this file's contents.
    local creds; creds=$(share_creds_file "$SHARE_NAME")
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

    # fstab entry — see configure_backend (legacy) for the rationale on
    # vers=1.0 / nobrl / cache=none / x-systemd.automount.
    local fu_uid fu_gid
    fu_uid=$(id -u "$FRONT_FORCE_USER")
    fu_gid=$(id -g "$FRONT_FORCE_USER")
    local fstab_line="//${BACKEND_IP}/${SHARE_NAME} ${BACKEND_MOUNT} cifs credentials=${creds},vers=1.0,cache=none,serverino,nobrl,uid=${fu_uid},gid=${fu_gid},file_mode=0660,dir_mode=0770,_netdev,x-systemd.automount,x-systemd.requires=network-online.target 0 0"
    sed -i "\| ${BACKEND_MOUNT} cifs |d" /etc/fstab
    echo "$fstab_line" >> /etc/fstab
    systemctl daemon-reload

    # Frontend smb.conf section — only if domain-joined and FRONT_GROUP
    # is set. Operator can add a share's backend before joining and
    # publish the frontend afterward.
    if is_joined && [[ -n "$FRONT_GROUP" ]]; then
        # Strip any prior [SHARE_NAME] section, then append fresh.
        awk -v sname="[$SHARE_NAME]" '
            BEGIN { in_share=0 }
            $0 == sname { in_share=1; next }
            /^\[/ && in_share { in_share=0 }
            !in_share { print }
        ' "$SMB_CONF" > "${SMB_CONF}.new"

        cat >> "${SMB_CONF}.new" <<EOF

[${SHARE_NAME}]
    path = ${BACKEND_MOUNT}
    read only = no
    guest ok = no
    valid users = @"${FRONT_GROUP}"

    # All AD identities authenticated to this share are mapped to
    # ${FRONT_FORCE_USER}, whose creds in ${creds} authenticate the
    # cifs mount to the WS2008 backend.
    force user = ${FRONT_FORCE_USER}
    force group = ${FRONT_FORCE_USER}

    # Strict locking for ISAM/.TPS multi-user databases; do NOT relax
    # without reading AGENTS.md first.
    oplocks = no
    level2 oplocks = no
    strict locking = yes
    kernel oplocks = no
    posix locking = yes
EOF

        if ! testparm -s "${SMB_CONF}.new" >/dev/null 2>/tmp/smbproxy-tp.$$; then
            rm -f "${SMB_CONF}.new"
            return 4
        fi
        mv "${SMB_CONF}.new" "$SMB_CONF"
        chmod 0644 "$SMB_CONF"
        systemctl reload smbd 2>/dev/null || systemctl restart smbd
    fi

    # Persist non-credential fields (BACKEND_PASS is intentionally
    # NOT in this list; save_share() doesn't touch creds).
    save_share

    BACKEND_PASS=""; unset BACKEND_PASS
    return 0
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
            --inputbox "Choose the share's name.\n\nThis is BOTH the WS2008 backend share name AND the published\nSMB3 share name (operator picks one; it appears at both ends).\nTrailing \$ marks it hidden in network browsing.\n\nExample: ProfitFab\$" \
            16 70 "" 3>&1 1>&2 2>&3) || return
        [[ -n "$SHARE_NAME" ]] || { info "Share name cannot be empty."; continue; }
        # Reject characters that aren't share-name-safe on Windows or
        # that would break smb.conf section parsing.
        if [[ "$SHARE_NAME" =~ [/\\\[\]\"\'\<\>] ]]; then
            info "Share name contains characters not allowed in SMB share names\n(/, \\\\, [, ], <, >, quotes)."
            continue
        fi
        if echo "$existing_names" | grep -qFx "$SHARE_NAME"; then
            info "A share named '$SHARE_NAME' already exists.\nUse Edit to change it, Remove to delete it first."
            continue
        fi
        break
    done

    local body_ctx="Share: ${SHARE_NAME}"
    local BACKEND_IP="" BACKEND_USER="" BACKEND_DOMAIN="" BACKEND_MOUNT=""
    local BACKEND_PASS="" FRONT_GROUP="" FRONT_FORCE_USER=""

    BACKEND_IP=$(whiptail --title "Add proxied share — backend IP" \
        --inputbox "${body_ctx}\n\nWS2008 backend IPv4 (LegacyZone-side):" \
        12 64 "" 3>&1 1>&2 2>&3) || return

    # Note: same BACKEND_IP with a different SHARE_NAME is the
    # *intended* multi-share case (multiple shares from one backend
    # with independent creds), so we DON'T warn on (IP, SHARE_NAME)
    # combinations. Same SHARE_NAME couldn't get here — we rejected
    # duplicate names above. The only meaningful collision worth
    # warning on is mount-path overlap, which we check after BACKEND_MOUNT
    # is collected below.

    BACKEND_USER=$(whiptail --title "Add proxied share — backend user" \
        --inputbox "${body_ctx}\n\nLocal WS2008 user with read/write access on the share:" \
        12 64 "" 3>&1 1>&2 2>&3) || return
    BACKEND_DOMAIN=$(whiptail --title "Add proxied share — backend domain" \
        --inputbox "${body_ctx}\n\nWS2008 NetBIOS domain (or workgroup) name:" \
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

    BACKEND_MOUNT=$(whiptail --title "Add proxied share — local mount point" \
        --inputbox "${body_ctx}\n\nLocal mount point on the proxy:" \
        12 64 "$(share_default_mount "$SHARE_NAME")" 3>&1 1>&2 2>&3) || { BACKEND_PASS=""; return; }

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
        FRONT_GROUP=$(whiptail --title "Add proxied share — AD access group" \
            --inputbox "${body_ctx}\n\nAD security group authorized to use this share.\nFormat: DOMAIN_SHORT\\Group Name (e.g. ${DOMAIN_SHORT:-LAB}\\${SHARE_NAME%\$} Users).\nThe @\"\" wrapper in smb.conf is added automatically." \
            14 74 "${DOMAIN_SHORT:-DOMAIN}\\${SHARE_NAME%\$} Users" 3>&1 1>&2 2>&3) || { BACKEND_PASS=""; return; }
    else
        info "Not domain-joined — backend will be configured but the\nfrontend [smb.conf] section is skipped. Re-run Edit after\njoining the domain to publish the share."
    fi

    FRONT_FORCE_USER=$(whiptail --title "Add proxied share — local force-user" \
        --inputbox "${body_ctx}\n\nLocal Linux account that owns the cifs mount AND that AD\nidentities authenticated to this share are mapped to on the\nway out to WS2008. Created if absent (system user, nologin)." \
        14 74 "${BACKEND_USER}" 3>&1 1>&2 2>&3) || { BACKEND_PASS=""; return; }

    yesno "Apply share '${SHARE_NAME}'?\n\n  backend://${BACKEND_IP}/${SHARE_NAME} -> ${BACKEND_MOUNT}\n  WS2008 user: ${BACKEND_DOMAIN}\\${BACKEND_USER}\n  AD access:   ${FRONT_GROUP:-(skipped — not joined)}\n  force user:  ${FRONT_FORCE_USER}" \
        || { BACKEND_PASS=""; return; }

    if configure_share; then
        info "Share '${SHARE_NAME}' configured.\n\nUse 'Mount / unmount a share' to mount it, or just access\n${BACKEND_MOUNT} — automount triggers."
    else
        local rc=$?
        info "configure_share failed (rc=$rc).\n  rc=2: missing required field\n  rc=4: testparm rejected the smb.conf — see /tmp/smbproxy-tp.*"
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
        local choice
        choice=$(whiptail --title "Edit share: $name" \
            --menu "${body_ctx}\n\n  backend://${BACKEND_IP:-?}/${name} -> ${BACKEND_MOUNT:-?}\n  AD group: ${FRONT_GROUP:-(unset)}\n  force user: ${FRONT_FORCE_USER:-?}\n\nPick a field to update:" \
            "$WT_HEIGHT" "$WT_WIDTH" 8 \
            "1" "Backend password (most common edit)" \
            "2" "AD access group (FRONT_GROUP)" \
            "3" "Local force-user (FRONT_FORCE_USER)" \
            "4" "Backend IP (BACKEND_IP)" \
            "5" "Backend user (BACKEND_USER)" \
            "6" "Backend domain (BACKEND_DOMAIN)" \
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
                FRONT_GROUP=$(whiptail --title "Edit share: $name — AD group" \
                    --inputbox "${body_ctx}\n\nAD security group authorized:" 12 70 \
                    "$FRONT_GROUP" 3>&1 1>&2 2>&3) || continue
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
                    --inputbox "${body_ctx}\n\nWS2008 backend IPv4:" 12 64 \
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
                    --inputbox "${body_ctx}\n\nWS2008 user with r/w access:" 12 64 \
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
                    --inputbox "${body_ctx}\n\nWS2008 NetBIOS domain or workgroup:" 12 64 \
                    "$BACKEND_DOMAIN" 3>&1 1>&2 2>&3) || continue
                local p
                p=$(whiptail --title "Edit share: $name — confirm with password" \
                    --passwordbox "${body_ctx}\n\nRe-enter backend password to apply:" 12 64 \
                    3>&1 1>&2 2>&3) || continue
                BACKEND_PASS="$p"
                configure_share && info "Backend domain updated for '$name'." || info "configure_share failed (rc=$?)"
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
    yesno "Remove share '${name}'?\n\nThis will:\n  - umount it (best-effort)\n  - strip its fstab line\n  - strip its [${name}] section from smb.conf\n  - delete its state file and creds file\n  - reload smbd\n\nThe operator-side data on the WS2008 backend is NOT touched." \
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
    if [[ -z "$DOMAIN_NIC_NAME" || -z "$LEGACY_NIC_NAME" ]]; then
        info "NIC roles not assigned — go to NIC Roles first."
        return
    fi
    if [[ ! -f "$NFT_TEMPLATE" ]]; then
        info "Template missing: $NFT_TEMPLATE"; return
    fi
    sed -e "s|%DOMAIN_IFACE%|$DOMAIN_NIC_NAME|g" \
        -e "s|%LEGACY_IFACE%|$LEGACY_NIC_NAME|g" \
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
    load_deploy
    [[ -n "$BACKEND_IP" ]] || { info "Backend not configured."; return; }
    local out=/tmp/smbproxy-be.$$
    {
        echo "=== ping ${BACKEND_IP} ==="
        ping -c 2 -W 2 "$BACKEND_IP" 2>&1
        echo
        echo "=== TCP/445 to ${BACKEND_IP} ==="
        timeout 3 bash -c "</dev/tcp/${BACKEND_IP}/445" 2>&1 && echo "open" || echo "445 not reachable"
        echo
        echo "=== smbclient -L //${BACKEND_IP} -A $CREDS_FILE -m SMB1 ==="
        smbclient -L "//${BACKEND_IP}" -A "$CREDS_FILE" -m SMB1 2>&1 | head -40 || true
        echo
        echo "=== mount status ==="
        if backend_mount_active "${BACKEND_MOUNT:-/dev/null}"; then
            echo "MOUNTED at $BACKEND_MOUNT"
            ls "$BACKEND_MOUNT" 2>&1 | head -5
        else
            echo "NOT MOUNTED"
        fi
    } > "$out"
    whiptail --title "Backend diag" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
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
    smbstatus -L 2>&1 > "$out"
    whiptail --title "smbstatus -L" --scrolltext --textbox "$out" "$WT_HEIGHT" "$WT_WIDTH"
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

  sudo smbproxy-sconfig --status               Print summary, exit 0.

  sudo smbproxy-sconfig --join-domain \\
        --realm REALM --short SHORT --dc DC \\
        --user AD_USER [--pass-stdin]
        Headless join. Reads the AD admin password from stdin.

  sudo smbproxy-sconfig --configure-backend \\
        --ip IP --share NAME --user USER --domain NETBIOS \\
        --mount /mnt/legacy/foo [--force-user pfuser] [--pass-stdin]
        Headless backend configuration. Reads the WS2008 user password
        from stdin. --force-user defaults to --user if not set.

  sudo smbproxy-sconfig --configure-frontend \\
        --share-name NAME --group "DOM\\Group" --force-user pfuser
        Headless frontend share. Requires backend already configured
        and the host already AD-joined.

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
backend_mount:   ${BACKEND_MOUNT:-(unset)}
backend_active:  $(backend_mount_active "${BACKEND_MOUNT:-/dev/null}" && echo yes || echo no)
frontend_share:  ${FRONT_SHARE:-(unset)}
smbd:            $(get_smbd_status)
winbind:         $(get_winbind_status)
EOF
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

cli_configure_backend() {
    BACKEND_IP="" BACKEND_SHARE="" BACKEND_USER="" BACKEND_DOMAIN=""
    BACKEND_MOUNT="" PASS_STDIN=0
    load_deploy   # carry over FRONT_FORCE_USER if set
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --ip)          BACKEND_IP="$2"; shift 2 ;;
            --share)       BACKEND_SHARE="$2"; shift 2 ;;
            --user)        BACKEND_USER="$2"; shift 2 ;;
            --domain)      BACKEND_DOMAIN="$2"; shift 2 ;;
            --mount)       BACKEND_MOUNT="$2"; shift 2 ;;
            --force-user)  FRONT_FORCE_USER="$2"; shift 2 ;;
            --pass-stdin)  PASS_STDIN=1; shift ;;
            *) echo "unknown flag: $1" >&2; return 2 ;;
        esac
    done
    [[ -n "$BACKEND_IP" && -n "$BACKEND_SHARE" && -n "$BACKEND_USER" \
        && -n "$BACKEND_DOMAIN" && -n "$BACKEND_MOUNT" ]] \
        || { echo "missing required flag" >&2; return 2; }
    # Default the local force-user to the backend username if not set.
    [[ -n "${FRONT_FORCE_USER:-}" ]] || FRONT_FORCE_USER="$BACKEND_USER"
    if [[ "$PASS_STDIN" -eq 1 ]]; then
        IFS= read -r BACKEND_PASS
    else
        echo "Password (will not echo): " >&2
        read -rs BACKEND_PASS; echo >&2
    fi
    configure_backend
    local rc=$?
    BACKEND_PASS=""; unset BACKEND_PASS
    return $rc
}

cli_configure_frontend() {
    load_deploy
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --share-name)  FRONT_SHARE="$2"; shift 2 ;;
            --group)       FRONT_GROUP="$2"; shift 2 ;;
            --force-user)  FRONT_FORCE_USER="$2"; shift 2 ;;
            *) echo "unknown flag: $1" >&2; return 2 ;;
        esac
    done
    [[ -n "$FRONT_SHARE" && -n "$FRONT_GROUP" && -n "$FRONT_FORCE_USER" ]] \
        || { echo "missing required flag" >&2; return 2; }
    configure_frontend
}

cli_apply_firewall() {
    load_roles
    [[ -n "$DOMAIN_NIC_NAME" && -n "$LEGACY_NIC_NAME" ]] \
        || { echo "NIC roles not assigned" >&2; return 2; }
    sed -e "s|%DOMAIN_IFACE%|$DOMAIN_NIC_NAME|g" \
        -e "s|%LEGACY_IFACE%|$LEGACY_NIC_NAME|g" \
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
        --configure-backend)   shift; cli_configure_backend "$@" ;;
        --configure-frontend)  shift; cli_configure_frontend "$@" ;;
        --apply-firewall)      cli_apply_firewall ;;
        *) echo "unknown subcommand: ${1:-}" >&2; print_help; return 2 ;;
    esac
}

#===============================================================================
# ENTRY POINT
#===============================================================================
check_root

if [[ $# -gt 0 ]]; then
    main_cli "$@"
    exit $?
fi

main_menu
