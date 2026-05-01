# Development and Test Environment Setup

This guide is the from-scratch "start here" for someone who wants to
develop on or test the SMB1↔SMB3 proxy appliance. It covers the
Mac-side tooling, the Hyper-V host expectations, external artifacts,
and the sibling-repo layout.

The proxy lab **shares its router, WS2025 DC, and LegacyZone backend**
with the [`samba-addc-appliance`](../../samba-addc-appliance/) sibling.
If that sibling's lab is already up, almost everything you need is
already there — see [Reusing the existing lab](#reusing-the-existing-lab)
below.

## Overview

The lab is driven from a Mac and runs on a remote Hyper-V host. Four
git repositories live side by side on the Mac:

```text
Debian-SAMBA/
  lab-kit/                reusable lab orchestration (generic runner)
  lab-router/             reusable router VM builder
  samba-addc-appliance/   Samba AD DC appliance + the WS2025 lab DC
  smb-proxy-appliance/    this repo: proxy appliance + proxy scenarios
```

Five VMs run on the Hyper-V host:

| VM | Purpose | Address |
| --- | --- | --- |
| `router1` | Debian NAT + DHCP + DNS forwarder | 10.10.10.1 |
| `WS2025-DC1` | Windows Server 2025 first DC for `lab.test` | 10.10.10.10 |
| `samba-dc1` | Samba AD DC appliance under test (sibling repo) | 10.10.10.20 |
| `smbproxy-1` | Proxy appliance under test (this repo) | 10.10.10.30 |
| WS2008 SP2 backend | Persistent legacy file server | `172.29.137.1` (LegacyZone) |

The Mac mounts an SMB share from the Hyper-V host (typically
`/Volumes/ISO` on the Mac = `D:\ISO\` on the host). This share is where
installer ISOs, built artifacts, and staged helper scripts live. The
runner jumps through the host via SSH to reach the VMs.

## Reusing the existing lab

If you already followed the `samba-addc-appliance` SETUP guide, the
only proxy-specific items you still need are:

1. **`LegacyZone` private virtual switch** with the WS2008 SP2 server
   attached (172.29.137.0/24). This is persistent infrastructure — see
   [LegacyZone vSwitch](#legacyzone-vswitch) below.
2. **dnsmasq reservation for the proxy's domain NIC**. Add
   `00:15:5D:0A:0A:1E,smbproxy-1,10.10.10.30` to your lab-router config
   (see [dnsmasq reservation](#dnsmasq-reservation)) and re-render.
3. **WS2008 backend credentials**. See
   [Backend credentials](#backend-credentials).

Everything else — the Mac toolchain, the SSH setup to the Hyper-V
host, `lab-kit`, `lab-router`, `WS2025-DC1` — is identical to the
samba-addc-appliance setup.

## Mac Prerequisites

| Tool | Required | Install |
| --- | --- | --- |
| Homebrew | yes | <https://brew.sh> |
| `qemu-img` | yes | `brew install qemu` |
| `git` | yes | Xcode CLT: `xcode-select --install` |
| `ssh`, `scp` | yes | macOS built-in |
| `curl` | yes | macOS built-in |
| `hdiutil` | yes | macOS built-in |
| `bsdtar` | optional | macOS built-in; handy for inspecting generated seed ISOs |

Generate an SSH keypair if you do not have one. The lab flow assumes
ed25519 at `~/.ssh/id_ed25519.pub`:

```bash
[[ -f ~/.ssh/id_ed25519 ]] || ssh-keygen -t ed25519 -N '' -f ~/.ssh/id_ed25519
```

Drop one or more `.pub` files into `lab/keys/` so the appliance image
accepts SSH from your operator account — see
[`lab/keys/README.md`](../lab/keys/README.md).

## Hyper-V Host Prerequisites

Same expectations as `samba-addc-appliance/docs/SETUP.md`:

- Hyper-V role installed and working
- PowerShell 7 (`pwsh.exe`) on `PATH`
- OpenSSH Server enabled, running, and key-authenticated from the Mac
- A directory shared over SMB to the Mac at `D:\ISO\` (Mac sees it at
  `/Volumes/ISO`)
- The lab-router and WS2025-DC1 VMs already built per the
  samba-addc-appliance setup guide

### LegacyZone vSwitch

Create the LegacyZone switch **once** as a Hyper-V *Private* vSwitch
(no host adapter, no upstream — just a private bus the proxy and the
WS2008 server share):

```powershell
New-VMSwitch -Name 'LegacyZone' -SwitchType Private
```

Attach the WS2008 SP2 staging server to it and pin the Windows side
to `172.29.137.1/24` with **no gateway, no DNS**. The proxy's legacy
NIC is configured later from `smbproxy-init` to a static address on
the same subnet (e.g. `172.29.137.10/24`, again no gateway, no DNS).

This switch is persistent infrastructure. Do not delete or rename it
casually; every diagnostic and lab scenario in this repo assumes it
exists with a working WS2008 backend.

### dnsmasq reservation

Add this line to your lab-router dnsmasq config alongside the existing
samba-dc1 reservation, then re-render and restart the router:

```text
dhcp-host=00:15:5D:0A:0A:1E,smbproxy-1,10.10.10.30,12h
```

If you use the YAML config style in `lab-router/configs/`, append the
equivalent entry under `dhcp.reservations` and rebuild.

The reservation is **not auto-created** by anything in this repo —
once-per-lab operator step, and it is the link between the MAC pinned
in `New-SmbProxyTestVM.ps1` and the IP in `lab/proxy.env`.

### Backend credentials

The WS2008 SP2 backend is reachable on LegacyZone at `172.29.137.1`
with share `ProfitFab$`, NetBIOS domain `LEGACY`, user `pfuser`. The
credentials are documented in
[`docs/sketch-smb1-smb3-proxy.sh`](sketch-smb1-smb3-proxy.sh) (the
historical starter script). They are **not** repeated in any scenario
file — scenarios that mount the backend read the password from the
`SC_BACKEND_PASS` env var or a gitignored `lab/backend-creds.env`
file. See [LAB-TESTING.md](LAB-TESTING.md) for the exact pattern.

## External Artifacts

The Debian 13 generic cloud image used by the proxy is fetched
automatically the first time you run `lab/stage-proxy-base.sh`. The
cached qcow2 is shared with the Samba sibling — whichever stager runs
first primes it for both.

You do **not** need to download anything else for the proxy lab; all
the WS2025 ISOs and security baselines are consumed by the
samba-addc-appliance lab, not this one.

Default filenames (override via script flags if needed):

- `lab/hyperv/New-SmbProxyTestVM.ps1` expects
  `D:\ISO\debian-13-smbproxy-base.vhdx` and
  `D:\ISO\<VMName>-seed.iso` — both produced by
  `lab/stage-proxy-base.sh`. End-to-end builds usually go through
  `lab/build-fresh-base.sh` instead.

## Customizing Defaults for Your Host

The defaults match the original developer's environment. Touch points:

| Setting | Default | Change in |
| --- | --- | --- |
| Hyper-V host DNS name | `server` | `lab/proxy.env` (`LAB_HV_HOST`) |
| Host SSH user | `nmadmin` | `lab/proxy.env` (`LAB_HV_USER`) |
| Mac-side ISO share path | `/Volumes/ISO/lab-scripts` | `lab/proxy.env` (`LAB_STAGE_DIR`) |
| Host-side ISO share path | `D:\ISO\lab-scripts` | `lab/proxy.env` (`LAB_HOST_STAGE_DIR`) |
| VM admin user | `debadmin` | `lab/proxy.env` (`LAB_VM_USER`) and stager `-u` |
| Domain NIC switch | `Lab-NAT` | `-DomainSwitchName` on `New-SmbProxyTestVM.ps1` |
| Legacy NIC switch | `LegacyZone` | `-LegacySwitchName` on `New-SmbProxyTestVM.ps1` |
| Domain NIC pinned MAC | `00:15:5D:0A:0A:1E` | `lab/build-fresh-base.sh -m` and matching dnsmasq reservation |
| VM IP | `10.10.10.30` | `lab/proxy.env` (`LAB_VM_IP`) and matching dnsmasq reservation |

Do not edit these values in multiple places. The scripts are wired so
that `lab/proxy.env` plus the matching dnsmasq reservation are the only
places you need to touch for host-specific settings.

## Verify Your Setup

Run these from the `smb-proxy-appliance/` directory after cloning all
four repos. Every line should succeed.

```bash
# 1. The siblings exist at the expected paths.
ls -d ../lab-kit ../lab-router ../samba-addc-appliance >/dev/null && echo "siblings OK"

# 2. Mac tools.
for t in qemu-img hdiutil curl ssh scp git; do
    command -v "$t" >/dev/null || { echo "missing $t"; false; }
done && echo "mac tools OK"

# 3. SSH keypair.
[[ -f ~/.ssh/id_ed25519.pub ]] && echo "ssh key OK"

# 4. SSH to the Hyper-V host and confirm both switches exist.
ssh nmadmin@server 'pwsh -Command "Get-VMSwitch | Where-Object Name -in @(\"Lab-NAT\",\"LegacyZone\") | Select-Object Name,SwitchType"'

# 5. ISO share is mounted and writable.
touch /Volumes/ISO/.write-test && rm /Volumes/ISO/.write-test && echo "ISO share OK"

# 6. WS2008 backend reachable from the Hyper-V host.
ssh nmadmin@server 'Test-NetConnection -ComputerName 172.29.137.1 -Port 445 -InformationLevel Quiet'

# 7. Syntax check the proxy scripts.
bash -n prepare-image.sh smbproxy-sconfig.sh \
    lab/run-scenario.sh lab/stage-proxy-base.sh lab/build-fresh-base.sh \
    lab/export-deploy-master.sh lab/scenarios/*.sh
echo "syntax checks OK"
```

## Build the proxy appliance image

After the prerequisites above are satisfied, building a `golden-image`
checkpoint of `smbproxy-1` is one command:

```bash
lab/build-fresh-base.sh -f       # -f removes any existing smbproxy-1 first
```

That stages the cloud image + per-VM seed, creates the dual-NIC VM,
waits for cloud-init, runs `prepare-image.sh`, snapshots
`deploy-master`, fires `smbproxy-firstboot` once, and snapshots
`golden-image`. ~6 minutes start to finish, mostly unattended.

From then on, the daily loop is:

```bash
lab/run-scenario.sh smoke-prepared-image
```

See [LAB-TESTING.md](LAB-TESTING.md) for scenario authoring and the
full test plan.

## Release export

To produce host-agnostic distributable artifacts (vhdx, qcow2, vmdk,
ova) from the `deploy-master` checkpoint:

```bash
lab/export-deploy-master.sh
```

Output lands in `dist/smb-proxy-appliance-vYYYY.MM.DD/` with a
SHA256SUMS file alongside.
