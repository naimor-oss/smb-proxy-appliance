#Requires -RunAsAdministrator
#Requires -Modules Hyper-V
<#
.SYNOPSIS
    Create a Debian 13 cloud-init VM for the SMB1<->SMB3 proxy appliance.

.DESCRIPTION
    Builds a Gen2 VM with TWO NICs:
      - the *domain* NIC, attached to Lab-NAT, MAC pinned so router1's
        dnsmasq hands it the reserved 10.10.10.30 lease;
      - the *legacy* NIC, attached to the LegacyZone private switch
        carrying the 172.29.137.0/24 SMB1 backend subnet. No IP is
        configured by cloud-init for this NIC; smbproxy-init's role
        wizard sets the static IP on the appliance side after
        first boot.

    The base VHDX is shared across all proxy VMs (read-mostly); each VM
    gets its own differencing disk rooted on the base. That keeps a fresh
    test VM tens of MB on disk until prepare-image.sh writes a lot.

    MAC reservations on the lab-router (matching dnsmasq):
      smbproxy-1   00:15:5D:0A:0A:1E   10.10.10.30
      smbproxy-2   00:15:5D:0A:0A:1F   10.10.10.31
      smbproxy-3   00:15:5D:0A:0A:20   10.10.10.32

    The LegacyZone vSwitch is persistent infrastructure — the WS2008 SP2
    backend lives on it. This script refuses to run if LegacyZone is
    missing rather than create a wrong-topology switch.

.PARAMETER VMName
    Hyper-V VM name. Required.

.PARAMETER BaseVhdxPath
    Path on the Hyper-V host to the staged base VHDX produced by
    stage-proxy-base.sh. Default 'D:\ISO\debian-13-smbproxy-base.vhdx'.

.PARAMETER SeedIso
    Path on the Hyper-V host to the per-VM cloud-init seed ISO. Defaults
    to 'D:\ISO\<VMName>-seed.iso' (matches stage-proxy-base.sh's output
    naming convention).

.PARAMETER DomainSwitchName
    Lab LAN switch (default 'Lab-NAT'). The proxy joins the WS2025 forest
    over this NIC.

.PARAMETER LegacySwitchName
    Backend point-to-point switch (default 'LegacyZone'). Must already
    exist with the WS2008 SP2 server attached.

.PARAMETER DomainStaticMacAddress
    Pinned MAC for the domain NIC, no separators. Default '00155D0A0A1E'
    = smbproxy-1.

.PARAMETER LegacyStaticMacAddress
    Optional pinned MAC for the legacy NIC. Default empty (Hyper-V
    auto-generates). Pin this only if you want stable identification of
    the legacy NIC across VM rebuilds — the appliance identifies it by
    "the NIC that isn't the domain NIC", not by MAC, so a generated MAC
    is fine for normal use.

.EXAMPLE
    .\New-SmbProxyTestVM.ps1 -VMName smbproxy-1 -Start

.EXAMPLE
    .\New-SmbProxyTestVM.ps1 -VMName smbproxy-2 `
        -DomainStaticMacAddress 00155D0A0A1F -Start
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$VMName,
    [string]$BaseVhdxPath           = 'D:\ISO\debian-13-smbproxy-base.vhdx',
    [string]$SeedIso                = '',     # default derived from $VMName below
    [string]$LabPath                = 'D:\Lab',
    [string]$DomainSwitchName       = 'Lab-NAT',
    [string]$LegacySwitchName       = 'LegacyZone',
    [int]   $MemoryGB               = 2,
    [int]   $VCpu                   = 2,
    [int]   $DiskGB                 = 20,
    [string]$DomainStaticMacAddress = '00155D0A0A1E',
    [string]$LegacyStaticMacAddress = '',
    [switch]$Start
)

$ErrorActionPreference = 'Stop'

function Write-Step { param($m) Write-Host "`n==> $m" -ForegroundColor Cyan }
function Write-OK   { param($m) Write-Host "    + $m" -ForegroundColor Green }

if (-not $SeedIso) { $SeedIso = "D:\ISO\${VMName}-seed.iso" }

if (Get-VM -Name $VMName -ErrorAction SilentlyContinue) {
    throw "VM '$VMName' already exists. Remove it first: Remove-VM $VMName -Force"
}
if (-not (Test-Path $BaseVhdxPath)) {
    throw "Base VHDX not found: $BaseVhdxPath. Run lab/stage-proxy-base.sh on the Mac first."
}
if (-not (Test-Path $SeedIso)) {
    throw "Seed ISO not found: $SeedIso. Run lab/stage-proxy-base.sh on the Mac first."
}
if (-not (Get-VMSwitch -Name $DomainSwitchName -ErrorAction SilentlyContinue)) {
    throw "Switch '$DomainSwitchName' not found. Build the lab router first (New-LabRouter.ps1)."
}
if (-not (Get-VMSwitch -Name $LegacySwitchName -ErrorAction SilentlyContinue)) {
    throw "Switch '$LegacySwitchName' not found. The LegacyZone private switch (with the WS2008 backend on it) is persistent infrastructure — create it once by hand and leave it."
}

Write-Step "Creating proxy test VM: $VMName"
Write-OK   "  domain NIC -> $DomainSwitchName  (MAC $DomainStaticMacAddress)"
if ($LegacyStaticMacAddress) {
    Write-OK "  legacy NIC -> $LegacySwitchName (MAC $LegacyStaticMacAddress)"
} else {
    Write-OK "  legacy NIC -> $LegacySwitchName (auto MAC)"
}

$VmFolder = Join-Path $LabPath $VMName
New-Item -Path $VmFolder -ItemType Directory -Force | Out-Null

# Differencing VHDX rooted on the shared base. Cheap to create, cheap to
# throw away — perfect for "build a fresh test VM" cycles.
$DiffVhdxPath = Join-Path $VmFolder "$VMName.vhdx"
if (Test-Path $DiffVhdxPath) { Remove-Item -Force $DiffVhdxPath }
New-VHD -Path $DiffVhdxPath -ParentPath $BaseVhdxPath -Differencing | Out-Null

# Resize the differencing virtual size so the guest sees room to grow
# beyond the cloud image's stock 2 GB. The on-disk file stays small until
# the workload writes to it.
Resize-VHD -Path $DiffVhdxPath -SizeBytes ($DiskGB * 1GB)

$null = New-VM -Name $VMName `
    -MemoryStartupBytes ($MemoryGB * 1GB) `
    -Generation 2 `
    -SwitchName $DomainSwitchName `
    -VHDPath $DiffVhdxPath `
    -Path $LabPath

Set-VMProcessor -VMName $VMName -Count $VCpu
Set-VMMemory -VMName $VMName -DynamicMemoryEnabled $false

# Pin the domain NIC's MAC so dnsmasq hands out the reserved IP.
# Get-VMNetworkAdapter at this point returns just the one adapter that
# New-VM created on -SwitchName.
$domainNic = Get-VMNetworkAdapter -VMName $VMName | Select-Object -First 1
$domainNic | Set-VMNetworkAdapter -StaticMacAddress $DomainStaticMacAddress
$domainNic | Rename-VMNetworkAdapter -NewName 'Domain'
Write-OK "domain NIC pinned: $DomainStaticMacAddress"

# Add the second NIC for the LegacyZone backend subnet.
$legacyNicArgs = @{
    VMName     = $VMName
    SwitchName = $LegacySwitchName
    Name       = 'Legacy'
}
Add-VMNetworkAdapter @legacyNicArgs
if ($LegacyStaticMacAddress) {
    Get-VMNetworkAdapter -VMName $VMName -Name 'Legacy' |
        Set-VMNetworkAdapter -StaticMacAddress $LegacyStaticMacAddress
}
Write-OK "legacy NIC attached to $LegacySwitchName"

# Mount the cloud-init seed as a DVD. cloud-init's NoCloud datasource
# discovers it by the CIDATA volume label set by stage-proxy-base.sh.
Add-VMDvdDrive -VMName $VMName -Path $SeedIso

# Cloud images are signed for normal Debian boot, NOT Microsoft secure
# boot. Disable SecureBoot so the bootloader on the base VHDX can run.
Set-VMFirmware -VMName $VMName -EnableSecureBoot Off
Set-VMFirmware -VMName $VMName -FirstBootDevice (Get-VMHardDiskDrive -VMName $VMName)

Enable-VMIntegrationService -VMName $VMName -Name 'Guest Service Interface'
Enable-VMIntegrationService -VMName $VMName -Name 'Heartbeat'
Enable-VMIntegrationService -VMName $VMName -Name 'Time Synchronization'

Write-OK "VM created"
Write-OK "  vCPU: $VCpu | RAM: $MemoryGB GB | Disk virt: $DiskGB GB"
Write-OK "  Base: $BaseVhdxPath"
Write-OK "  Diff: $DiffVhdxPath"
Write-OK "  Seed: $SeedIso"

if ($Start) {
    Write-Step "Starting VM"
    Start-VM -Name $VMName
    Write-OK "Started — cloud-init typically takes ~20s; the appliance is reachable"
    Write-OK "via SSH at the dnsmasq-reserved IP for $DomainStaticMacAddress once cloud-init"
    Write-OK "writes /var/log/smbproxy-base-ready.marker."
}
