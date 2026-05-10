#!/usr/bin/env bash
#===============================================================================
# stage-proxy-base.sh - Mac-side staging for the SMB1<->SMB3 proxy appliance
#
# Produces two files on the ISO share (/Volumes/ISO by default,
# = D:\ISO\ on the Hyper-V host):
#
#   debian-13-smbproxy-base.vhdx  ~1.2 GB - Debian genericcloud qcow2 converted.
#                                  Built once, reused for every proxy VM you make.
#   <hostname>-seed.iso           ~1 MB - NoCloud cloud-init seed for one VM.
#
# The per-VM seed encodes hostname, the appliance admin user, the SSH
# pubkey set, and the MAC address that pins the *domain* NIC. That MAC is
# the link between dnsmasq (which hands out the reserved 10.10.10.30 lease
# when it sees that MAC) and the cloud-init network config (which DHCPs
# the matching interface). The *legacy* NIC is intentionally left out of
# cloud-init; smbproxy-init's role wizard sets its static IP later.
#
# A VM created from these two files boots, applies cloud-init once, and
# is immediately reachable over SSH from the Mac on its dnsmasq-reserved
# IP. No vmconnect clicks, no Debian installer wait, no manual
# sudoers / authorized_keys setup.
#
# The cached qcow2 is shared with samba-addc-appliance/lab/ — the first
# repo to fetch it primes the cache for the other.
#
# Usage:
#   lab/stage-proxy-base.sh                                # smbproxy-1 / lab.test
#   lab/stage-proxy-base.sh -n smbproxy-2 -i 10.10.10.31 -m 00155D0A0A1F
#   lab/stage-proxy-base.sh -u debadmin -k ~/.ssh/lab.pub
#===============================================================================
set -euo pipefail

HOSTNAME='smbproxy-1'
DOMAIN='lab.test'
USERNAME='debadmin'
STAGE_DIR='/Volumes/ISO'
ARCH='amd64'           # only amd64 implemented today; arm64 expected per dev-commons/CONTEXT.md
DEBIAN_URL=''           # derived from $ARCH after arg parse

# Domain-NIC MAC pinned by lab/hyperv/New-SmbProxyTestVM.ps1. The default
# 00:15:5D:0A:0A:1E maps to dnsmasq reservation 10.10.10.30 (smbproxy-1).
# Last-octet pattern: 0A14=20 samba-dc1, 0A1E=30 smbproxy-1, etc.
DOMAIN_MAC='00155D0A0A1E'
DOMAIN_IP='10.10.10.30'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEED_SRC="$SCRIPT_DIR/templates/cloud-init"
KEYS_DIR="$SCRIPT_DIR/keys"

# Single-pubkey legacy override; if -k FILE is passed we ignore $KEYS_DIR.
SSH_PUBKEY_FILE=""
ALLOW_NO_KEYS=0

die() { echo "error: $*" >&2; exit 1; }

usage() {
    sed -n '/^# Usage:/,/^$/p' "$0" | sed 's/^# \{0,1\}//'
    cat <<EOF

Options:
  -n, --hostname NAME     VM short hostname (default: $HOSTNAME)
  -d, --domain NAME       DNS domain (default: $DOMAIN)
  -u, --user NAME         appliance admin user (default: $USERNAME)
  -m, --mac MAC           Domain-NIC MAC, no separators (default: $DOMAIN_MAC)
  -i, --ip IP             Expected dnsmasq-reserved IP for that MAC
                          (default: $DOMAIN_IP). Used in template comments
                          only — the actual reservation is in lab-router.
  -k, --pubkey FILE       Single SSH pubkey file (legacy; overrides
                          lab/keys/ if used).
      --allow-no-keys     Build a master with no SSH keys (console-only
                          login via the wizard's [P]assword action).
  -s, --stage-dir DIR     output directory (default: $STAGE_DIR)
  -a, --arch ARCH         Debian cloud-image architecture (default: $ARCH).
                          Only 'amd64' is implemented today; 'arm64' is
                          expected within ~6 months per
                          dev-commons/CONTEXT.md.
  -h, --help              show this

Default key source is lab/keys/*.pub. Drop your team's pubkey files
there; one '      - <key>' line is generated per file. See
lab/keys/README.md for details.
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--hostname)    HOSTNAME="$2";        shift 2 ;;
        -d|--domain)      DOMAIN="$2";          shift 2 ;;
        -u|--user)        USERNAME="$2";        shift 2 ;;
        -m|--mac)         DOMAIN_MAC="$2";      shift 2 ;;
        -i|--ip)          DOMAIN_IP="$2";       shift 2 ;;
        -k|--pubkey)      SSH_PUBKEY_FILE="$2"; shift 2 ;;
        --allow-no-keys)  ALLOW_NO_KEYS=1;      shift ;;
        -s|--stage-dir)   STAGE_DIR="$2";       shift 2 ;;
        -a|--arch)        ARCH="$2";            shift 2 ;;
        -h|--help)        usage; exit 0 ;;
        *)                die "unknown arg: $1" ;;
    esac
done

# Today only amd64 is implemented end-to-end. arm64 will land when the
# first arm64 appliance does (per dev-commons/SUPPORTED-ENVIRONMENTS.md);
# the interface accepts it now so call-sites don't need to change.
case "$ARCH" in
    amd64) DEBIAN_URL="https://cloud.debian.org/images/cloud/trixie/latest/debian-13-genericcloud-amd64.qcow2" ;;
    arm64) die "arm64 staging not implemented yet — see dev-commons/CONTEXT.md for the timeline" ;;
    *)     die "unsupported --arch: $ARCH (allowed: amd64, arm64)" ;;
esac

command -v qemu-img >/dev/null || die "qemu-img not on PATH (brew install qemu)"
command -v hdiutil  >/dev/null || die "hdiutil missing (built-in on macOS)"
command -v curl     >/dev/null || die "curl not on PATH"
[[ -d "$STAGE_DIR" ]]              || die "stage dir not mounted: $STAGE_DIR"
[[ -d "$SEED_SRC" ]]               || die "seed templates dir not found: $SEED_SRC"
for tpl in user-data-proxy.tpl meta-data.tpl network-config.tpl; do
    [[ -f "$SEED_SRC/$tpl" ]] || die "template missing: $SEED_SRC/$tpl"
done

# Normalize MAC: accept 00155D0A0A1E or 00:15:5D:0A:0A:1E, produce both.
mac_compact=$(echo "$DOMAIN_MAC" | tr -d ':-' | tr 'a-f' 'A-F')
[[ "$mac_compact" =~ ^[0-9A-F]{12}$ ]] || die "bad MAC: $DOMAIN_MAC (need 12 hex chars or colon-separated)"
DOMAIN_MAC_COLON=$(echo "$mac_compact" | sed 's/\(..\)/\1:/g; s/:$//' | tr 'A-F' 'a-f')

FQDN="${HOSTNAME}.${DOMAIN}"

# Build the multi-line ssh_authorized_keys block. Each pubkey line
# becomes a YAML list entry indented to match user-data-proxy.tpl's
# six-space indent.
SSH_KEYS_BLOCK=""
KEY_SOURCES=""
add_key_line() {
    local raw="$1"
    [[ -z "$raw" || "$raw" =~ ^# ]] && return
    SSH_KEYS_BLOCK+="      - ${raw}"$'\n'
}
if [[ -n "$SSH_PUBKEY_FILE" ]]; then
    [[ -f "$SSH_PUBKEY_FILE" ]] || die "ssh pubkey not found: $SSH_PUBKEY_FILE"
    while IFS= read -r line; do add_key_line "$line"; done < "$SSH_PUBKEY_FILE"
    KEY_SOURCES="$SSH_PUBKEY_FILE"
elif [[ -d "$KEYS_DIR" ]]; then
    shopt -s nullglob
    for f in "$KEYS_DIR"/*.pub; do
        while IFS= read -r line; do add_key_line "$line"; done < "$f"
        KEY_SOURCES+="$f "
    done
    shopt -u nullglob
fi
if [[ -z "$SSH_KEYS_BLOCK" ]]; then
    if [[ $ALLOW_NO_KEYS -eq 1 ]]; then
        # Empty block — cloud-init renders 'ssh_authorized_keys:' with no
        # entries, which is valid YAML and means "no keys".
        :
    else
        die "no SSH pubkeys (drop *.pub files in $KEYS_DIR, or pass -k FILE, or --allow-no-keys)"
    fi
fi

echo "=== stage-proxy-base.sh"
echo "  hostname:    $HOSTNAME"
echo "  fqdn:        $FQDN"
echo "  user:        $USERNAME"
echo "  arch:        $ARCH"
echo "  domain MAC:  $DOMAIN_MAC_COLON"
echo "  domain IP:   $DOMAIN_IP (expected from dnsmasq)"
echo "  pubkeys:     ${KEY_SOURCES:-<none — --allow-no-keys>}"
echo "  stage dir:   $STAGE_DIR"

#---- 1. base VHDX (shared across all proxy VMs) ----
CACHE_QCOW2="$STAGE_DIR/debian-13-genericcloud-${ARCH}.qcow2"
OUT_VHDX="$STAGE_DIR/debian-13-smbproxy-base.vhdx"

if [[ ! -f "$OUT_VHDX" ]]; then
    if [[ ! -f "$CACHE_QCOW2" ]]; then
        echo "-> downloading Debian 13 genericcloud qcow2 (~300 MB)"
        curl -fSL -o "$CACHE_QCOW2" "$DEBIAN_URL"
    else
        echo "-> using cached qcow2 at $CACHE_QCOW2"
    fi

    # qemu-img cannot lock across SMB on macOS; convert in /tmp then move.
    echo "-> converting qcow2 -> vhdx (~60s)"
    tmp_qcow=$(mktemp /tmp/smbproxy-base-XXXX.qcow2)
    tmp_vhdx=$(mktemp /tmp/smbproxy-base-XXXX.vhdx)
    # shellcheck disable=SC2064  # tmp_qcow/tmp_vhdx are mktemp paths set above; expand-now is intentional
    trap "rm -f '$tmp_qcow' '$tmp_vhdx'" EXIT
    cp "$CACHE_QCOW2" "$tmp_qcow"
    qemu-img convert -O vhdx -o subformat=dynamic "$tmp_qcow" "$tmp_vhdx"
    cp "$tmp_vhdx" "$OUT_VHDX"
    rm -f "$tmp_qcow" "$tmp_vhdx"
    trap - EXIT
    echo "-> wrote $OUT_VHDX ($(du -h "$OUT_VHDX" | cut -f1))"
else
    echo "-> base VHDX already present at $OUT_VHDX - skipping convert"
fi

#---- 2. NoCloud seed ISO (per-VM) ----
SEED_BUILD_DIR=$(mktemp -d /tmp/seed-smbproxy-XXXX)
SEED_OUT="$STAGE_DIR/${HOSTNAME}-seed.iso"

substitute() {
    sed \
        -e "s|@@HOSTNAME@@|$HOSTNAME|g" \
        -e "s|@@FQDN@@|$FQDN|g" \
        -e "s|@@DOMAIN@@|$DOMAIN|g" \
        -e "s|@@USERNAME@@|$USERNAME|g" \
        -e "s|@@DOMAIN_MAC_COLON@@|$DOMAIN_MAC_COLON|g" \
        -e "s|@@DOMAIN_IP@@|$DOMAIN_IP|g" \
        "$1"
}

# user-data-proxy.tpl has a multi-line @@SSH_KEYS_BLOCK@@ placeholder
# that sed can't insert multi-line content for cleanly. awk handles the
# placeholder line first, then sed substitutes the single-token vars.
SSH_KEYS_BLOCK="$SSH_KEYS_BLOCK" \
awk '
    /^[[:space:]]*@@SSH_KEYS_BLOCK@@[[:space:]]*$/ {
        printf "%s", ENVIRON["SSH_KEYS_BLOCK"]
        next
    }
    { print }
' "$SEED_SRC/user-data-proxy.tpl" | substitute /dev/stdin > "$SEED_BUILD_DIR/user-data"

substitute "$SEED_SRC/meta-data.tpl"        > "$SEED_BUILD_DIR/meta-data"
substitute "$SEED_SRC/network-config.tpl"   > "$SEED_BUILD_DIR/network-config"

# hdiutil makehybrid won't overwrite — clear any prior copy first.
rm -f "$SEED_OUT"
hdiutil makehybrid -iso -joliet \
    -default-volume-name CIDATA \
    -o "$SEED_OUT" "$SEED_BUILD_DIR" >/dev/null

rm -rf "$SEED_BUILD_DIR"
echo "-> wrote $SEED_OUT ($(du -h "$SEED_OUT" | cut -f1))"

echo ""
echo "Build the VM with:"
echo "  ssh <host-user>@<hyper-v-host> 'pwsh -File D:\\ISO\\lab-scripts\\New-SmbProxyTestVM.ps1 \\"
echo "      -VMName ${HOSTNAME} -SeedIso D:\\ISO\\${HOSTNAME}-seed.iso \\"
echo "      -DomainStaticMacAddress ${mac_compact} -Start'"
echo ""
echo "Or run the end-to-end build (stage + create + prepare + checkpoint):"
echo "  lab/build-fresh-base.sh -n ${HOSTNAME}"
