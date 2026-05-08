#!/usr/bin/env bash
#===============================================================================
# prepare-image.sh — SMB1↔SMB3 Proxy Appliance Image Preparation
#
# Run ONCE on a fresh Debian 13 (Trixie) minimal install to:
#   - Remove unnecessary packages (spell check, X11, laptop detection, etc.)
#   - Install Samba (member-server only), Winbind, Kerberos, cifs-utils,
#     chrony, nftables, and tooling
#   - Conditionally install VM guest agents (QEMU, VMware, Hyper-V)
#   - Pre-configure skeleton files for smbproxy-sconfig deployment
#   - Install the unattended-upgrades framework (policy set by sconfig)
#   - Install smbproxy-firstboot.service (host-integration, NIC detection)
#   - Install smbproxy-init TTY1 console wizard (incl. NIC role assignment)
#
# After running, snapshot the VM. Use smbproxy-sconfig for per-deployment
# configuration: realm, DC IP, backend IP/share/credentials, frontend
# share name and AD access group, etc.
#
# Design rule: this script prepares an image, but it does not decide the
# domain or the backend. Anything that depends on the eventual realm, DC,
# legacy backend, share, or credentials belongs in smbproxy-sconfig.sh. That
# is why files such as krb5.conf and chrony.conf are skeletons here, why
# /etc/samba/smb.conf is removed entirely, and why no /etc/samba/.*creds
# file is ever created in this script.
#
# Usage: sudo bash prepare-image.sh
#===============================================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[+]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; }

if [[ $EUID -ne 0 ]]; then
    err "This script must be run as root."
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive

#===============================================================================
# 0. REFRESH APT INDEXES
#===============================================================================
# Debian cloud images ship with /var/lib/apt/lists/ cleaned to keep the image
# small. Without an `apt-get update` first, any subsequent `apt-get install`
# of a package that wasn't in the build-time index — for example the
# hyperv-daemons install in section 2 — fails with "Unable to locate
# package".
log "Refreshing apt indexes..."
apt-get update -y

#===============================================================================
# 1. REMOVE UNNECESSARY PACKAGES
#===============================================================================
# This is a special-purpose SMB protocol-version proxy: Kerberos, Winbind,
# SMB (server + cifs client), and chrony. Administration is SSH plus
# smbproxy-sconfig. The package purge below removes general-purpose Debian
# extras that add attack surface, boot noise, or image size but do not help
# a headless file proxy. Keep this list conservative; predictable image
# preparation matters more than shaving every possible package.
log "Removing unnecessary packages to minimize image size..."

REMOVE_PKGS=(
    # Spell-check stack
    ispell iamerican ibritish ienglish-common wamerican
    dictionaries-common emacsen-common
    # Post-install / installer artifacts
    installation-report
    tasksel tasksel-data task-english
    # Multi-boot GRUB probing (useless in VM)
    os-prober
    # Laptop / desktop detection
    laptop-detect
    # Desktop-oriented hooks
    xdg-user-dirs shared-mime-info

    # Mail stack — the appliance sends no mail. apt-listchanges / mailutils
    # pull exim4 in as a Recommends, so explicitly purge the lot. The
    # unattended-upgrades install below uses --no-install-recommends to
    # keep them from sneaking back in.
    exim4 exim4-base exim4-config exim4-daemon-light
    bsd-mailx mailutils
    apt-listchanges

    # Debian community / end-user tooling that has no place on a server
    # appliance we don't hand out to end users.
    reportbug python3-reportbug
    popularity-contest
    debian-faq doc-debian

    # debconf prompts only run in English on this appliance (locale is set
    # to en_US.UTF-8 below); the ~2 MB of translation catalogs aren't used.
    debconf-i18n

    # Real-hardware bits that never apply to a VM proxy.
    eject
    discover discover-data
    # Wireless — VMs don't have radios.
    wpasupplicant wireless-regdb crda iw
    # Bluetooth
    bluez bluetooth
    # Audio
    alsa-utils pulseaudio

    # Avahi / mDNS — actively harmful next to a hardened SMB stack and
    # noisy on labs. The proxy advertises nothing on the network.
    avahi-daemon avahi-utils

    # The proxy is a member server, not an AD DC. If samba-ad-dc was
    # installed by some previous tinkering, get rid of it before we
    # configure smbd as a member.
    samba-ad-dc
)

for pkg in "${REMOVE_PKGS[@]}"; do
    if dpkg -l "$pkg" &>/dev/null 2>&1; then
        apt-get purge -y "$pkg" 2>/dev/null || true
    fi
done

apt-get autoremove -y --purge
apt-get clean
log "Package cleanup complete."

#===============================================================================
# 2. PRE-DOWNLOAD GUEST AGENTS (no install)
#===============================================================================
# This image is host-agnostic: the same prepared snapshot must work on
# Hyper-V, KVM/QEMU, or VMware regardless of where it was mastered.
# Detecting the hypervisor here and installing only the matching agent
# would lock the image to that environment.
#
# Instead, pre-download a self-contained .deb bundle for each supported
# hypervisor into /var/cache/smbproxy-appliance/vmtools/<pkg>/. At the
# deployed VM's first boot, smbproxy-firstboot.service detects the actual
# hypervisor and does an offline `dpkg -i` from the matching cache
# directory, then deletes the rest. This works even if the deployment-side
# domain NIC isn't yet recognized, because no internet access is required
# at first boot.
log "Pre-downloading guest agents and cloud helpers for all supported targets..."

VMTOOLS_CACHE="/var/cache/smbproxy-appliance/vmtools"
mkdir -p "$VMTOOLS_CACHE"

declare -A VIRT_PKGS=(
    ["amazon"]="qemu-guest-agent cloud-init cloud-guest-utils"
    ["kvm"]="qemu-guest-agent cloud-guest-utils"
    ["qemu"]="qemu-guest-agent cloud-guest-utils"
    ["microsoft"]="hyperv-daemons cloud-guest-utils"
    ["vmware"]="open-vm-tools cloud-guest-utils"
    ["oracle"]="cloud-guest-utils"
    ["xen"]="qemu-guest-agent cloud-guest-utils"
)

EXTRA_DOWNLOADS="cloud-init"

declare -A PKGS_SEEN
for virt in "${!VIRT_PKGS[@]}"; do
    for pkg in ${VIRT_PKGS[$virt]}; do
        PKGS_SEEN[$pkg]=1
    done
done
for pkg in $EXTRA_DOWNLOADS; do
    PKGS_SEEN[$pkg]=1
done

for pkg in "${!PKGS_SEEN[@]}"; do
    dest="$VMTOOLS_CACHE/$pkg"
    mkdir -p "$dest/partial"
    log "  pre-download $pkg -> $dest"
    if ! apt-get install -y --download-only --reinstall --no-install-recommends \
            -o "Dir::Cache::archives=$dest" \
            "$pkg" 2>&1 | tail -3; then
        warn "    WARN: download of $pkg failed (not in Debian main on this release; skipping)"
    fi
    rm -rf "$dest/partial"
done

{
    echo "# smbproxy-appliance guest-agent / cloud-helper manifest"
    echo "# format: systemd-detect-virt-value=space-separated-package-list"
    for virt in "${!VIRT_PKGS[@]}"; do
        printf '%s=%s\n' "$virt" "${VIRT_PKGS[$virt]}"
    done | sort
} > "$VMTOOLS_CACHE/manifest"

log "  staged cache (per-package):"
du -sh "$VMTOOLS_CACHE"/* 2>/dev/null | sed 's|^|    |'

#===============================================================================
# 3. SYSTEM UPDATE
#===============================================================================
log "Updating package index and upgrading system..."
apt-get update -y
apt-get upgrade -y

#===============================================================================
# 4. BASE TOOLS
#===============================================================================
log "Installing base administration tools..."
apt-get install -y \
    sudo \
    nano \
    iputils-ping \
    net-tools \
    dnsutils \
    wget \
    curl \
    htop \
    tree \
    rsync \
    bash-completion \
    locales-all \
    whiptail \
    nftables \
    ldap-utils \
    iproute2 \
    ethtool

#===============================================================================
# 5. SAMBA MEMBER + CIFS CLIENT
#===============================================================================
# Member server only. NO samba-ad-dc — that package brings in a different
# samba.service unit that masks smbd/nmbd; for a member proxy we want the
# stock smbd flavour.
log "Installing Samba member-server, Winbind, and cifs-utils..."
apt-get install -y \
    samba \
    winbind \
    libnss-winbind \
    libpam-winbind \
    krb5-user \
    smbclient \
    cifs-utils \
    acl \
    attr

#===============================================================================
# 6. CHRONY NTP
#===============================================================================
log "Installing Chrony..."
apt-get install -y chrony

#===============================================================================
# 7. UNATTENDED-UPGRADES FRAMEWORK
#===============================================================================
log "Installing unattended-upgrades framework..."
apt-get install -y --no-install-recommends unattended-upgrades

# Default to disabled — sconfig sets the policy per deployment.
cat > /etc/apt/apt.conf.d/20auto-upgrades << 'UAEOF'
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Unattended-Upgrade "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "7";
UAEOF

#===============================================================================
# 8. SET LOCALE
#===============================================================================
log "Setting system locale to en_US.UTF-8..."
update-locale LANG=en_US.UTF-8
export LANG=en_US.UTF-8

#===============================================================================
# 9. CONFIGURE SYSTEMD-RESOLVED  (DHCP-DNS preferred, 1.1.1.1 fallback)
#===============================================================================
# Pre-join, the appliance is just a regular Debian box and should use
# whatever DNS the deployment network's DHCP supplies. systemd-resolved
# does that automatically — it merges per-link DHCP DNS with global
# fallbacks. We add 1.1.1.1 / 1.0.0.1 as fallbacks so the box still
# resolves names if DHCP didn't provide a DNS server (rare but real).
#
# smbproxy-sconfig disables systemd-resolved and writes its own
# /etc/resolv.conf at join time, when the WS2025 DC is the authoritative
# name source for the realm. The legacy NIC's interface gets DNS=disabled
# explicitly so resolved never tries to ask the LegacyZone for anything.
log "Configuring systemd-resolved (DHCP DNS preferred, 1.1.1.1 fallback)..."
mkdir -p /etc/systemd/resolved.conf.d
cat > /etc/systemd/resolved.conf.d/10-smbproxy-appliance.conf <<'RSLVEOF'
[Resolve]
FallbackDNS=1.1.1.1 1.0.0.1
DNSStubListener=yes
RSLVEOF

#===============================================================================
# 10. MASK SAMBA SERVICES UNTIL SCONFIG TAKES OVER
#===============================================================================
# Without smb.conf, smbd would either fail or serve nothing useful. nmbd
# is irrelevant — we never speak NetBIOS. winbind has nothing to do until
# the host is domain-joined. samba-sconfig enables smbd + winbind (and
# leaves nmbd masked) as part of the join flow.
log "Stopping and disabling Samba services until smbproxy-sconfig takes over..."
systemctl stop samba winbind nmbd smbd 2>/dev/null || true
systemctl disable samba winbind nmbd smbd 2>/dev/null || true
# Mask nmbd permanently — the proxy never speaks NetBIOS.
systemctl mask nmbd 2>/dev/null || true

#===============================================================================
# 11. REMOVE DEFAULT SMB.CONF
#===============================================================================
# A leftover Debian default smb.conf would advertise homes/printers and
# confuse later inspection. smbproxy-sconfig writes the real config from
# scratch the first time domain-join is run.
log "Removing default smb.conf..."
rm -f /etc/samba/smb.conf

#===============================================================================
# 12. SKELETON KRB5.CONF
#===============================================================================
log "Writing skeleton krb5.conf..."
cat > /etc/krb5.conf << 'KRBEOF'
[libdefaults]
  default_realm = YOURREALM.LAN
  dns_lookup_kdc = true
  dns_lookup_realm = false
  ticket_lifetime = 24h
  renew_lifetime = 7d
  forwardable = true
KRBEOF

#===============================================================================
# 13. SKELETON CHRONY.CONF
#===============================================================================
log "Writing chrony skeleton..."
# Deliberately no NTP servers here. AD time has topology rules: a member
# server should follow the domain time source. smbproxy-sconfig points
# chrony at the WS2025 DC during join. Baking public pools into the
# golden image also breaks isolated labs.
#
# This proxy never serves NTP (no `allow`, no signed-NTP socket). It is
# strictly a time client.
cat > /etc/chrony/chrony.conf << 'CHRONEOF'
# Time sources are configured per deployment by smbproxy-sconfig.
# Until sconfig runs, this host relies on the hypervisor time-sync service
# (hyperv-daemons / open-vm-tools / qemu-guest-agent) if present.

driftfile /var/lib/chrony/drift
makestep 1.0 3
CHRONEOF

#===============================================================================
# 14. BACKUP NSSWITCH.CONF
#===============================================================================
log "Backing up nsswitch.conf..."
cp /etc/nsswitch.conf /etc/nsswitch.conf.orig

#===============================================================================
# 15. STATE / CONFIG DIRECTORIES
#===============================================================================
log "Creating /etc/smbproxy and /var/lib/smbproxy state dirs..."
mkdir -p /etc/smbproxy /var/lib/smbproxy
chmod 0755 /etc/smbproxy /var/lib/smbproxy

#===============================================================================
# 16. INSTALL SMBPROXY-SCONFIG
#===============================================================================
log "Installing smbproxy-sconfig tool..."
for src in /root/smbproxy-sconfig.sh /root/smbproxy-sconfig; do
    if [[ -f "$src" ]]; then
        cp "$src" /usr/local/sbin/smbproxy-sconfig
        chmod +x /usr/local/sbin/smbproxy-sconfig
        log "  Installed from $src to /usr/local/sbin/smbproxy-sconfig"
        break
    fi
done
[[ -x /usr/local/sbin/smbproxy-sconfig ]] || warn "smbproxy-sconfig not found — copy it manually to /usr/local/sbin/"

# Pre-connect probe used by modern-profile shares' `root preexec` to
# fail-fast when the backend is offline (see smbproxy-probe-backend
# header for the rationale).
for src in /root/smbproxy-probe-backend /root/smbproxy-probe-backend.sh; do
    if [[ -f "$src" ]]; then
        cp "$src" /usr/local/sbin/smbproxy-probe-backend
        chmod +x /usr/local/sbin/smbproxy-probe-backend
        log "  Installed from $src to /usr/local/sbin/smbproxy-probe-backend"
        break
    fi
done
[[ -x /usr/local/sbin/smbproxy-probe-backend ]] || warn "smbproxy-probe-backend not found — copy it manually to /usr/local/sbin/"

grep -q 'smbproxy-sconfig' /root/.bashrc 2>/dev/null || \
    echo 'alias sconfig="sudo smbproxy-sconfig"' >> /root/.bashrc

#===============================================================================
# 16b. VENDOR APPLIANCE-CORE LIBS
#===============================================================================
# smbproxy-sconfig sources shared bash helpers from
# /usr/local/lib/appliance-core/. The libs come from the sibling
# appliance-core repo and are scp'd to /tmp/lib by the build pipeline
# (see lab/build-fresh-base.sh §5). Vendoring them into the image at
# prep time means a deployed appliance has no runtime cross-repo
# dependency.
#
# Provenance file at /etc/appliance-core.provenance carries the SemVer
# (lib/VERSION, informational) and the git commit hash of the
# appliance-core checkout that built this image (load-bearing
# identity). Hash is computed Mac-side and passed via
# $APPCORE_BUILD_COMMIT.
LIB_TARGET=/usr/local/lib/appliance-core
LIB_SRC=""
for cand in /tmp/lib /root/appliance-core-lib; do
    if [[ -d "$cand" && -f "$cand/detect-net.sh" ]]; then
        LIB_SRC="$cand"; break
    fi
done

if [[ -n "$LIB_SRC" ]]; then
    log "Vendoring appliance-core libs from $LIB_SRC -> $LIB_TARGET ..."
    install -d -m 0755 "$LIB_TARGET"
    install -m 0644 "$LIB_SRC"/*.sh "$LIB_TARGET/"
    [[ -f "$LIB_SRC/VERSION"   ]] && install -m 0644 "$LIB_SRC/VERSION"   "$LIB_TARGET/VERSION"
    [[ -f "$LIB_SRC/README.md" ]] && install -m 0644 "$LIB_SRC/README.md" "$LIB_TARGET/README.md"

    src_count=$(ls -1 "$LIB_SRC"/*.sh 2>/dev/null | wc -l)
    dst_count=$(ls -1 "$LIB_TARGET"/*.sh 2>/dev/null | wc -l)
    if (( src_count == 0 || src_count != dst_count )); then
        err "appliance-core vendoring count mismatch: source $src_count, target $dst_count"
        exit 1
    fi
    for libfile in "$LIB_TARGET"/*.sh; do
        bash -n "$libfile" || { err "vendored lib failed bash -n: $libfile"; exit 1; }
    done
    log "  vendored $dst_count appliance-core lib(s) into $LIB_TARGET"

    PROV_FILE=/etc/appliance-core.provenance
    PROV_COMMIT="${APPCORE_BUILD_COMMIT:-unknown}"
    {
        printf 'appliance-core-version=%s\n' "$(<"$LIB_TARGET/VERSION")"
        printf 'appliance-core-commit=%s\n'  "$PROV_COMMIT"
        printf 'image-built-at=%s\n'         "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'image-built-on=%s\n'         "$(uname -srm)"
        printf 'consumer=smb-proxy-appliance\n'
    } > "$PROV_FILE"
    chmod 0644 "$PROV_FILE"
    log "  provenance: $(tr '\n' ' ' < "$PROV_FILE")"
else
    warn "no appliance-core lib/ source at /tmp/lib or /root/appliance-core-lib"
    warn "smbproxy-sconfig features that depend on the shared libs will fail at runtime"
    warn "fix: ensure lab/build-fresh-base.sh pushes ../appliance-core/lib to /tmp/lib"
fi

#===============================================================================
# 17. MOTD BANNER
#===============================================================================
log "Setting login banner..."
cat > /etc/motd << 'MOTDEOF'

  ╔═══════════════════════════════════════════════════════╗
  ║              SMB1↔SMB3 Protocol Gateway               ║
  ║                  Debian 13 (Trixie)                   ║
  ╠═══════════════════════════════════════════════════════╣
  ║  Run 'sudo smbproxy-sconfig' to configure this host.  ║
  ╚═══════════════════════════════════════════════════════╝

MOTDEOF

#===============================================================================
# 18. NFTABLES FIREWALL RULESET (inactive — sconfig activates after join)
#===============================================================================
# Member-server rules. The legacy NIC carries only outbound SMB1 to the
# legacy backend; nothing should listen on it. sconfig writes the live
# /etc/nftables.conf with the actual interface names once NIC roles are
# known; this template is for reference and headless tests.
log "Writing proxy firewall ruleset template (inactive)..."
cat > /etc/nftables-smbproxy.conf << 'NFTEOF'
#!/usr/sbin/nft -f
#
# Template only. smbproxy-sconfig substitutes %DOMAIN_IFACE% / %LEGACY_IFACE%
# with the live interface names and installs the resulting file as
# /etc/nftables.conf. Direct use of this file will leave the substitution
# tokens unresolved and refuse to load.
flush ruleset
table inet filter {
    chain input {
        type filter hook input priority 0; policy drop;
        iif "lo" accept
        ct state established,related accept
        ip protocol icmp accept
        ip6 nexthdr ipv6-icmp accept

        # Domain-side: SSH + SMB3 listener for AD-joined clients.
        iifname "%DOMAIN_IFACE%" tcp dport 22 accept
        iifname "%DOMAIN_IFACE%" tcp dport 445 accept

        # Legacy NIC carries no listeners. Drop everything inbound; the
        # established/related rule above lets backend SMB1 replies through.

        log prefix "nft-drop: " limit rate 5/minute
        drop
    }
    chain forward { type filter hook forward priority 0; policy drop; }
    chain output  { type filter hook output priority 0; policy accept; }
}
NFTEOF

#===============================================================================
# 19. FIRST-BOOT HOST INTEGRATION
#===============================================================================
# smbproxy-firstboot detects which hypervisor we're running on AT FIRST
# BOOT (not at image-prep time), installs the matching guest agent offline
# from /var/cache/smbproxy-appliance/vmtools/, prints host-specific
# recommendations, runs network-environment detection (incl. NIC
# enumeration with MAC + carrier state for the role-assignment wizard),
# and disables itself. The marker file /var/lib/smbproxy-firstboot.done
# makes subsequent boots a no-op.
log "Installing smbproxy-firstboot helper + service..."

cat > /usr/local/sbin/smbproxy-firstboot <<'FBEOF'
#!/usr/bin/env bash
#
# smbproxy-firstboot — runs once on the first boot of a deployed proxy
# appliance. Detects the actual hypervisor (which is usually NOT the same
# as the one the image was mastered on), installs the matching guest agent
# from /var/cache/smbproxy-appliance/vmtools/ offline, deletes the unused
# caches, prints recommended VM hardware, enumerates network interfaces
# for the NIC role-assignment wizard, and disables itself.

set -u -o pipefail
PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

LOGFILE="/var/log/smbproxy-firstboot.log"
MARKER="/var/lib/smbproxy-firstboot.done"
MOTD="/etc/motd.d/01-smbproxy-firstboot"
CACHE="/var/cache/smbproxy-appliance/vmtools"
MANIFEST="$CACHE/manifest"

mkdir -p /var/lib /etc/motd.d "$(dirname "$LOGFILE")"

log() { printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$*" | tee -a "$LOGFILE"; }

if [[ -f "$MARKER" ]]; then
    log "smbproxy-firstboot already complete (marker present); nothing to do"
    exit 0
fi

VIRT=$(systemd-detect-virt 2>/dev/null || echo "none")
log "host environment: $VIRT"

PKG_LIST=""
if [[ -f "$MANIFEST" ]]; then
    PKG_LIST=$(awk -F= -v v="$VIRT" 'NF>=2 && $1==v {sub(/^[^=]+=/, "", $0); print; exit}' "$MANIFEST")
fi

# Azure runs on Hyper-V, so systemd-detect-virt reports 'microsoft'. Tell
# them apart by the chassis-asset-tag DMI string Azure sets to a fixed
# value. When matched, augment the install list with cloud-init.
AZURE_CHASSIS_TAG="7783-7084-3265-9085-8269-3286-77"
if [[ "$VIRT" == "microsoft" ]] && \
   [[ -r /sys/class/dmi/id/chassis_asset_tag ]] && \
   [[ "$(cat /sys/class/dmi/id/chassis_asset_tag 2>/dev/null)" == "$AZURE_CHASSIS_TAG" ]]; then
    log "Azure detected via DMI chassis-asset-tag; adding cloud-init"
    PKG_LIST="$PKG_LIST cloud-init"
fi

# Per-package systemd unit map. Empty means "no service to enable".
service_units_for() {
    case "$1" in
        qemu-guest-agent)  echo "qemu-guest-agent" ;;
        open-vm-tools)     echo "open-vm-tools" ;;
        hyperv-daemons)    echo "hv-kvp-daemon hv-vss-daemon" ;;
        cloud-init)        echo "" ;;
        cloud-guest-utils) echo "" ;;
        *)                 echo "" ;;
    esac
}

INSTALLED_NOTE=""
INSTALLED_PKGS=""
FAILED_PKGS=""

if [[ -z "$PKG_LIST" ]]; then
    INSTALLED_NOTE="No guest-agent or cloud-helper package staged for '$VIRT'.
The proxy will run without host-side integration; chrony handles time,
ACPI handles graceful shutdown — both work without an agent. Install
any of /var/cache/smbproxy-appliance/vmtools/<pkg>/*.deb by hand if you
want management-plane integration."
    log "$INSTALLED_NOTE"
else
    log "installing for $VIRT: $PKG_LIST"
    for pkg in $PKG_LIST; do
        deb_dir="$CACHE/$pkg"
        if [[ ! -d "$deb_dir" ]] || ! compgen -G "$deb_dir/*.deb" >/dev/null; then
            log "  WARN: $pkg has no .deb files in cache (skipping)"
            FAILED_PKGS="$FAILED_PKGS $pkg"
            continue
        fi
        log "  dpkg -i $pkg (offline from $deb_dir)"
        if dpkg -i "$deb_dir"/*.deb >>"$LOGFILE" 2>&1; then
            INSTALLED_PKGS="$INSTALLED_PKGS $pkg"
        else
            log "    ERROR: dpkg -i of $pkg failed; see $LOGFILE"
            FAILED_PKGS="$FAILED_PKGS $pkg"
        fi
    done

    systemctl daemon-reload || true

    for pkg in $INSTALLED_PKGS; do
        for svc in $(service_units_for "$pkg"); do
            if systemctl enable --now "$svc" >>"$LOGFILE" 2>&1; then
                log "  enabled+started: $svc ($pkg)"
            else
                log "  WARN: could not start $svc (from $pkg)"
            fi
        done
    done

    if [[ -n "$INSTALLED_PKGS" ]]; then
        INSTALLED_NOTE="Installed:$INSTALLED_PKGS"
        [[ -n "$FAILED_PKGS" ]] && INSTALLED_NOTE+=$'\n'"Failed:   $FAILED_PKGS (see $LOGFILE)"
    elif [[ -n "$FAILED_PKGS" ]]; then
        INSTALLED_NOTE="ERROR: nothing installed; failed:$FAILED_PKGS"
        log "$INSTALLED_NOTE"
    fi

    if echo " $INSTALLED_PKGS " | grep -q ' cloud-init '; then
        INSTALLED_NOTE+=$'\n'"NOTE: reboot once to let cloud-init run from early boot and apply"
        INSTALLED_NOTE+=$'\n'"      IMDS data (SSH keys, hostname) from your cloud platform."
    fi
fi

# Host-specific recommendations.
read -r -d '' RECS <<RECEOF || true
=== Recommended VM hardware/config for $VIRT ===
RECEOF

case "$VIRT" in
    kvm|qemu)
        RECS+=$'\n'"  Hypervisor: KVM/QEMU (Proxmox, libvirt, oVirt, ...)"
        RECS+=$'\n'"  vCPU:       2+ (host-passthrough for AES-NI on SMB3 encryption)"
        RECS+=$'\n'"  RAM:        2 GiB minimum"
        RECS+=$'\n'"  Disk:       virtio-blk or virtio-scsi"
        RECS+=$'\n'"  NICs:       virtio-net x2 — one on the AD LAN, one on LegacyZone"
        RECS+=$'\n'"  Agent:      qemu-guest-agent (this script just installed it)"
        ;;
    vmware)
        RECS+=$'\n'"  Hypervisor: VMware (ESXi / vCenter / Workstation / Fusion)"
        RECS+=$'\n'"  vCPU:       2+, expose AES-NI"
        RECS+=$'\n'"  RAM:        2 GiB minimum (no ballooning)"
        RECS+=$'\n'"  Disk:       Paravirtual SCSI (PVSCSI)"
        RECS+=$'\n'"  NICs:       vmxnet3 x2 — AD LAN + LegacyZone vSwitch"
        RECS+=$'\n'"  Agent:      open-vm-tools (this script just installed it)"
        ;;
    microsoft)
        if [[ "$(cat /sys/class/dmi/id/chassis_asset_tag 2>/dev/null)" == "$AZURE_CHASSIS_TAG" ]]; then
            RECS+=$'\n'"  Platform:   Microsoft Azure (Hyper-V-backed)"
            RECS+=$'\n'"  vCPU:       2+, AES-NI exposed (default on Standard SKUs)"
            RECS+=$'\n'"  RAM:        2 GiB+"
            RECS+=$'\n'"  NICs:       Two interfaces — only meaningful if the legacy backend"
            RECS+=$'\n'"              is reachable as an Azure-side network. Most real"
            RECS+=$'\n'"              deployments are on-prem Hyper-V — this advice is FYI."
            RECS+=$'\n'"  Agents:     hyperv-daemons + cloud-init (just installed)"
        else
            RECS+=$'\n'"  Hypervisor: Microsoft Hyper-V (on-prem)"
            RECS+=$'\n'"  Generation: 2 (UEFI). Disable Secure Boot for the cloud-image bootloader"
            RECS+=$'\n'"              UNLESS you booted from the Debian installer ISO (then it's fine)."
            RECS+=$'\n'"  vCPU:       2+"
            RECS+=$'\n'"  RAM:        2 GiB+ STATIC; do not use Dynamic Memory"
            RECS+=$'\n'"  NICs:       Hyper-V synthetic adapter x2 — connect one to the AD"
            RECS+=$'\n'"              switch (e.g. Lab-NAT) and one to the LegacyZone switch"
            RECS+=$'\n'"  Integration: enable Heartbeat, Guest Service Interface; DISABLE"
            RECS+=$'\n'"               'Time Synchronization' (chrony manages domain time)"
            RECS+=$'\n'"  Agent:      hyperv-daemons (this script just installed it)"
        fi
        ;;
    amazon)
        RECS+=$'\n'"  Platform:   Amazon EC2 (Nitro)"
        RECS+=$'\n'"  Two interfaces typically requires VPC peering or a private link"
        RECS+=$'\n'"  to reach the legacy backend. The proxy works fine on EC2 but is"
        RECS+=$'\n'"  only useful when there is genuinely a legacy SMB1 host to front."
        RECS+=$'\n'"  Agents:     qemu-guest-agent + cloud-init + cloud-guest-utils (installed)"
        ;;
    xen)
        RECS+=$'\n'"  Hypervisor: Xen / Citrix Hypervisor / XCP-ng"
        RECS+=$'\n'"  NICs:       netfront x2 (AD LAN + LegacyZone)"
        RECS+=$'\n'"  Agents:     qemu-guest-agent (installed)"
        ;;
    oracle)
        RECS+=$'\n'"  Hypervisor: Oracle VirtualBox"
        RECS+=$'\n'"  No headless guest-agent .deb is staged. Install"
        RECS+=$'\n'"  virtualbox-guest-utils manually if you want clipboard/file integration."
        ;;
    none)
        RECS+=$'\n'"  Bare-metal install detected — no virtualization-specific advice."
        RECS+=$'\n'"  Make sure chrony has reachable upstream NTP, both NICs are wired,"
        RECS+=$'\n'"  and the BIOS clock is sane."
        ;;
    *)
        RECS+=$'\n'"  Unknown environment '$VIRT'. No specific recommendations."
        ;;
esac

log ""
printf '%s\n' "$RECS" | tee -a "$LOGFILE"

# Image-freshness check.
log ""
log "checking image freshness (apt-get update + upgradable count)..."
APT_FRESHNESS=""
for _ in $(seq 1 10); do
    [[ -n "$(ip route show default 2>/dev/null)" ]] && break
    sleep 2
done
if [[ -z "$(ip route show default 2>/dev/null)" ]]; then
    APT_FRESHNESS="apt: offline (no default route) — freshness check skipped"
elif apt-get update -qq >>"$LOGFILE" 2>&1; then
    upg=$(apt list --upgradable 2>/dev/null | grep -cv '^Listing')
    sec=$(apt list --upgradable 2>/dev/null | grep -c -- '-security' || true)
    if [[ "$upg" -eq 0 ]]; then
        APT_FRESHNESS="apt: image is current (0 upgrades pending)"
    else
        # Kernel and other held-back packages require dist-upgrade (installs new
        # packages); plain upgrade refuses to do so and silently skips them.
        if apt-get --simulate upgrade 2>/dev/null | grep -q "kept back"; then
            apt_cmd="sudo apt-get dist-upgrade"
        else
            apt_cmd="sudo apt-get upgrade"
        fi
        APT_FRESHNESS="apt: ${upg} upgrades pending (${sec} security-marked); review with 'apt list --upgradable', apply with '${apt_cmd}'"
    fi
else
    APT_FRESHNESS="apt: index refresh failed — see $LOGFILE"
fi
log "  $APT_FRESHNESS"

#==========================================================================
# Network-environment detection.
#
# For the proxy we enumerate ALL ethernet-class interfaces, not just the
# one with a default route. The TTY1 wizard uses this list to ask the
# operator which NIC is which (domain vs legacy). We capture, per NIC:
#   - kernel name (eth0, ens3, enp1s0 ...)
#   - permanent MAC (ethtool -P; falls back to /sys when ethtool is absent)
#   - operstate (up / down)
#   - whether it has a DHCP lease
#   - any IPv4 currently bound
# and write them as NIC0_*, NIC1_* etc. into the detected.env file.
#==========================================================================
log ""
log "detecting network-environment hints..."
DETECT_FILE=/var/lib/smbproxy-init-detected.env
mkdir -p /var/lib

det_default_iface=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
det_default_ip=""
det_default_gateway=""
if [[ -n "$det_default_iface" ]]; then
    det_default_ip=$(ip -o -4 addr show dev "$det_default_iface" scope global 2>/dev/null \
                        | awk 'NR==1 {sub(/\/.*$/,"",$4); print $4}')
    det_default_gateway=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
fi
det_dhcp_dns=$(resolvectl dns 2>/dev/null \
                | awk '/^Link [0-9]/ {for(i=4;i<=NF;i++) printf "%s ", $i}' \
                | sed 's/ *$//')
det_dhcp_domain=$(resolvectl domain 2>/dev/null \
                | awk '/^Link [0-9]/ {for(i=4;i<=NF;i++) {
                                          gsub(/^~/,"",$i)
                                          if ($i!="" && $i!=".") {print $i; exit}
                                      }}')

# Collect all ethernet interfaces.
mapfile -t ALL_IFACES < <(ls -1 /sys/class/net 2>/dev/null \
    | while read -r n; do
        [[ "$n" == "lo" ]] && continue
        # Skip loopback, bridges, virtual switches, wireguard, docker, etc.
        [[ -d "/sys/class/net/$n/bridge" ]] && continue
        [[ "$n" == docker* || "$n" == veth* || "$n" == wg* || "$n" == tun* || "$n" == tap* ]] && continue
        # Only physical/synthetic ethernet (type 1 = ARPHRD_ETHER).
        local_type=$(cat "/sys/class/net/$n/type" 2>/dev/null || echo 0)
        [[ "$local_type" == "1" ]] || continue
        echo "$n"
      done)

mac_for_iface() {
    local i="$1" m=""
    if command -v ethtool >/dev/null 2>&1; then
        m=$(ethtool -P "$i" 2>/dev/null | awk '{print $NF}')
    fi
    if [[ -z "$m" || "$m" == "00:00:00:00:00:00" ]]; then
        m=$(cat "/sys/class/net/$i/address" 2>/dev/null || echo "")
    fi
    echo "${m,,}"
}

is_dhcp_iface() {
    # systemd-networkd / NetworkManager-agnostic probe: presence of a
    # 'dynamic' flag on the IPv4 address is an unambiguous DHCP marker.
    local i="$1"
    ip -4 addr show dev "$i" 2>/dev/null | grep -q 'dynamic'
}

ip4_for_iface() {
    local i="$1"
    ip -o -4 addr show dev "$i" 2>/dev/null | awk 'NR==1 {print $4}'
}

operstate_for() {
    cat "/sys/class/net/$1/operstate" 2>/dev/null || echo unknown
}

# Build the per-NIC block. NIC_COUNT controls how many NIC[N]_* sets the
# wizard reads.
nic_block=""
nic_count=0
for ifn in "${ALL_IFACES[@]}"; do
    mac=$(mac_for_iface "$ifn")
    state=$(operstate_for "$ifn")
    cidr=$(ip4_for_iface "$ifn")
    dhcp=no
    is_dhcp_iface "$ifn" && dhcp=yes
    nic_block+="NIC${nic_count}_NAME=\"$ifn\""$'\n'
    nic_block+="NIC${nic_count}_MAC=\"$mac\""$'\n'
    nic_block+="NIC${nic_count}_STATE=\"$state\""$'\n'
    nic_block+="NIC${nic_count}_IP4=\"${cidr:-}\""$'\n'
    nic_block+="NIC${nic_count}_DHCP=\"$dhcp\""$'\n'
    log "  NIC[$nic_count] $ifn mac=$mac state=$state ip=${cidr:-<none>} dhcp=$dhcp"
    nic_count=$((nic_count+1))
done

cat > "$DETECT_FILE" <<DETEOF
# Generated by smbproxy-firstboot $(date -u +%Y-%m-%dT%H:%M:%SZ).
# Refreshed on each firstboot run; smbproxy-init reads this on every menu render.
DET_DEFAULT_IFACE="${det_default_iface:-}"
DET_DEFAULT_IP="${det_default_ip:-}"
DET_DEFAULT_GATEWAY="${det_default_gateway:-}"
DET_DHCP_DNS="${det_dhcp_dns:-}"
DET_DHCP_DOMAIN="${det_dhcp_domain:-}"
DET_NIC_COUNT="$nic_count"
$nic_block
DETEOF
chmod 644 "$DETECT_FILE"
log "  default iface: ${det_default_iface:-(none)}  ip: ${det_default_ip:-?}  gw: ${det_default_gateway:-?}"
log "  DHCP-DNS: ${det_dhcp_dns:-(none)}  DHCP-domain: ${det_dhcp_domain:-(none)}"
log "  $nic_count ethernet NIC(s) detected"

# Write the motd snippet.
{
    echo
    echo "=== First-boot host detection (SMB gateway) ==="
    echo "Detected: $VIRT"
    printf '%s\n' "$INSTALLED_NOTE" | sed 's/^/  /'
    printf '%s\n' "$RECS"
    echo
    echo "Image freshness:"
    echo "  $APT_FRESHNESS"
    echo
    echo "(Remove $MOTD to silence this banner.)"
    echo
} > "$MOTD"

# Cleanup unused caches.
log ""
log "cleaning up unused guest-agent / cloud-helper caches..."
KEEP=" $(echo "$INSTALLED_PKGS" | xargs) "
shopt -s nullglob
for d in "$CACHE"/*/; do
    name=$(basename "$d")
    if [[ "$KEEP" != *" $name "* ]]; then
        log "  removing $d"
        rm -rf "$d"
    fi
done
shopt -u nullglob

touch "$MARKER"
log "smbproxy-firstboot complete; marker at $MARKER"
systemctl disable smbproxy-firstboot.service >>"$LOGFILE" 2>&1 || true
FBEOF
chmod +x /usr/local/sbin/smbproxy-firstboot

cat > /etc/systemd/system/smbproxy-firstboot.service <<'UEOF'
[Unit]
Description=SMB1↔SMB3 Proxy Appliance first-boot host integration
ConditionPathExists=!/var/lib/smbproxy-firstboot.done
After=local-fs.target network-online.target
Wants=network-online.target
# Run before smbd so the guest agent is up before any service traffic.
# smbd is masked at image-prep time and only enabled by smbproxy-sconfig
# after a join, so this ordering is mostly defensive.
Before=smbd.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/smbproxy-firstboot
StandardOutput=journal+console
StandardError=journal+console

[Install]
WantedBy=multi-user.target
UEOF

systemctl daemon-reload
systemctl enable smbproxy-firstboot.service

#===============================================================================
# 20. CONSOLE INITIAL-SETUP WIZARD (TTY1)
#===============================================================================
# When the appliance lands somewhere DHCP doesn't work, or the operator
# doesn't have the SSH key the master was built with, the only access path
# is the hypervisor's console. smbproxy-init is a whiptail-driven setup
# wizard that takes over TTY1 (via getty autologin) on every boot until
# the operator marks setup complete. It can:
#   - assign NIC roles by MAC (domain vs legacy)
#   - configure the domain NIC (DHCP / static)
#   - configure the legacy NIC (always static, gateway-less, no DNS)
#   - change the default password
#   - paste an SSH authorized_keys entry
#   - set hostname and timezone
log "Installing smbproxy-init console wizard + TTY1 autologin..."

cat > /usr/local/sbin/smbproxy-init <<'INITEOF'
#!/usr/bin/env bash
#
# smbproxy-init — TTY1-resident console setup wizard. Runs as 'debadmin'
# via autologin; uses passwordless sudo for system changes. Loops a menu
# (outer text + whiptail TUI) until the operator picks "Mark setup
# complete and proceed to login".
#
# State files:
#   /var/lib/smbproxy-init.done                -> setup acknowledged
#   /var/lib/smbproxy-init-default-password    -> debadmin still has the
#                                                 factory default password;
#                                                 the wizard refuses to
#                                                 mark complete while this
#                                                 marker exists
#   /etc/smbproxy/nic-roles.env                -> NIC role mapping; written
#                                                 here, consumed by sconfig

set -u

# Source shared appliance-core libs vendored by prepare-image.sh §16b.
# Sentinel-guarded so this is a no-op if already loaded; falls through
# silently when absent (older images that predate the vendoring).
APPCORE_LIBS=/usr/local/lib/appliance-core
if [[ -d "$APPCORE_LIBS" ]]; then
    for _lib in apt-helpers detect-net identity tui hostname; do
        [[ -f "$APPCORE_LIBS/${_lib}.sh" ]] && source "$APPCORE_LIBS/${_lib}.sh"
    done
    unset _lib
fi

MARKER=/var/lib/smbproxy-init.done
DEFAULT_PWD_MARKER=/var/lib/smbproxy-init-default-password
GETTY_DROPIN=/etc/systemd/system/getty@tty1.service.d/smbproxy-init.conf
ROLES_FILE=/etc/smbproxy/nic-roles.env
SELF_USER=$(id -un)

if [[ -f "$MARKER" ]]; then
    exec /bin/bash --login
fi

WT_HEIGHT=22
WT_WIDTH=76
WT_MENU=12

DETECT_FILE=/var/lib/smbproxy-init-detected.env

load_detect_env() {
    DET_DEFAULT_IFACE="" DET_DEFAULT_IP="" DET_DEFAULT_GATEWAY=""
    DET_DHCP_DNS="" DET_DHCP_DOMAIN="" DET_NIC_COUNT="0"
    if [[ -f "$DETECT_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$DETECT_FILE"
    fi
    # Live refresh — the bound IP changes as the operator switches modes.
    DET_DEFAULT_IFACE=$(ip -4 route show default 2>/dev/null | awk '/default/ {print $5; exit}')
    DET_DEFAULT_IP=$(ip -o -4 addr show scope global 2>/dev/null \
                | awk 'NR==1 {sub(/\/.*$/,"",$4); print $4}')
    DET_DEFAULT_GATEWAY=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
}

load_roles() {
    DOMAIN_NIC_NAME="" DOMAIN_NIC_MAC=""
    LEGACY_NIC_NAME="" LEGACY_NIC_MAC=""
    if [[ -f "$ROLES_FILE" ]]; then
        # shellcheck disable=SC1090
        source "$ROLES_FILE"
    fi
}

count_upgrades() {
    if [[ -z "$(ip route show default 2>/dev/null)" ]]; then
        echo "0 0"; return
    fi
    # Refresh apt indexes if the cache is older than 1h. Without this,
    # the count reflects whatever the cache held at last refresh —
    # and on a fresh deployment a few days after image build, the
    # cache is stale and reports 0 even when real security updates
    # are pending. Throttle so menu re-renders stay cheap (cold
    # first-boot pays ~30s once; warm re-renders are free).
    local now mtime cache_age
    if [[ -f /var/cache/apt/pkgcache.bin ]]; then
        now=$(date +%s)
        mtime=$(stat -c %Y /var/cache/apt/pkgcache.bin 2>/dev/null || echo 0)
        cache_age=$(( now - mtime ))
    else
        cache_age=999999
    fi
    if (( cache_age > 3600 )); then
        sudo apt-get update -qq >/dev/null 2>&1 || true
    fi
    # Delegate the actual count to appliance-core. The lib's
    # implementation uses `apt-get --simulate dist-upgrade` and
    # ^Inst lines, which is phased-rollout-aware (the regression
    # class that bit `apt list --upgradable`-based counters).
    if command -v appcore_apt_count_upgrades >/dev/null 2>&1; then
        appcore_apt_count_upgrades
        return
    fi
    # Fallback for older images without the lib.
    local sim upg sec
    sim=$(apt-get --simulate -qq dist-upgrade 2>/dev/null) || sim=""
    upg=$(grep -c '^Inst ' <<< "$sim" || true)
    sec=$(grep -c '^Inst .*-security' <<< "$sim" || true)
    echo "${upg:-0} ${sec:-0}"
}

# ----------------------------------------------------------------------------
# Status, password, SSH key, hostname, timezone — same shape as the AD-DC
# appliance's samba-init.
# ----------------------------------------------------------------------------
show_status() {
    load_detect_env
    load_roles
    {
        echo "Hostname: $(hostnamectl hostname 2>/dev/null || hostname)"
        echo
        echo "NIC roles:"
        if [[ -n "$DOMAIN_NIC_NAME" ]]; then
            echo "  domain: $DOMAIN_NIC_NAME (mac=$DOMAIN_NIC_MAC)"
        else
            echo "  domain: NOT ASSIGNED"
        fi
        if [[ -n "$LEGACY_NIC_NAME" ]]; then
            echo "  legacy: $LEGACY_NIC_NAME (mac=$LEGACY_NIC_MAC)"
        else
            echo "  legacy: NOT ASSIGNED"
        fi
        echo
        echo "Network interfaces:"
        ip -br addr show | sed 's/^/  /'
        echo
        echo "Default route:"
        ip route show default | sed 's/^/  /'
        [[ -z "$(ip route show default)" ]] && echo "  (none — no default gateway)"
        echo
        echo "DNS resolvers (resolvectl):"
        resolvectl dns 2>/dev/null | sed 's/^/  /' || echo "  (none)"
        echo
        echo "Setup state:"
        echo "  default password active: $([[ -f $DEFAULT_PWD_MARKER ]] && echo yes || echo no)"
        echo "  smbproxy-firstboot done: $([[ -f /var/lib/smbproxy-firstboot.done ]] && echo yes || echo no)"
        echo "  smbd                   : $(systemctl is-active smbd 2>/dev/null || echo not-running)"
        echo "  winbind                : $(systemctl is-active winbind 2>/dev/null || echo not-running)"
    } > /tmp/smbproxy-init-status.$$
    whiptail --title "Network & setup status" --scrolltext \
        --textbox /tmp/smbproxy-init-status.$$ "$WT_HEIGHT" "$WT_WIDTH"
    rm -f /tmp/smbproxy-init-status.$$
}

# ----------------------------------------------------------------------------
# NIC role assignment.
#
# The detect.env file enumerates all ethernet NICs as NIC0..NIC{N-1} blocks.
# We render a whiptail menu twice: once asking which NIC is the domain
# (AD-side) interface, then which is the legacy (LegacyZone-side)
# interface. The wizard refuses to assign the same NIC to both roles.
# ----------------------------------------------------------------------------
get_nic_field() {
    # $1 = index, $2 = field (NAME|MAC|STATE|IP4|DHCP)
    local var="NIC${1}_${2}"
    eval echo "\${$var:-}"
}

build_nic_menu_args() {
    # Echo whiptail --menu argument tuples: TAG ITEM TAG ITEM ...
    # TAG is the kernel name; ITEM is "MAC | state | ip-or-dhcp".
    local i
    for ((i=0; i<DET_NIC_COUNT; i++)); do
        local n m s ip dhcp item
        n=$(get_nic_field "$i" NAME)
        m=$(get_nic_field "$i" MAC)
        s=$(get_nic_field "$i" STATE)
        ip=$(get_nic_field "$i" IP4)
        dhcp=$(get_nic_field "$i" DHCP)
        item="$m  link=$s"
        if [[ "$dhcp" == "yes" && -n "$ip" ]]; then
            item+=" dhcp=$ip"
        elif [[ -n "$ip" ]]; then
            item+=" ip=$ip"
        else
            item+=" no-ip"
        fi
        printf '%s\n%s\n' "$n" "$item"
    done
}

assign_nic_roles() {
    load_detect_env
    if [[ "${DET_NIC_COUNT:-0}" -lt 2 ]]; then
        whiptail --title "NIC role assignment" --msgbox \
            "Only ${DET_NIC_COUNT:-0} ethernet interface(s) detected.\n\nThe proxy needs TWO NICs — one on the AD domain LAN, one on the LegacyZone subnet. Add a second NIC in the hypervisor and reboot." \
            12 "$WT_WIDTH"
        return
    fi

    local menu_args
    mapfile -t menu_args < <(build_nic_menu_args)

    local pick_dom pick_leg
    pick_dom=$(whiptail --title "Domain NIC" --notags \
        --menu "Pick the interface attached to the AD domain LAN.\n\nThis NIC carries DHCP (initially) or a static IP, the default route, and DNS pointing at the WS2025 DC." \
        "$WT_HEIGHT" "$WT_WIDTH" "$WT_MENU" \
        "${menu_args[@]}" \
        3>&1 1>&2 2>&3) || return

    pick_leg=$(whiptail --title "Legacy NIC" --notags \
        --menu "Pick the interface attached to LegacyZone (the dedicated point-to-point link to the legacy backend).\n\nThis NIC is always static, gateway-less, and serves no DNS." \
        "$WT_HEIGHT" "$WT_WIDTH" "$WT_MENU" \
        "${menu_args[@]}" \
        3>&1 1>&2 2>&3) || return

    if [[ "$pick_dom" == "$pick_leg" ]]; then
        whiptail --msgbox "Domain and Legacy must be different interfaces." 8 50
        return
    fi

    # Resolve MACs for the chosen names.
    local i dom_mac leg_mac
    for ((i=0; i<DET_NIC_COUNT; i++)); do
        local n m
        n=$(get_nic_field "$i" NAME)
        m=$(get_nic_field "$i" MAC)
        [[ "$n" == "$pick_dom" ]] && dom_mac="$m"
        [[ "$n" == "$pick_leg" ]] && leg_mac="$m"
    done

    sudo install -d -o root -g root -m 0755 /etc/smbproxy
    sudo bash -c "cat > $ROLES_FILE" <<RFEOF
# NIC role mapping. Written by smbproxy-init at first boot. Consumed by
# smbproxy-sconfig for network and firewall configuration.
DOMAIN_NIC_NAME="$pick_dom"
DOMAIN_NIC_MAC="$dom_mac"
LEGACY_NIC_NAME="$pick_leg"
LEGACY_NIC_MAC="$leg_mac"
RFEOF
    sudo chmod 0644 "$ROLES_FILE"
    whiptail --title "NIC roles saved" --msgbox \
        "Roles written to $ROLES_FILE:\n\n  domain: $pick_dom (mac=$dom_mac)\n  legacy: $pick_leg (mac=$leg_mac)\n\nThe network configuration step uses these. smbproxy-sconfig will read them after you finish initial setup." \
        14 "$WT_WIDTH"
}

# ----------------------------------------------------------------------------
# Network configuration.
#
# Domain NIC: DHCP or static (just like the AD-DC appliance's first-boot
# wizard). Static defaults pre-fill from the current DHCP lease when
# available.
#
# Legacy NIC: ALWAYS static, ALWAYS gateway-less, ALWAYS no DNS. The
# wizard only asks for the IP/CIDR.
# ----------------------------------------------------------------------------
write_netplan_yaml() {
    # Generate the live netplan based on whatever the role file plus the
    # arguments provided here. The legacy NIC stanza never carries a
    # gateway or nameservers regardless of what the operator typed.
    local dom_mode="$1"      # dhcp | static
    local dom_cidr="$2"      # used when dom_mode=static
    local dom_gw="$3"
    local dom_dns="$4"       # space-separated
    local leg_cidr="$5"      # always static; pass empty to skip configuring legacy

    load_roles
    local domain_iface="${DOMAIN_NIC_NAME}"
    local legacy_iface="${LEGACY_NIC_NAME}"
    [[ -z "$domain_iface" ]] && { whiptail --msgbox "No domain NIC role assigned. Run [N] first." 8 60; return 1; }

    # Build the per-interface YAML stanzas.
    local dom_stanza leg_stanza=""
    if [[ "$dom_mode" == "dhcp" ]]; then
        dom_stanza="    ${domain_iface}:
      match:
        macaddress: \"${DOMAIN_NIC_MAC}\"
      set-name: ${domain_iface}
      dhcp4: true
      dhcp6: false
"
    else
        local nslist=""
        for n in $dom_dns; do nslist+="$n, "; done
        nslist="${nslist%, }"
        dom_stanza="    ${domain_iface}:
      match:
        macaddress: \"${DOMAIN_NIC_MAC}\"
      set-name: ${domain_iface}
      dhcp4: false
      addresses: [${dom_cidr}]
      routes:
        - to: default
          via: ${dom_gw}
      nameservers:
        addresses: [${nslist}]
"
    fi

    if [[ -n "$legacy_iface" && -n "$leg_cidr" ]]; then
        leg_stanza="    ${legacy_iface}:
      match:
        macaddress: \"${LEGACY_NIC_MAC}\"
      set-name: ${legacy_iface}
      dhcp4: false
      dhcp6: false
      addresses: [${leg_cidr}]
      # No 'routes' — legacy link is gateway-less by design.
      # No 'nameservers' — legacy link serves no DNS.
"
    fi

    sudo bash -c "cat > /etc/netplan/60-smbproxy-init.yaml" <<NPY
network:
  version: 2
  ethernets:
${dom_stanza}${leg_stanza}
NPY
    sudo chmod 600 /etc/netplan/60-smbproxy-init.yaml
}

config_network() {
    load_detect_env
    load_roles
    if [[ -z "$DOMAIN_NIC_NAME" || -z "$LEGACY_NIC_NAME" ]]; then
        whiptail --msgbox "Assign NIC roles first ([N] in this menu)." 8 60
        return
    fi

    local dom_mode
    dom_mode=$(whiptail --title "Domain NIC mode" \
        --menu "Pick the addressing mode for the domain NIC ($DOMAIN_NIC_NAME, mac=$DOMAIN_NIC_MAC).\n\nDHCP is convenient for install-time; you'll typically pin a static IP after joining the AD domain." \
        16 "$WT_WIDTH" 2 \
        "dhcp"   "DHCP (default for install / lab environments)" \
        "static" "Static IPv4 (pre-filled from the current lease, if any)" \
        3>&1 1>&2 2>&3) || return

    local dom_cidr="" dom_gw="" dom_dns=""
    if [[ "$dom_mode" == "static" ]]; then
        local prefix=""
        prefix=$(ip -o -4 addr show dev "$DOMAIN_NIC_NAME" scope global 2>/dev/null \
                    | awk 'NR==1 {split($4,a,"/"); print a[2]}')
        local cur_ip
        cur_ip=$(ip -o -4 addr show dev "$DOMAIN_NIC_NAME" scope global 2>/dev/null \
                    | awk 'NR==1 {sub(/\/.*$/,"",$4); print $4}')
        local pre_cidr=""
        [[ -n "$cur_ip" ]] && pre_cidr="${cur_ip}/${prefix:-24}"
        dom_cidr=$(whiptail --inputbox "Domain NIC IPv4 with CIDR (e.g. 10.0.0.20/24):" 10 "$WT_WIDTH" "$pre_cidr" 3>&1 1>&2 2>&3) || return
        dom_gw=$(whiptail --inputbox "Default gateway (on the AD LAN):" 10 "$WT_WIDTH" "${DET_DEFAULT_GATEWAY}" 3>&1 1>&2 2>&3) || return
        dom_dns=$(whiptail --inputbox "DNS server(s), space-separated. Use the WS2025 DC IP after joining; for now a public DNS is fine:" 11 "$WT_WIDTH" "${DET_DHCP_DNS:-1.1.1.1}" 3>&1 1>&2 2>&3) || return
    fi

    # Pre-fill the legacy CIDR with whatever the legacy NIC currently has,
    # if anything. The default value is empty — the operator types the
    # 172.29.137.x/24 (or similar) themselves.
    local leg_cidr_pre leg_cidr
    leg_cidr_pre=$(ip -o -4 addr show dev "$LEGACY_NIC_NAME" scope global 2>/dev/null | awk 'NR==1 {print $4}')
    leg_cidr=$(whiptail --inputbox \
        "Legacy NIC IPv4 with CIDR (gateway-less, no DNS).\n\nExample: 172.29.137.5/24\nLeave blank to skip configuring the legacy NIC right now." \
        13 "$WT_WIDTH" "${leg_cidr_pre:-}" 3>&1 1>&2 2>&3) || return

    write_netplan_yaml "$dom_mode" "$dom_cidr" "$dom_gw" "$dom_dns" "$leg_cidr" || return

    if sudo netplan apply 2>&1 | tee /tmp/netplan.$$; then
        whiptail --title "Network applied" --scrolltext --msgbox \
            "$(cat /tmp/netplan.$$)\n\nResult:\n$(ip -br addr show)" 18 "$WT_WIDTH"
    else
        whiptail --msgbox "netplan apply reported errors. See /tmp/netplan.$$ — fix and retry." 10 "$WT_WIDTH"
    fi
    rm -f /tmp/netplan.$$
}

change_password() {
    local p1 p2
    p1=$(whiptail --passwordbox "New password for ${SELF_USER} (min 8 chars):" 10 "$WT_WIDTH" 3>&1 1>&2 2>&3) || return
    [[ ${#p1} -lt 8 ]] && { whiptail --msgbox "Min 8 characters." 8 50; return; }
    p2=$(whiptail --passwordbox "Confirm password:" 10 "$WT_WIDTH" 3>&1 1>&2 2>&3) || return
    [[ "$p1" == "$p2" ]] || { whiptail --msgbox "Passwords don't match." 8 50; return; }

    if echo "${SELF_USER}:${p1}" | sudo chpasswd; then
        sudo rm -f "$DEFAULT_PWD_MARKER"
        whiptail --msgbox "Password updated for ${SELF_USER}.\n\nThe default-password marker is gone; you can now mark setup complete." 11 "$WT_WIDTH"
    else
        whiptail --msgbox "chpasswd failed; password not changed." 8 50
    fi
}

add_ssh_key() {
    whiptail --msgbox "Paste the public key below and press OK.\n(Enter the full 'ssh-ed25519 AAA...' line.)" 10 "$WT_WIDTH"
    local key
    key=$(whiptail --inputbox "SSH public key:" 11 "$WT_WIDTH" 3>&1 1>&2 2>&3) || return
    [[ -n "$key" ]] || return
    case "$key" in
        ssh-rsa\ *|ssh-ed25519\ *|ecdsa-*\ *|sk-*) ;;
        *) whiptail --msgbox "That doesn't look like an SSH public key (no algorithm prefix)." 8 70; return ;;
    esac
    local home; home=$(getent passwd "$SELF_USER" | cut -d: -f6)
    sudo install -d -o "$SELF_USER" -g "$SELF_USER" -m 0700 "$home/.ssh"
    if echo "$key" | sudo tee -a "$home/.ssh/authorized_keys" >/dev/null; then
        sudo chown "$SELF_USER:$SELF_USER" "$home/.ssh/authorized_keys"
        sudo chmod 0600 "$home/.ssh/authorized_keys"
        whiptail --msgbox "Key added. SSH login as ${SELF_USER} will accept it." 9 "$WT_WIDTH"
    else
        whiptail --msgbox "Failed to write authorized_keys." 8 50
    fi
}

set_hostname() {
    local cur new
    cur=$(hostnamectl hostname 2>/dev/null || hostname)
    new=$(whiptail --inputbox "New hostname (short name, no FQDN; max 15 chars).\n\nNetBIOS limit is 15 chars. Examples: smbproxy-1, tps-bridge." 12 "$WT_WIDTH" "$cur" 3>&1 1>&2 2>&3) || return
    [[ -n "$new" ]] || return
    [[ "$new" =~ ^[a-zA-Z][a-zA-Z0-9-]{0,14}$ ]] || {
        whiptail --msgbox "Hostname must start with a letter, only [a-zA-Z0-9-], 1-15 chars (NetBIOS limit)." 9 "$WT_WIDTH"
        return
    }
    sudo hostnamectl set-hostname "$new"
    sudo sed -i "s/\\b${cur}\\b/${new}/g" /etc/hosts
    whiptail --msgbox "Hostname is now ${new}. Reboot recommended after marking setup complete." 9 "$WT_WIDTH"
}

show_firstboot_log() {
    if [[ -f /var/log/smbproxy-firstboot.log ]]; then
        whiptail --title "/var/log/smbproxy-firstboot.log" --scrolltext \
            --textbox /var/log/smbproxy-firstboot.log "$WT_HEIGHT" "$WT_WIDTH"
    else
        whiptail --msgbox "No smbproxy-firstboot log yet (firstboot may not have run)." 8 60
    fi
}

set_timezone() {
    local cur suggested prefill new
    cur=$(timedatectl show --property=Timezone --value 2>/dev/null || echo Etc/UTC)
    suggested=""
    if [[ -n "$(ip route show default 2>/dev/null)" ]]; then
        suggested=$(timeout 5 curl -fsS https://ipapi.co/timezone 2>/dev/null \
                     | tr -d '\r\n[:space:]')
        case "$suggested" in
            */*|UTC|Etc/UTC) ;;
            *) suggested="" ;;
        esac
    fi
    prefill="${suggested:-$cur}"
    local prompt="Current timezone: ${cur}"
    [[ -n "$suggested" && "$suggested" != "$cur" ]] && \
        prompt+="\nNetwork-based suggestion: ${suggested}"
    prompt+="\n\nEnter Region/City. Examples:\n  America/Los_Angeles  Europe/London  Asia/Tokyo  Etc/UTC"
    new=$(whiptail --inputbox "$prompt" 14 "$WT_WIDTH" "$prefill" 3>&1 1>&2 2>&3) || return
    [[ -n "$new" ]] || return
    if timedatectl list-timezones 2>/dev/null | grep -qx "$new"; then
        sudo timedatectl set-timezone "$new"
        whiptail --msgbox "Timezone is now: $(timedatectl show --property=Timezone --value)\n\nLocal time: $(date)" 11 "$WT_WIDTH"
    else
        whiptail --msgbox "Unknown timezone: $new\n\nUse 'Region/City' as listed by:\n  timedatectl list-timezones" 11 "$WT_WIDTH"
    fi
}

mark_done_tui() {
    if [[ -f "$DEFAULT_PWD_MARKER" ]]; then
        whiptail --msgbox "Change the ${SELF_USER} password before marking setup complete.\n\nThe default password is documented and trivially findable." 11 "$WT_WIDTH"
        return
    fi
    load_roles
    if [[ -z "$DOMAIN_NIC_NAME" || -z "$LEGACY_NIC_NAME" ]]; then
        if ! whiptail --yesno "NIC roles are not assigned yet.\n\nMark complete anyway? You can still assign roles later from smbproxy-sconfig, but the appliance will not work as a proxy until both roles are set." 12 "$WT_WIDTH"; then
            return
        fi
    fi
    whiptail --yesno "Mark initial setup complete?\n\n  - This wizard will not run on subsequent boots.\n  - The next reboot of this VM gives you a normal login prompt.\n  - You can re-arm with: cp /usr/local/sbin/smbproxy-init.getty-dropin\n    /etc/systemd/system/getty@tty1.service.d/smbproxy-init.conf\n    && rm /var/lib/smbproxy-init.done && reboot." 16 "$WT_WIDTH" || return

    sudo touch "$MARKER"
    if [[ -f "$GETTY_DROPIN" ]]; then
        sudo rm -f "$GETTY_DROPIN"
        sudo systemctl daemon-reload
    fi
    whiptail --msgbox "Setup marked complete.\n\nReboot or run 'sudo systemctl restart getty@tty1.service' to drop the autologin and pick up the normal login prompt." 13 "$WT_WIDTH"
    exit 0
}

# ----------------------------------------------------------------------------
# Outer text-mode menu — what the operator sees first on the console.
# ----------------------------------------------------------------------------
print_banner() {
    load_detect_env
    load_roles
    clear
    local hn tz
    hn=$(hostnamectl hostname 2>/dev/null || hostname)
    tz=$(timedatectl show --property=Timezone --value 2>/dev/null || echo Etc/UTC)
    cat <<BAN
==============================================================
  SMB1↔SMB3 Proxy Appliance — initial setup
==============================================================
BAN
    printf '  Host: %-18s  TZ: %s\n' "$hn" "$tz"
    if [[ -n "$DOMAIN_NIC_NAME" ]]; then
        printf '  Domain NIC: %-12s (mac=%s)\n' "$DOMAIN_NIC_NAME" "$DOMAIN_NIC_MAC"
    else
        printf '  Domain NIC: NOT ASSIGNED\n'
    fi
    if [[ -n "$LEGACY_NIC_NAME" ]]; then
        printf '  Legacy NIC: %-12s (mac=%s)\n' "$LEGACY_NIC_NAME" "$LEGACY_NIC_MAC"
    else
        printf '  Legacy NIC: NOT ASSIGNED\n'
    fi
    printf '  Default route: %-15s  GW: %s\n' \
        "${DET_DEFAULT_IP:-<none>}" "${DET_DEFAULT_GATEWAY:-<none>}"
    [[ -f "$DEFAULT_PWD_MARKER" ]] && \
        echo "  Default password ACTIVE — change before remote use"
    [[ -f /var/run/reboot-required ]] && \
        echo "  REBOOT REQUIRED — pick [R] to apply pending kernel/library upgrades"
    echo "=============================================================="
}

action_update() {
    clear
    echo "Refreshing apt indexes and applying upgrades (full-upgrade)..."
    echo "Note: full-upgrade can install new dependencies (kernels, etc.)."
    echo "      Plain 'apt-get upgrade' would silently keep them back."
    echo
    if command -v appcore_apt_run_full_upgrade >/dev/null 2>&1; then
        sudo DEBIAN_FRONTEND=noninteractive bash -c \
            'source /usr/local/lib/appliance-core/apt-helpers.sh; appcore_apt_run_full_upgrade'
    else
        sudo apt-get update -qq && sudo DEBIAN_FRONTEND=noninteractive apt-get -y full-upgrade
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
        echo "  Pick [R] from the menu (or run 'sudo reboot') to apply."
    else
        echo "  Done. No reboot required."
    fi
    echo "=============================================================="
    echo "  Press Enter to return to the menu."
    read -r _
}

action_set_password() {
    clear
    echo "Set the ${SELF_USER} password and enable SSH password auth."
    echo "Until now, SSH only accepts the build operator's pre-baked key."
    echo
    local p1 p2
    while true; do
        read -srp "  New password (min 12 chars): " p1; echo
        if [[ ${#p1} -lt 12 ]]; then echo "  Too short."; continue; fi
        read -srp "  Confirm:                      " p2; echo
        if [[ "$p1" != "$p2" ]]; then echo "  Mismatch."; continue; fi
        break
    done
    echo "${SELF_USER}:${p1}" | sudo chpasswd
    echo "PasswordAuthentication yes" | \
        sudo tee /etc/ssh/sshd_config.d/99-smbproxy-init-password.conf >/dev/null
    sudo systemctl reload ssh 2>/dev/null || sudo systemctl reload sshd 2>/dev/null || true
    sudo rm -f "$DEFAULT_PWD_MARKER"
    echo
    echo "  Password set. SSH password auth enabled."
    echo "  Press Enter."
    read -r _
}

action_run_tui() {
    while true; do
        local choice
        choice=$(whiptail --title "smbproxy-init — interactive setup (TUI)" --nocancel \
            --menu "Detailed steps. [B] returns to the outer text menu." \
            "$WT_HEIGHT" "$WT_WIDTH" "$WT_MENU" \
            "1" "Show network & setup status" \
            "2" "Assign NIC roles (domain vs legacy by MAC)" \
            "3" "Configure network (domain DHCP/static, legacy static)" \
            "4" "Change ${SELF_USER} password" \
            "5" "Add an SSH authorized_keys entry" \
            "6" "Set hostname (NetBIOS-safe short name)" \
            "7" "Set timezone (with optional network hint)" \
            "8" "Show smbproxy-firstboot log" \
            "S" "Drop to a root shell" \
            "D" "Mark setup complete and proceed to login" \
            "B" "Back to outer text menu" \
            3>&1 1>&2 2>&3)
        case "$choice" in
            1) show_status ;;
            2) assign_nic_roles ;;
            3) config_network ;;
            4) change_password ;;
            5) add_ssh_key ;;
            6) set_hostname ;;
            7) set_timezone ;;
            8) show_firstboot_log ;;
            S|s) clear; sudo bash; ;;
            D|d) mark_done_tui ;;
            B|b|"") return ;;
        esac
    done
}

action_shell() {
    clear
    echo "Dropping to a root shell. 'exit' returns to this menu."
    sudo bash || true
}

action_halt() {
    clear; echo "Halting in 3s — Ctrl-C to abort."; sleep 3
    sudo systemctl poweroff
    exec sleep 60
}

action_reboot() {
    clear; echo "Rebooting in 3s — Ctrl-C to abort."; sleep 3
    sudo systemctl reboot
    exec sleep 60
}

action_mark_done_outer() {
    if [[ -f "$DEFAULT_PWD_MARKER" ]]; then
        echo
        echo "  Cannot mark complete: ${SELF_USER} still has the factory default"
        echo "  password. Pick [P] to change it first."
        echo "  Press Enter."
        read -r _
        return
    fi
    sudo touch "$MARKER"
    if [[ -f "$GETTY_DROPIN" ]]; then
        sudo rm -f "$GETTY_DROPIN"
        sudo systemctl daemon-reload
    fi
    echo
    echo "  Setup marked complete. Dropping to a normal login shell."
    sleep 1
    exec /bin/bash --login
}

action_quit() {
    echo "  Skipping menu for this boot only. exec'ing /bin/bash --login."
    sleep 1
    exec /bin/bash --login
}

while true; do
    print_banner
    read -r upg sec < <(count_upgrades)
    echo
    if [[ "$upg" -gt 0 ]] 2>/dev/null; then
        printf '  [U] Update OS (%d pending, %d security)\n' "$upg" "$sec"
    fi
    echo  "  [P] Set ${SELF_USER} password (also enables SSH password auth)"
    echo  "  [I] Interactive setup wizard (TUI: NIC roles, network, hostname, ...)"
    echo  "  [S] Root shell    [D] Mark setup complete    [Q] Skip menu"
    echo  "  [H] Halt          [R] Reboot"
    echo
    read -rp "  > " choice
    case "${choice^^}" in
        U) [[ "$upg" -gt 0 ]] 2>/dev/null && action_update ;;
        P) action_set_password ;;
        I) action_run_tui ;;
        S) action_shell ;;
        D) action_mark_done_outer ;;
        H) action_halt ;;
        R) action_reboot ;;
        Q) action_quit ;;
        *) ;;
    esac
done
INITEOF
chmod +x /usr/local/sbin/smbproxy-init

# TTY1 autologin override.
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /usr/local/sbin/smbproxy-init.getty-dropin <<'GETTYEOF'
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin debadmin --noclear --keep-baud %I 115200,38400,9600 $TERM
Type=idle
GETTYEOF
cp /usr/local/sbin/smbproxy-init.getty-dropin \
   /etc/systemd/system/getty@tty1.service.d/smbproxy-init.conf

# debadmin's profile launches the wizard on TTY1 only.
mkdir -p /home/debadmin
cat > /home/debadmin/.profile <<'PROFILEEOF'
# Auto-launch smbproxy-init on TTY1 only, while initial setup is pending.
# SSH and other TTYs fall through to a normal shell.
if [[ -t 0 ]] && [[ "$(tty)" == "/dev/tty1" ]] && [[ ! -f /var/lib/smbproxy-init.done ]]; then
    exec /usr/local/sbin/smbproxy-init
fi
PROFILEEOF
chown debadmin:debadmin /home/debadmin/.profile 2>/dev/null || true

#===============================================================================
# 21. NETWORK-AWARE LOGIN BANNER (MOTD)
#===============================================================================
log "Installing smbproxy-net-status MOTD generator..."
cat > /etc/update-motd.d/15-smbproxy-net-status <<'MOTDEOF'
#!/bin/sh
DET=/var/lib/smbproxy-init-detected.env
ROLES=/etc/smbproxy/nic-roles.env
[ -r "$DET" ]   && . "$DET"   2>/dev/null
[ -r "$ROLES" ] && . "$ROLES" 2>/dev/null
printf '\n  SMB1↔SMB3 Protocol Gateway\n'
printf '  --------------------------\n'
printf '  Hostname:    %s\n' "$(hostnamectl hostname 2>/dev/null || hostname)"
if [ -n "$DOMAIN_NIC_NAME" ]; then
    printf '  Domain NIC:  %s (mac=%s)\n' "$DOMAIN_NIC_NAME" "$DOMAIN_NIC_MAC"
else
    printf '  Domain NIC:  not assigned (run smbproxy-init at console)\n'
fi
if [ -n "$LEGACY_NIC_NAME" ]; then
    printf '  Legacy NIC:  %s (mac=%s)\n' "$LEGACY_NIC_NAME" "$LEGACY_NIC_MAC"
else
    printf '  Legacy NIC:  not assigned\n'
fi
printf '  Network:\n'
ip -br addr show 2>/dev/null | awk 'NF>0 && $1!="lo" {printf "    %s\n", $0}'
gw=$(ip route show default 2>/dev/null | awk '/default/ {print $3" via "$5; exit}')
[ -n "$gw" ] && printf '  Default route: %s\n' "$gw" || printf '  Default route: (none)\n'
if dns=$(resolvectl dns 2>/dev/null | awk '/^Link [0-9]/ {for(i=4;i<=NF;i++) printf "%s ", $i}'); [ -n "$dns" ]; then
    printf '  DNS:         %s\n' "$dns"
fi
printf '  Setup wizard: %s\n' "$([ -f /var/lib/smbproxy-init.done ] && echo done || echo 'PENDING — open the console for the wizard')"
smbd_state=$(systemctl is-active smbd 2>/dev/null || true)
wb_state=$(systemctl is-active winbind 2>/dev/null || true)
printf '  smbd:         %s\n' "${smbd_state:-unavailable}"
printf '  winbind:      %s\n' "${wb_state:-unavailable}"
if [ ! -f /etc/samba/smb.conf ]; then
    printf '  Next step:   sudo smbproxy-sconfig (Domain Operations -> Join existing forest)\n'
fi
printf '\n'
MOTDEOF
chmod +x /etc/update-motd.d/15-smbproxy-net-status

#===============================================================================
# 21B. SR-IOV VF KERNEL-PANIC WORKAROUND (ixgbevf)
#===============================================================================
# FIXME(remove-when-fixed): Defensive blacklist of `ixgbevf` (Intel 10G VF
# driver). Background: Linux 6.12 (Debian trixie kernel 6.12.74) panics
# very early in `ixgbevf_negotiate_api()` on at least one combination of
# host firmware ("Hyper-V UEFI Release v4.1 09/25/2025") and Intel
# 82599/X540/X550 PFs when Hyper-V passes the SR-IOV virtual function
# through to the guest. Symptom on the affected host:
#
#   RIP: 0010:0x0
#   Call Trace: ixgbevf_negotiate_api+0x66 -> ixgbevf_probe+0x2ff ->
#               local_pci_probe -> work_for_cpu_fn
#   Kernel panic - not syncing: Fatal exception in interrupt
#
# Outcome: VM never finishes booting on hosts that expose the VF.
#
# This appliance does not need raw NIC passthrough — the synthetic
# `hv_netvsc` (or virtio-net on KVM, vmxnet3 on VMware) NIC is the
# expected datapath, and SMB1<->SMB3 proxy throughput is nowhere near
# what would justify SR-IOV. Blacklisting `ixgbevf` is therefore safe
# and the operator-side workaround (set IovWeight 0 on the Hyper-V
# vNIC) becomes optional rather than mandatory.
#
# How to remove or improve this in the future:
#   1. When Debian ships a kernel where ixgbevf has been verified
#      against this firmware combination (track LKML / Debian
#      kernel-team bug for ixgbevf NULL-deref in negotiate_api),
#      drop /etc/modprobe.d/smbproxy-blacklist-ixgbevf.conf and
#      `update-initramfs -u`.
#   2. If the appliance ever genuinely needs SR-IOV passthrough for
#      throughput (it shouldn't — the legacy backend is SMB1, capped
#      at single-digit Gb/s practically), narrow the blacklist to a
#      modprobe.d match against the specific buggy device-id combo
#      instead of the whole driver.
#   3. Replace this defensive workaround with a Debian backport of
#      the upstream fix once one lands. Ideally the appliance should
#      not need to know about device-driver bugs.
log "Installing SR-IOV VF kernel-panic workaround (ixgbevf blacklist)..."
cat > /etc/modprobe.d/smbproxy-blacklist-ixgbevf.conf <<'BLEOF'
# FIXME(remove-when-fixed): see prepare-image.sh §21B for the full
# story. Short version: Linux 6.12 + Hyper-V UEFI v4.1 09/25/2025 +
# Intel 82599/X540/X550 PF panics in ixgbevf_negotiate_api when the
# SR-IOV VF is passed through. Appliance does not need passthrough —
# synthetic NIC is fine. Remove this file + `update-initramfs -u`
# once the kernel/firmware combo is verified working again.
blacklist ixgbevf
BLEOF
chmod 644 /etc/modprobe.d/smbproxy-blacklist-ixgbevf.conf

# Rebuild initramfs so the blacklist takes effect even if the panic
# would have happened before / during the initramfs phase. Fail soft —
# `update-initramfs` can warn about missing firmware on a freshly
# prepared image; that's not fatal here.
update-initramfs -u || log "  warning: update-initramfs returned non-zero (continuing)"

# Runtime detector: walks PCI to spot any Ethernet device the kernel
# left unbound (most often: this blacklist suppressing the SR-IOV VF
# the host is offering). Used by the MOTD warning below and safe to
# call from anywhere — read-only sysfs walk, no kernel calls.
log "Installing smbproxy-detect-unbound-nic helper..."
cat > /usr/local/sbin/smbproxy-detect-unbound-nic <<'DETEOF'
#!/usr/bin/env bash
# smbproxy-detect-unbound-nic — print one line per unbound Ethernet
# PCI device. Format: "BDF VENDOR:DEVICE [vendor-name] [device-name]".
# Exit 0 with empty output if everything is bound.
#
# Used to surface the ixgbevf-blacklist-suppressing-an-active-VF case
# in the MOTD without re-implementing the detection logic in the MOTD
# generator. See prepare-image.sh §21B for the why.
set -u
PATH=/usr/local/sbin:/usr/sbin:/usr/bin:/sbin:/bin
shopt -s nullglob
for d in /sys/bus/pci/devices/*; do
    class=$(cat "$d/class" 2>/dev/null || echo)
    # Class 0x020000 = Ethernet controller. Match the high two bytes.
    [[ "${class:0:6}" == "0x0200" ]] || continue
    [[ -e "$d/driver" ]] && continue          # already bound; nothing to flag
    bdf=$(basename "$d")
    vid=$(cat "$d/vendor" 2>/dev/null | sed 's/^0x//')
    did=$(cat "$d/device" 2>/dev/null | sed 's/^0x//')
    name=""
    if command -v lspci >/dev/null 2>&1; then
        name=$(lspci -s "$bdf" 2>/dev/null | sed 's/^[^ ]* //')
    fi
    printf '%s %s:%s %s\n' "$bdf" "$vid" "$did" "${name:-(unknown)}"
done
DETEOF
chmod +x /usr/local/sbin/smbproxy-detect-unbound-nic

# MOTD addition: only renders when the detector returns lines. The
# 16-* prefix puts it right under the 15-* network status block.
log "Installing smbproxy-vf-warning MOTD generator..."
cat > /etc/update-motd.d/16-smbproxy-vf-warning <<'MOTDEOF'
#!/bin/sh
# Surface the SR-IOV-VF-blacklisted-but-active-on-host case in the
# login banner. Silent when no unbound NIC is present.
unbound=$(/usr/local/sbin/smbproxy-detect-unbound-nic 2>/dev/null)
[ -z "$unbound" ] && exit 0

# ANSI red for the banner border so it's visually distinct from the
# normal status block. Falls back to plain text on terminals without
# color, which is fine — the message body is still readable.
RED=$(printf '\033[1;31m'); RST=$(printf '\033[0m')

printf '\n'
printf '%s======================================================================%s\n' "$RED" "$RST"
printf '%s  WARNING: SR-IOV / passthrough NIC detected but unbound%s\n' "$RED" "$RST"
printf '%s======================================================================%s\n' "$RED" "$RST"
printf '  This server has an Ethernet PCI device that the kernel did NOT\n'
printf '  bind a driver to. The most common cause is that the hypervisor is\n'
printf '  exposing an SR-IOV virtual function (typically Intel ixgbevf) to\n'
printf '  this VM, and the matching driver is blacklisted as a workaround\n'
printf '  for an early-boot kernel panic on certain Hyper-V UEFI firmware\n'
printf '  revisions.\n'
printf '\n'
printf '  Unbound device(s):\n'
printf '%s\n' "$unbound" | sed 's/^/    /'
printf '\n'
printf '  Why it matters:\n'
printf '    - The synthetic vNIC (hv_netvsc / virtio-net / vmxnet3) is in\n'
printf '      use instead. Network traffic operates normally.\n'
printf '    - SR-IOV optimizations and the dedicated bandwidth they would\n'
printf '      have provided are NOT in effect.\n'
printf '    - Without the blacklist, this VM would kernel-panic at boot on\n'
printf '      affected hosts.\n'
printf '\n'
printf '  How to silence this warning:\n'
printf '    Hyper-V (recommended):\n'
printf '      Set-VMNetworkAdapter -VMName <name> -IovWeight 0\n'
printf '      then reboot the VM. The PCI device disappears and this\n'
printf '      banner clears automatically on next login.\n'
printf '    Other hypervisors:\n'
printf '      detach the SR-IOV VF / disable passthrough on the vNIC.\n'
printf '\n'
printf '  Background:\n'
printf '    /etc/modprobe.d/smbproxy-blacklist-ixgbevf.conf describes the\n'
printf '    bug and the conditions under which the blacklist can be removed.\n'
printf '%s======================================================================%s\n' "$RED" "$RST"
printf '\n'
MOTDEOF
chmod +x /etc/update-motd.d/16-smbproxy-vf-warning

#===============================================================================
# 22. FINAL CLEANUP
#===============================================================================
log "Final cleanup..."
apt-get autoremove -y --purge
apt-get clean
rm -rf /var/lib/apt/lists/*
journalctl --vacuum-size=10M 2>/dev/null || true

unset DEBIAN_FRONTEND

#===============================================================================
# SUMMARY
#===============================================================================
echo ""
log "=========================================="
log " Image preparation complete."
log "=========================================="
echo ""
echo "  Samba:         $(samba --version 2>/dev/null || echo 'check manually')"
echo "  Chrony:        $(chronyc --version 2>/dev/null || echo 'check manually')"
echo "  cifs-utils:    $(dpkg -s cifs-utils 2>/dev/null | awk '/^Version:/{print $2}')"
echo "  Guest agents:  $(ls -1 /var/cache/smbproxy-appliance/vmtools/ 2>/dev/null | grep -v ^manifest$ | tr '\n' ' ')"
echo ""
echo "  Removed:       ${REMOVE_PKGS[*]}"
echo ""
echo "  Next steps:"
echo "    1. Shut down this VM. The shutdown-state disk is the host-agnostic"
echo "       deploy master — copy/export it to any hypervisor you want."
echo "    2. On a deployed VM's first boot, smbproxy-firstboot.service will"
echo "       detect the actual hypervisor, install the matching guest agent"
echo "       offline, enumerate NICs, and print recommended VM hardware."
echo "    3. The console TTY1 wizard (smbproxy-init) walks the operator"
echo "       through NIC role assignment by MAC, network configuration,"
echo "       password change, SSH key paste, hostname, and timezone."
echo "    4. After that, log in over SSH and run 'sudo smbproxy-sconfig' to"
echo "       join the WS2025 forest, configure the backend SMB1 mount, and"
echo "       publish the frontend SMB3 share."
echo ""
