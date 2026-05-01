#!/usr/bin/env bash
#===============================================================================
# lab/export-deploy-master.sh — release-time export of the SMB1<->SMB3 proxy
# appliance, host-agnostic.
#
# Pipeline:
#   1. Hyper-V: Export-VMSnapshot of the host-agnostic 'deploy-master'
#      checkpoint to a versioned directory under D:\ISO\Export\.
#   2. Mac:     copy the merged .vhdx out, convert with qemu-img to .qcow2
#               and to streamOptimized .vmdk.
#   3. Mac:     write a minimal .vmx, run ovftool to bundle the .vmdk as
#               an .ova for VMware shops.
#   4. Mac:     sha256sum the four artifacts; emit SHA256SUMS.
#
# Final layout:
#
#   dist/smb-proxy-appliance-vYYYY.MM.DD/
#     smb-proxy-appliance-vYYYY.MM.DD.vhdx     # Hyper-V users (lossless)
#     smb-proxy-appliance-vYYYY.MM.DD.qcow2    # KVM/Proxmox/Nutanix/OpenStack
#     smb-proxy-appliance-vYYYY.MM.DD.vmdk     # streamOptimized; same content
#                                              #  as the .vmdk inside the .ova
#     smb-proxy-appliance-vYYYY.MM.DD.ova      # VMware/VirtualBox
#     SHA256SUMS
#
# The .vmx fed to ovftool is intentionally minimal — its only job is to give
# ovftool a virtual machine definition to hang the disk under so the OVF
# manifest is well-formed. The OVA defines a single NIC (vmxnet3, NAT)
# because OVF can't express "private switch on host X" portably; the
# operator wires the second NIC into their LegacyZone equivalent after
# import. The proxy refuses to mount the backend until the wizard has
# both NIC roles assigned, so a one-NIC import is a clear error state,
# not a silent misconfiguration.
#===============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

VM_NAME="${VM_NAME:-smbproxy-1}"
SNAPSHOT="${SNAPSHOT:-deploy-master}"
HV_HOST="${HV_HOST:-server}"
HV_USER="${HV_USER:-nmadmin}"
ISO_DIR_MAC="${ISO_DIR_MAC:-/Volumes/ISO}"
ISO_DIR_HOST="${ISO_DIR_HOST:-D:\\ISO}"
DIST_DIR="${DIST_DIR:-$REPO_DIR/dist}"
OVFTOOL="${OVFTOOL:-/Volumes/Data/Developer/Debian-SAMBA/ovftool/ovftool}"
VERSION="${VERSION:-$(date +%Y.%m.%d)}"

# Recompute paths after VERSION is fixed so --version flag works.
recompute_paths() {
    ARTIFACT_BASE="smb-proxy-appliance-v${VERSION}"
    HOST_EXPORT_DIR="${ISO_DIR_HOST}\\Export\\${ARTIFACT_BASE}"
    MAC_EXPORT_DIR="${ISO_DIR_MAC}/Export/${ARTIFACT_BASE}"
    DIST_VER_DIR="${DIST_DIR}/${ARTIFACT_BASE}"
}
recompute_paths

usage() {
    cat <<USAGE
Usage: lab/export-deploy-master.sh [flags]

Exports the host-agnostic '$SNAPSHOT' checkpoint of $VM_NAME from the
Hyper-V host, converts to vhdx + qcow2 + vmdk, packages the vmdk into
an OVA via ovftool. Final artifacts in dist/$ARTIFACT_BASE/.

Flags:
  -n, --vm-name NAME    source VM (default: $VM_NAME)
  -s, --snapshot NAME   snapshot to export (default: $SNAPSHOT)
  -V, --version V       version string for artifact names
                        (default: today's date Y.M.D, e.g. ${VERSION})
      --keep-export     don't remove the host-side export tree on exit
  -h, --help            show this

Environment overrides: HV_HOST, HV_USER, ISO_DIR_MAC, ISO_DIR_HOST,
DIST_DIR, OVFTOOL.
USAGE
}

KEEP_HOST_EXPORT=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--vm-name)    VM_NAME="$2"; shift 2 ;;
        -s|--snapshot)   SNAPSHOT="$2"; shift 2 ;;
        -V|--version)    VERSION="$2"; recompute_paths; shift 2 ;;
        --keep-export)   KEEP_HOST_EXPORT=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "Unknown arg: $1" >&2; usage >&2; exit 2 ;;
    esac
done

say()  { echo "--- [$(date -u +%H:%M:%S)] $*"; }
step() { echo
         echo "=============================================================="
         echo "=== $*"
         echo "=============================================================="; }

ssh_host() { ssh "${HV_USER}@${HV_HOST}" "$@"; }

[[ -d "$ISO_DIR_MAC" ]] || { echo "ISO share not mounted: $ISO_DIR_MAC" >&2; exit 1; }
[[ -x "$OVFTOOL"     ]] || { echo "ovftool not found at $OVFTOOL" >&2; exit 1; }
command -v qemu-img >/dev/null || { echo "qemu-img missing (brew install qemu)" >&2; exit 1; }

mkdir -p "$DIST_VER_DIR"

step "1. Hyper-V: Export-VMSnapshot $VM_NAME / $SNAPSHOT -> $HOST_EXPORT_DIR"
# Wipe any prior export at the same path so re-runs don't fail with
# "directory not empty". Export-VMSnapshot creates a fresh tree below.
#
# Our VM runs from a differencing VHDX rooted on the shared cloud-image
# base, so Export-VMSnapshot writes BOTH the parent base and the diff
# into the export tree. The diff still references its parent by path,
# which will not resolve once the file is pulled to the Mac. We use
# Convert-VHD to follow the chain and produce a single self-contained
# 'merged.vhdx' in the same directory; that's what we pull and convert.
ssh_host "Remove-Item -LiteralPath '$HOST_EXPORT_DIR' -Recurse -Force -ErrorAction SilentlyContinue
          New-Item -Path '$HOST_EXPORT_DIR' -ItemType Directory -Force | Out-Null
          Export-VMSnapshot -VMName '$VM_NAME' -Name '$SNAPSHOT' -Path '$HOST_EXPORT_DIR'

          \$vhdDir  = '${HOST_EXPORT_DIR}\\${VM_NAME}\\Virtual Hard Disks'
          \$diffs   = Get-ChildItem -Path \$vhdDir -Filter '*.vhdx' |
                       Where-Object { (Get-VHD \$_.FullName).VhdType -eq 'Differencing' }
          if (\$diffs.Count -ne 1) {
              throw \"Expected exactly one differencing VHDX in \$vhdDir, found \$(\$diffs.Count)\"
          }
          \$merged = Join-Path \$vhdDir 'merged.vhdx'
          Convert-VHD -Path \$diffs[0].FullName -DestinationPath \$merged -VHDType Dynamic
          # Drop the original diff + base now that the merge is self-contained
          # to keep the export size small over the SMB share.
          Get-ChildItem -Path \$vhdDir -Filter '*.vhdx' |
              Where-Object { \$_.FullName -ne \$merged } |
              Remove-Item -Force"

EXPORTED_VHDX_MAC="${MAC_EXPORT_DIR}/${VM_NAME}/Virtual Hard Disks/merged.vhdx"
say "merged vhdx at $EXPORTED_VHDX_MAC"
[[ -f "$EXPORTED_VHDX_MAC" ]] || { say "merged.vhdx not visible via SMB"; exit 1; }

VHDX_OUT="$DIST_VER_DIR/${ARTIFACT_BASE}.vhdx"
QCOW2_OUT="$DIST_VER_DIR/${ARTIFACT_BASE}.qcow2"
VMDK_OUT="$DIST_VER_DIR/${ARTIFACT_BASE}.vmdk"
OVA_OUT="$DIST_VER_DIR/${ARTIFACT_BASE}.ova"
VMX_TMP="$DIST_VER_DIR/${ARTIFACT_BASE}.vmx"

step "2. copy merged.vhdx out of the host export into dist/"
cp "$EXPORTED_VHDX_MAC" "$VHDX_OUT"
say "wrote $VHDX_OUT ($(du -sh "$VHDX_OUT" | cut -f1))"

step "3. qemu-img convert vhdx -> qcow2"
qemu-img convert -p -O qcow2 -o compat=1.1 "$VHDX_OUT" "$QCOW2_OUT"
say "wrote $QCOW2_OUT ($(du -sh "$QCOW2_OUT" | cut -f1))"

step "4. qemu-img convert vhdx -> vmdk (streamOptimized for OVA)"
qemu-img convert -p -O vmdk -o subformat=streamOptimized "$VHDX_OUT" "$VMDK_OUT"
say "wrote $VMDK_OUT ($(du -sh "$VMDK_OUT" | cut -f1))"

step "5. write a minimal .vmx for ovftool"
# guestOS=debian12-64 is the closest GOS identifier widely recognized by
# VMware (Debian 13 may not be in older host databases). firmware=efi
# matches the cloud-image bootloader; Secure Boot off because the cloud
# image is signed with the Debian key, not Microsoft's UEFI CA. Single
# NIC; the operator adds the second (legacy) NIC after import — see the
# header comment for why a portable OVF can't carry the second switch.
cat > "$VMX_TMP" <<VMXEOF
.encoding = "UTF-8"
config.version = "8"
virtualHW.version = "19"
displayName = "${ARTIFACT_BASE}"
annotation = "SMB1<->SMB3 Proxy Appliance | host-agnostic deploy master | exported $(date -u +%Y-%m-%dT%H:%M:%SZ)"
guestOS = "debian12-64"
firmware = "efi"
uefi.secureBoot.enabled = "FALSE"
memSize = "2048"
numvcpus = "2"
scsi0.present = "TRUE"
scsi0.virtualDev = "pvscsi"
scsi0:0.present = "TRUE"
scsi0:0.deviceType = "disk"
scsi0:0.fileName = "$(basename "$VMDK_OUT")"
ethernet0.present = "TRUE"
ethernet0.virtualDev = "vmxnet3"
ethernet0.connectionType = "nat"
ethernet0.startConnected = "TRUE"
ethernet0.addressType = "generated"
toolScripts.afterPowerOn = "TRUE"
VMXEOF

step "6. ovftool .vmx -> .ova"
"$OVFTOOL" --acceptAllEulas --shaAlgorithm=SHA256 \
    "$VMX_TMP" "$OVA_OUT"
say "wrote $OVA_OUT ($(du -sh "$OVA_OUT" | cut -f1))"

step "7. SHA256SUMS"
(cd "$DIST_VER_DIR" && shasum -a 256 \
    "${ARTIFACT_BASE}.vhdx" \
    "${ARTIFACT_BASE}.qcow2" \
    "${ARTIFACT_BASE}.vmdk" \
    "${ARTIFACT_BASE}.ova" \
    > SHA256SUMS && cat SHA256SUMS)

step "8. cleanup"
rm -f "$VMX_TMP"
if [[ $KEEP_HOST_EXPORT -eq 0 ]]; then
    say "removing host-side export at $HOST_EXPORT_DIR"
    ssh_host "Remove-Item -LiteralPath '$HOST_EXPORT_DIR' -Recurse -Force -ErrorAction SilentlyContinue"
fi

echo
echo "Done. Release artifacts in $DIST_VER_DIR/:"
ls -lh "$DIST_VER_DIR"
