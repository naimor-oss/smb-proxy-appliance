#!/usr/bin/env bash
#===============================================================================
# build-fresh-base.sh - End-to-end "fresh appliance image" build (proxy).
#
# This is the one-shot replacement for the manual netinst flow. It:
#
#   1. Stages base VHDX + per-VM seed ISO via lab/stage-proxy-base.sh
#   2. Copies host-side helper scripts (incl. New-SmbProxyTestVM.ps1) to
#      the Hyper-V host's lab-scripts share
#   3. Optionally removes any existing VM by the same name (-f)
#   4. Creates a Hyper-V VM from the staged artifacts and starts it
#   5. Waits for cloud-init to bring SSH up on the VM's reserved IP
#   6. scp's prepare-image.sh + smbproxy-sconfig.sh to /tmp on the VM and
#      runs prepare-image.sh
#   7. Snapshots the powered-off VM as `deploy-master` (host-agnostic)
#   8. Boots once to fire smbproxy-firstboot, snapshots as `golden-image`
#
# After this, lab/run-scenario.sh smoke-prepared-image / ... can revert
# to the new golden-image checkpoint and run their own pipelines.
#
# Defaults track lab/proxy.env (smbproxy-1 / 10.10.10.30 / debadmin /
# MAC 00155D0A0A1E); override via env vars or flags.
#
# The lab reuses the samba-addc-appliance lab environment: same router1,
# same Lab-NAT, same WS2025-DC1 the proxy will join. The LegacyZone
# private switch is persistent infrastructure carrying the legacy SMB1
# backend — this script does not stand it up.
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# Defaults intentionally match lab/proxy.env so a flagless invocation
# produces smbproxy-1 ready for the existing scenarios.
VM_NAME="${VM_NAME:-smbproxy-1}"
VM_IP="${VM_IP:-10.10.10.30}"
VM_USER="${VM_USER:-debadmin}"
HV_HOST="${HV_HOST:-server}"
HV_USER="${HV_USER:-nmadmin}"
STAGE_DIR_MAC="${LAB_STAGE_DIR:-/Volumes/ISO/lab-scripts}"
STAGE_DIR_HOST="${LAB_HOST_STAGE_DIR:-D:\\ISO\\lab-scripts}"
ISO_DIR_MAC="${ISO_DIR_MAC:-/Volumes/ISO}"
DOMAIN="${DOMAIN:-lab.test}"
# Empty by default so the stager picks up lab/keys/*.pub (the
# documented multi-key path). Operators can still pin a single key
# with -k/--pubkey or by exporting SSH_PUBKEY=...; if neither is set
# AND lab/keys/ has no .pub files, we fall back to the operator's
# personal key after arg parsing — see below.
SSH_PUBKEY="${SSH_PUBKEY:-}"
GOLDEN_CHECKPOINT="${GOLDEN_CHECKPOINT:-golden-image}"
DOMAIN_STATIC_MAC="${DOMAIN_STATIC_MAC:-00155D0A0A1E}"
LEGACY_STATIC_MAC="${LEGACY_STATIC_MAC:-}"

FORCE=0
DEPLOY_ONLY=0

usage() {
    cat <<USAGE
Usage: lab/build-fresh-base.sh [flags]

Flags:
  -n, --vm-name NAME     Hyper-V VM name (default: $VM_NAME)
  -i, --vm-ip IP         Reserved LAN IP, domain NIC (default: $VM_IP)
  -u, --vm-user USER     Appliance admin user (default: $VM_USER)
  -m, --mac MAC          Pinned domain-NIC MAC, no separators
                         (default: $DOMAIN_STATIC_MAC)
      --legacy-mac MAC   Optional pinned legacy-NIC MAC (default: auto)
  -d, --domain DOMAIN    DNS domain for the appliance hostname
                         (default: $DOMAIN)
  -k, --pubkey FILE      SSH public key (default: lab/keys/*.pub, then
                         ~/.ssh/id_ed25519.pub if lab/keys/ is empty)
  -f, --force            Remove the VM and its diff VHDX first if present
      --deploy-only      Stop after the host-agnostic 'deploy-master'
                         snapshot. Skip the firstboot pass and the
                         'golden-image' snapshot — useful when the
                         build's only purpose is to produce dist
                         artifacts (lab/export-deploy-master.sh) for
                         testing in a different hypervisor environment.
  -h, --help             Show this

Environment overrides: HV_HOST, HV_USER, ISO_DIR_MAC, GOLDEN_CHECKPOINT,
LAB_STAGE_DIR, LAB_HOST_STAGE_DIR.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--vm-name)    VM_NAME="$2";           shift 2 ;;
        -i|--vm-ip)      VM_IP="$2";             shift 2 ;;
        -u|--vm-user)    VM_USER="$2";           shift 2 ;;
        -m|--mac)        DOMAIN_STATIC_MAC="$2"; shift 2 ;;
        --legacy-mac)    LEGACY_STATIC_MAC="$2"; shift 2 ;;
        -d|--domain)     DOMAIN="$2";            shift 2 ;;
        -k|--pubkey)     SSH_PUBKEY="$2";        shift 2 ;;
        -f|--force)      FORCE=1; shift ;;
        --deploy-only)   DEPLOY_ONLY=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

say()  { echo "--- [$(date -u +%H:%M:%S)] $*"; }
step() { echo
         echo "=============================================================="
         echo "=== $*"
         echo "=============================================================="; }

ssh_host() { ssh "${HV_USER}@${HV_HOST}" "$@"; }
ssh_vm()   { ssh -J "${HV_USER}@${HV_HOST}" \
                 -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
                 "${VM_USER}@${VM_IP}" "$@"; }

# 0. Tear down any existing VM first. The DVD attachment of the prior seed
# ISO (mounted on the dead VM) locks the file across the SMB share — if we
# stage before destroying the VM, the seed ISO write fails with "Resource
# busy". Doing this up front guarantees stage has a clean slate.
if [[ $FORCE -eq 1 ]]; then
    step "0. force flag set: tearing down existing $VM_NAME if present"
    ssh_host "Stop-VM -Name '$VM_NAME' -Force -ErrorAction SilentlyContinue; \
              Remove-VM -Name '$VM_NAME' -Force -ErrorAction SilentlyContinue; \
              Remove-Item -LiteralPath 'D:\\Lab\\$VM_NAME' -Recurse -Force -ErrorAction SilentlyContinue; \
              Write-Host 'cleaned'"
fi

# Resolve key source: prefer lab/keys/ (multi-key path), fall back to
# operator's personal key only if lab/keys/ is empty AND no -k was
# given. Forwarding `-k` to the stager forces single-key mode and
# bypasses lab/keys/, so we only forward when an explicit key was set.
STAGER_KEY_ARGS=()
if [[ -n "$SSH_PUBKEY" ]]; then
    STAGER_KEY_ARGS=(-k "$SSH_PUBKEY")
else
    keys_dir="$SCRIPT_DIR/keys"
    have_keys=0
    for f in "$keys_dir"/*.pub; do
        [[ -f "$f" ]] && { have_keys=1; break; }
    done
    if [[ $have_keys -eq 0 ]]; then
        STAGER_KEY_ARGS=(-k "$HOME/.ssh/id_ed25519.pub")
    fi
fi

step "1. stage base VHDX + seed ISO"
"$SCRIPT_DIR/stage-proxy-base.sh" \
    -n "$VM_NAME" -d "$DOMAIN" -u "$VM_USER" "${STAGER_KEY_ARGS[@]}" \
    -m "$DOMAIN_STATIC_MAC" -i "$VM_IP" -s "$ISO_DIR_MAC"

step "2. push host-side helper scripts to $STAGE_DIR_HOST"
mkdir -p "$STAGE_DIR_MAC"
cp -f "$SCRIPT_DIR/hyperv/"*.ps1 "$STAGE_DIR_MAC/"
ls -la "$STAGE_DIR_MAC/New-SmbProxyTestVM.ps1"

step "3. create Hyper-V VM $VM_NAME"
LEGACY_ARG=""
[[ -n "$LEGACY_STATIC_MAC" ]] && LEGACY_ARG="-LegacyStaticMacAddress '$LEGACY_STATIC_MAC'"
ssh_host "pwsh -File ${STAGE_DIR_HOST}\\New-SmbProxyTestVM.ps1 \
            -VMName '$VM_NAME' \
            -SeedIso 'D:\\ISO\\${VM_NAME}-seed.iso' \
            -DomainStaticMacAddress '$DOMAIN_STATIC_MAC' \
            $LEGACY_ARG \
            -Start"

step "4. wait for cloud-init + SSH on $VM_IP (up to 180s)"
ssh_up=0
for _ in $(seq 1 90); do
    if ssh -o ConnectTimeout=3 -o BatchMode=yes \
           -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -J "${HV_USER}@${HV_HOST}" "${VM_USER}@${VM_IP}" true 2>/dev/null; then
        ssh_up=1
        break
    fi
    sleep 2
done
[[ $ssh_up -eq 1 ]] || { say "SSH never came up after cloud-init window"; exit 1; }
ssh_vm 'hostname; ip -4 addr show | grep -E "inet " | head -3; \
        test -f /var/log/smbproxy-base-ready.marker && cat /var/log/smbproxy-base-ready.marker'

step "5. push appliance scripts and appliance-core lib/ to the VM"
scp -J "${HV_USER}@${HV_HOST}" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$REPO_DIR/prepare-image.sh" "$REPO_DIR/smbproxy-sconfig.sh" \
    "${VM_USER}@${VM_IP}:/tmp/"

# Cross-repo: vendor the shared libs from the sibling appliance-core
# repo. prepare-image.sh §16b looks for them at /tmp/lib/. The
# appliance-core checkout lives at $REPO_DIR/../appliance-core per
# REPO-SPLIT.md.
APPCORE_REPO="${APPCORE_REPO:-$REPO_DIR/../appliance-core}"
if [[ ! -d "$APPCORE_REPO/lib" ]]; then
    say "appliance-core lib/ not found at $APPCORE_REPO/lib"
    say "set \$APPCORE_REPO if the sibling lives elsewhere"
    exit 1
fi
scp -J "${HV_USER}@${HV_HOST}" -r \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$APPCORE_REPO/lib" \
    "${VM_USER}@${VM_IP}:/tmp/"

step "6. run prepare-image.sh on $VM_NAME"
# Compute the appliance-core source-tree commit on the Mac and pass
# through; the appliance image has no git, so this is the only correct
# way to record provenance. See appliance-core/prepare-image.sh §12 and
# decisions/0002-appliance-core.md §"Versioning + identity".
APPCORE_BUILD_COMMIT="$(git -C "$APPCORE_REPO" rev-parse HEAD 2>/dev/null || echo unknown)"
say "  appliance-core source commit: $APPCORE_BUILD_COMMIT"
if ! ssh_vm "sudo APPCORE_BUILD_COMMIT='$APPCORE_BUILD_COMMIT' bash /tmp/prepare-image.sh"; then
    say "prepare-image.sh failed"
    ssh_vm 'sudo tail -30 /var/log/smbproxy-prepare.log 2>/dev/null || journalctl -n 30 --no-pager'
    exit 1
fi
ssh_vm 'sudo install -m 0755 /tmp/smbproxy-sconfig.sh /usr/local/sbin/smbproxy-sconfig'

step "7. shutdown for deploy-master snapshot"
# This is the host-agnostic master: prepare-image.sh has finished, but
# smbproxy-firstboot has NOT yet fired. The disk image at this point can
# be copied to any hypervisor — the firstboot service will detect the
# environment on its first run there and install the matching guest agent
# from the pre-staged offline cache.
ssh_vm 'sudo shutdown -h now' || true

wait_off() {
    local name="$1" tries="$2"
    for _ in $(seq 1 "$tries"); do
        state=$(ssh_host "(Get-VM -Name '$name').State.ToString()" 2>/dev/null | tr -d '\r')
        [[ "$state" == "Off" ]] && return 0
        sleep 2
    done
    return 1
}

if ! wait_off "$VM_NAME" 30; then
    say "VM did not power off cleanly after 60s"; exit 1
fi

ssh_host "Checkpoint-VM -Name '$VM_NAME' -SnapshotName 'deploy-master'"
say "checkpoint 'deploy-master' created (host-agnostic, pre-firstboot)"

if [[ $DEPLOY_ONLY -eq 1 ]]; then
    echo
    echo "--deploy-only requested: stopping after deploy-master."
    echo "Snapshots on '$VM_NAME':"
    echo "  deploy-master   host-agnostic, ship-this-one"
    echo
    echo "Next:"
    echo "  lab/export-deploy-master.sh   # produce dist artifacts"
    exit 0
fi

step "8. boot once to fire smbproxy-firstboot (Hyper-V tailoring)"
ssh_host "Start-VM -Name '$VM_NAME'"

say "wait for smbproxy-firstboot.done marker (up to 120s)"
done_marker=0
for _ in $(seq 1 60); do
    if ssh -o ConnectTimeout=3 -o BatchMode=yes \
           -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
           -J "${HV_USER}@${HV_HOST}" "${VM_USER}@${VM_IP}" \
           'test -f /var/lib/smbproxy-firstboot.done' 2>/dev/null; then
        done_marker=1
        break
    fi
    sleep 2
done
[[ $done_marker -eq 1 ]] || { say "smbproxy-firstboot.done never appeared"; exit 1; }

# Show what firstboot did so it's in the build log.
ssh_vm 'sudo cat /var/log/smbproxy-firstboot.log 2>/dev/null | tail -40' || true

step "9. shutdown + checkpoint as $GOLDEN_CHECKPOINT"
ssh_vm 'sudo shutdown -h now' || true
if ! wait_off "$VM_NAME" 30; then
    say "VM did not power off cleanly after 60s"; exit 1
fi

ssh_host "Checkpoint-VM -Name '$VM_NAME' -SnapshotName '$GOLDEN_CHECKPOINT'"
say "checkpoint $GOLDEN_CHECKPOINT created (Hyper-V-tailored, lab-ready)"

echo
echo "Done. Snapshots on '$VM_NAME':"
echo "  deploy-master   host-agnostic, ship-this-one"
echo "  $GOLDEN_CHECKPOINT     Hyper-V tailored, used by lab/run-scenario.sh"
echo
echo "Next:"
echo "  lab/run-scenario.sh smoke-prepared-image"
