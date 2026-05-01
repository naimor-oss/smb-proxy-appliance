# Agent Guide

This file is the vendor-neutral working brief for coding agents in this
repository. It should be safe for Claude Code, Codex, local agents, or other
tools to read. Vendor-specific notes are explicitly marked and should not be
treated as general project requirements.

**General conventions, project narrative, and shared decisions live in
the sibling repo [`../dev-commons/`](../dev-commons/).** Read at least
[`../dev-commons/CONTEXT.md`](../dev-commons/CONTEXT.md) and
[`../dev-commons/STYLE.md`](../dev-commons/STYLE.md) before substantive
work here. This file covers what's specific to `smb-proxy-appliance`.

## Project Purpose

Build and test an **SMB1↔SMB3 protocol-version proxy appliance** on Debian
13. The appliance fronts a hardened Windows Server 2008 SP2 file server
(reachable only over a dedicated point-to-point link) and re-publishes its
share to a modern Windows Server 2025 forest as an AD-joined SMB3 share.

Primary use case: serving multi-user Clarion `.TPS` (ISAM) database files
to AD-joined Windows 11 clients while the byte-range locking and oplock
semantics required by `.TPS` are enforced **at the proxy** rather than
across the WAN to the legacy backend.

The appliance has two core scripts:

- `prepare-image.sh`: one-time Debian image preparation. Vendor-neutral,
  realm-neutral, credential-free. Produces a host-agnostic master image.
- `smbproxy-sconfig.sh`: whiptail TUI plus headless CLI for NIC role
  assignment, AD domain join, backend SMB1 mount management, frontend
  SMB3 share publication, hardening, diagnostics, and service maintenance.

This repo is a sibling of:

- [`samba-addc-appliance`](../samba-addc-appliance/) — the Samba AD DC
  appliance that this proxy joins as a member server.
- [`lab-kit`](../lab-kit/) — reusable appliance lab orchestration.
- [`lab-router`](../lab-router/) — simple reusable lab router appliance.

## Dual-NIC Model

The proxy is the only writer the WS2008 backend ever sees, so all locking
is enforced locally by Samba and the backend mount uses `nobrl` to avoid
pushing locks across SMB1.

| NIC role | Network | Initial state | Final state |
| --- | --- | --- | --- |
| **Domain NIC** | AD domain LAN | DHCP (for install + updates) | Static; gateway + DNS = WS2025 DC |
| **Legacy NIC** | LegacyZone (e.g. 172.29.137.0/24) | unconfigured | Static, **no gateway, no DNS** |

NIC role identification happens once at first-boot via the `smbproxy-init`
console wizard. The operator picks each NIC by MAC address (the wizard
shows MAC, link-up state, and any DHCP lease present, so the choice is
unambiguous). The mapping is persisted as `/etc/smbproxy/nic-roles.env`
and consumed by `smbproxy-sconfig` thereafter.

## Locking Semantics for `.TPS` Files

The frontend share enforces strict locking; the backend mount delegates
nothing. This is correct for `.TPS` because the proxy is the single
arbiter of all writes the WS2008 server sees.

Frontend (`/etc/samba/smb.conf` per share):

```
oplocks         = no
level2 oplocks  = no
strict locking  = yes
kernel oplocks  = no
posix locking   = yes
```

Backend (cifs mount options for the WS2008 share):

```
vers=1.0,nobrl,cache=none,serverino
```

`nobrl` deliberately silences kernel-level byte-range lock propagation so
the backend never sees lock requests; `cache=none` removes the read cache
that could mask conflicts; `serverino` keeps inode numbers stable across
remounts.

## Persistent Infrastructure

Do not tear these down casually:

- The Hyper-V switch carrying the LegacyZone subnet (172.29.137.0/24).
- The WS2008 SP2 staging server VM. It contains test data only, but its
  existence is assumed by every diagnostic and lab scenario in this repo.
- The WS2025 forest used by the AD DC sibling appliance.
- The prepared `smbproxy-1` checkpoint `golden-image` (once it exists).

## Common Commands

Run a command on the proxy through the host:

```bash
ssh -J nmadmin@server debadmin@<smbproxy-domain-nic-ip> 'sudo systemctl is-active smbd'
```

Show NIC role mapping:

```bash
ssh -J nmadmin@server debadmin@<proxy> 'cat /etc/smbproxy/nic-roles.env'
```

Verify backend mount + share locks:

```bash
ssh -J nmadmin@server debadmin@<proxy> 'sudo mount | grep cifs; sudo smbstatus -L'
```

## Development Rules

- Prefer small, reviewable changes.
- Never bake realm, DC IP, WS2008 IP, share name, or credentials into
  `prepare-image.sh`. They belong in `smbproxy-sconfig`.
- Never commit `*creds*` files or anything containing the WS2008 backend
  password. The `.gitignore` covers the obvious paths; if you add a new
  one, extend the `.gitignore` rather than rely on memory.
- Do not modify the WS2008 SP2 staging server from this repo. Backend
  hardening changes live in the operator's runbook, not in agent
  automation.
- Use the headless `smbproxy-sconfig` CLI for automation instead of
  driving the whiptail UI.
- Add tests or scenario assertions when changing behavior.

## Important Interop Notes

- The Linux `cifs.ko` kernel module honors `vers=1.0` independently of
  Samba's `client min protocol = SMB3`. The two settings do not conflict;
  the frontend (Samba) speaks SMB3 only, while the backend (kernel cifs
  mount) speaks SMB1 only.
- Samba's `disable netbios = yes` plus `smb ports = 445` is the modern
  baseline. Do not enable nmbd; the WS2025 forest does not use NetBIOS.
- Time sync is critical for Kerberos. The proxy's chrony source is the
  WS2025 DC after join (set by `smbproxy-sconfig`), not a public pool.
- Backend cifs creds live at `/etc/samba/.legacy_creds`, mode 600,
  owned by root. The frontend share enforces a domain group via
  `valid users = @"DOMAIN\\Group"` and maps all incoming AD identities
  to a single local backend user via `force user` — that user is the one
  whose credentials sit in `.legacy_creds`.

## Private Agent State

Agents may keep private local folders such as `.claude/`, `.codex/`,
`.cursor/`, `.continue/`, or `.aider*`. These are ignored and should not be
published.

Shared project knowledge belongs in tracked Markdown files, not in private
agent folders.

## Vendor-Specific Notes

### Claude Code

Claude Code reads `CLAUDE.md` by convention. In this repo, `CLAUDE.md` is a
compatibility entry point that points back to this neutral guide.

### Codex

Codex-style agents should use this file as the project brief and follow the
repo's normal git hygiene. Keep local `.codex/` state private.

### Local Lightweight Agents

Local agents are useful for boilerplate, scaffolding, lint-only edits, simple
renames, and repetitive doc generation. They should be given narrow ownership
and should not make broad architectural changes without human or senior-agent
review.
