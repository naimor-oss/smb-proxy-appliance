# SMB1↔SMB3 Protocol-Version Proxy Appliance

This repository builds a small **SMB1↔SMB3 proxy appliance** on Debian 13.
The appliance fronts a hardened Windows Server 2008 SP2 file server (over
a dedicated point-to-point link) and re-publishes its share to a modern
WS2025 AD forest as an SMB3-only share, with byte-range locking and oplock
behavior enforced at the proxy so multi-user Clarion `.TPS` databases work
correctly under modern Windows clients.

## Where do I start?

| If you want to … | Read |
| --- | --- |
| Understand the **dual-NIC model and lock semantics** | [`AGENTS.md`](AGENTS.md) |
| **Set up** the dev/test environment | [`docs/SETUP.md`](docs/SETUP.md) |
| **Author or run** lab scenarios | [`docs/LAB-TESTING.md`](docs/LAB-TESTING.md) |
| Understand the **original sketch** that drove the design | [`docs/sketch-smb1-smb3-proxy.sh`](docs/sketch-smb1-smb3-proxy.sh) |
| Understand the **sibling-repo split** | [`../dev-commons/REPO-SPLIT.md`](../dev-commons/REPO-SPLIT.md) |
| Look up **shared coding/docs/test conventions** | [`../dev-commons/STYLE.md`](../dev-commons/STYLE.md) |

The proxy appliance is exercised against the same Windows Server 2025
forest that the [`samba-addc-appliance`](../samba-addc-appliance/) sibling
joins. The lab is built from five sibling repositories living next to each
other on disk:

- [`dev-commons`](../dev-commons/) — cross-cutting docs, templates, tooling
- [`lab-kit`](../lab-kit/) — reusable appliance lab orchestration
- [`lab-router`](../lab-router/) — simple reusable lab router VM
- [`samba-addc-appliance`](../samba-addc-appliance/) — Samba AD DC member
  test fixture (the proxy joins as a domain member of the WS2025 forest;
  the Samba sibling exists for separate testing)
- `smb-proxy-appliance` — this proxy and its scenarios

## Repository Map

| Path | Purpose |
| --- | --- |
| `prepare-image.sh` | One-time Debian image preparation. Installs Samba member-server, Winbind, Kerberos, cifs-utils, chrony, nftables, and appliance helper scripts. Vendor-, realm-, and credential-neutral. |
| `smbproxy-sconfig.sh` | Main appliance configuration tool. Provides the whiptail TUI and a small headless CLI. Handles NIC role assignment, AD join, backend SMB1 mount, and frontend SMB3 share. |
| `lab/proxy.env` | Lab environment file consumed by the generic runner. |
| `lab/run-scenario.sh` | Proxy-specific wrapper around `../lab-kit/bin/run-scenario.sh`. |
| `lab/stage-proxy-base.sh` | Mac-side stager: produces the shared base VHDX and per-VM cloud-init seed ISO. |
| `lab/build-fresh-base.sh` | End-to-end image build: stage → create dual-NIC VM → run prepare-image.sh → snapshot `deploy-master` → fire firstboot → snapshot `golden-image`. |
| `lab/export-deploy-master.sh` | Release-time export: Hyper-V snapshot → vhdx + qcow2 + vmdk + ova + SHA256SUMS. |
| `lab/hyperv/New-SmbProxyTestVM.ps1` | Creates the dual-NIC proxy VM (Lab-NAT + LegacyZone). |
| `lab/scenarios/smoke-prepared-image.sh` | Verifies a freshly reverted `golden-image` is a clean, unprovisioned proxy base. |
| `lab/scenarios/bootstrap-network.sh` | Headless equivalent of `smbproxy-init`'s NIC-roles + legacy-IP step. Used as a `pre_hook` by every downstream scenario. |
| `lab/scenarios/join-domain.sh` | Joins `lab.test` via `smbproxy-sconfig --join-domain`. AD cleanup respects `--no-cleanup` / `--dry-cleanup`. |
| `lab/scenarios/backend-mount.sh` | Configures one share's backend half via `--configure-share` (no `--group`). Reads `SC_BACKEND_PASS` from `lab/backend-creds.env` (gitignored). |
| `lab/scenarios/frontend-share.sh` | Composes bootstrap + join + full `--configure-share` (with `--group`) + `--apply-firewall`. Verifies SMB3 + Kerberos access. |
| `lab/scenarios/multi-share.sh` | Configures TWO shares from the same backend with different creds + AD groups; verifies independence; exercises `--remove-share` while another share is configured. |
| `lab/scenarios/end-to-end.sh` | Single-shot release-gate test. Optional WS2008 read/write roundtrip via `SC_WRITE_ROUNDTRIP=1`. |
| `lab/backend-creds.env.example` | Template for the gitignored `lab/backend-creds.env`. Single-share scenarios need `SC_BACKEND_PASS`; `multi-share` also needs `SC_BACKEND_PASS_B`. |
| `lab/templates/cloud-init/` | NoCloud seed templates (meta-data, network-config matching by domain MAC, user-data with operator pubkeys). |
| `lab/keys/` | Operator SSH pubkeys baked into the image at build time. See `lab/keys/README.md`. |
| `docs/SETUP.md` | Mac + Hyper-V environment setup, LegacyZone vSwitch, dnsmasq reservation. |
| `docs/LAB-TESTING.md` | Scenario authoring and the prioritized backlog of additional scenarios. |
| `docs/sketch-smb1-smb3-proxy.sh` | Original single-script sketch from the maintainer; preserved for historical reference. The two-script (image + sconfig) layout above supersedes it. |
| `AGENTS.md` | Vendor-neutral coding-agent guide for this repo. |
| `CLAUDE.md` | Claude Code compatibility pointer back to `AGENTS.md`. |

## Intended Workflow

1. Build (or reuse) the persistent lab infrastructure: router, WS2025 DC,
   and the WS2008 SP2 staging server on the LegacyZone subnet.
2. Create a Debian VM with **two NICs**: the first attached to the
   domain LAN with DHCP for install-time internet access; the second
   attached to the LegacyZone switch (no gateway, no DHCP).
3. Boot the Debian installer, install minimally, then run
   `prepare-image.sh` once and shut down. The shutdown-state disk is the
   host-agnostic master image.
4. Boot the deployed appliance. The console TTY1 wizard
   (`smbproxy-init`) walks the operator through:
   - identifying which NIC is the domain NIC and which is the legacy NIC
     (operator picks by MAC; the wizard shows MAC + link-up state +
     DHCP lease per interface);
   - applying static IP on the legacy NIC;
   - confirming or pinning a static IP on the domain NIC;
   - hostname, password, SSH key paste, timezone.
5. Log in over SSH and run `sudo smbproxy-sconfig` to:
   - join the WS2025 forest;
   - configure backend SMB1 mount credentials (WS2008 IP, share, user,
     password, NetBIOS domain);
   - configure the frontend SMB3 share (share name, mount path, the AD
     group allowed to access it, the local backend force-user);
   - enable `smbd`, `winbind`, and the systemd-mounted cifs backend.

## Lab Topology

The lab consumes the existing Hyper-V environment plus a private virtual
switch named `LegacyZone` carrying the dedicated SMB1 backend subnet.

| Role | VM | Subnet / IP | Notes |
| --- | --- | --- | --- |
| Gateway / DHCP / DNS forwarder | `router1` | `10.10.10.0/24` | From `lab-router`. |
| First Windows DC | `WS2025-DC1` | `10.10.10.10` | Owns the test forest. |
| WS2008 SP2 backend | (existing) | `172.29.137.1` (LegacyZone) | Static, gateway-less. Test data only. |
| SMB1↔SMB3 proxy | `smbproxy-1` | domain NIC: DHCP→static, legacy NIC: `172.29.137.x/24` | Debian 13 appliance candidate. |

The actual production WS2008 SP2 server reachable on LegacyZone is the
authoritative source. The lab does **not** stand up a synthetic WS2008
backend; backend behavior is validated against the existing staging
server only.

## Status

Initial commit covers:

- Two-script appliance layout (`prepare-image.sh` +
  `smbproxy-sconfig.sh`) plus first-boot wizard.
- Lab harness mirroring the samba-addc-appliance pattern: stager,
  end-to-end build, dual-NIC Hyper-V VM creator (with the LegacyZone
  switch as a hard prereq), generic-runner wrapper, smoke scenario,
  and release-export pipeline. See [`lab/`](lab/).
- Setup and lab-testing docs in [`docs/`](docs/).

The lab reuses the existing samba-addc-appliance lab environment
(router1, WS2025-DC1, LegacyZone vSwitch with the WS2008 SP2 backend
on it). The proxy joins `lab.test` as a member server. Only one
once-per-lab operator step is new: a dnsmasq reservation for
`smbproxy-1` (MAC `00:15:5D:0A:0A:1E` → `10.10.10.30`). See
[`docs/SETUP.md`](docs/SETUP.md).
