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
13. The appliance fronts a hardened legacy SMB1 file server (typically
reachable only over a dedicated point-to-point link) and re-publishes
**one or more of its shares** to a modern Windows Server 2025 forest as
AD-joined SMB3 shares — each share with independent backend credentials
and AD access groups.

Motivating use case: serving multi-user ISAM-style database files
(e.g. Clarion `.TPS`) to AD-joined Windows clients while the byte-range
locking and oplock semantics those databases require are enforced **at
the proxy** rather than across the WAN to the legacy backend. The same
machinery generalizes to any aging SMB1/SMB2 file server that needs to
be re-published into a modern AD forest, plus a `modern` profile for
standalone SMB2/3 devices (CNC HMIs, NAS units) being consolidated
into DFS-N — see `Profiles` below.

The appliance has two core scripts:

- `prepare-image.sh`: one-time Debian image preparation. Vendor-neutral,
  realm-neutral, credential-free. Produces a host-agnostic master image.
- `smbproxy-sconfig.sh`: whiptail TUI plus headless CLI for NIC role
  assignment, AD domain join, multi-share management (add / edit /
  remove / mount each proxied share with its own creds + AD group),
  hardening, diagnostics, and service maintenance.

This repo is a sibling of:

- [`samba-addc-appliance`](../samba-addc-appliance/) — the Samba AD DC
  appliance that this proxy joins as a member server.
- [`lab-kit`](../lab-kit/) — reusable appliance lab orchestration.
- [`lab-router`](../lab-router/) — simple reusable lab router appliance.

## Dual-NIC Model

For the legacy profile, the proxy is the only writer the legacy backend
ever sees, so all locking is enforced locally by Samba and the backend
mount uses `nobrl` to avoid pushing locks across SMB1.

| NIC role | Network | Initial state | Final state |
| --- | --- | --- | --- |
| **Domain NIC** | AD domain LAN | DHCP (for install + updates) | Static; gateway + DNS = WS2025 DC |
| **Legacy NIC** | LegacyZone (e.g. 172.29.137.0/24) | unconfigured | Static, **no gateway, no DNS** |

NIC role identification happens once at first-boot via the `smbproxy-init`
console wizard. The operator picks each NIC by MAC address (the wizard
shows MAC, link-up state, and any DHCP lease present, so the choice is
unambiguous). The mapping is persisted as `/etc/smbproxy/nic-roles.env`
and consumed by `smbproxy-sconfig` thereafter.

## Locking Semantics for ISAM-style Databases (legacy profile)

The frontend share enforces strict locking; the backend mount delegates
nothing. This is correct for `.TPS`-style ISAM databases because the
proxy is the single arbiter of all writes the legacy backend sees.

Frontend (`/etc/samba/smb.conf` per share):

```
oplocks         = no
level2 oplocks  = no
strict locking  = yes
kernel oplocks  = no
posix locking   = yes
```

Backend (cifs mount options) — diverges per profile:

```
legacy:  vers=1.0,nobrl,cache=none,serverino,nosharesock
modern:  vers=3,seal,serverino,nosharesock,soft,echo_interval=10
```

`nobrl` (legacy only) deliberately silences kernel-level byte-range
lock propagation so the backend never sees lock requests; `cache=none`
(legacy only) removes the read cache that could mask conflicts;
`serverino` keeps inode numbers stable across remounts; `nosharesock`
forces a separate TCP/SMB session per cifs mount so multi-share
configs against the same backend don't multiplex onto a single
session and silently reuse the first share's credentials.

**`soft,echo_interval=10` (modern only)** is one of several layered
defenses that target the offline-device hang. The kernel cifs default
of `hard` makes I/O block indefinitely waiting for an unreachable
backend's TCP socket — a Windows client with a drive letter to the
proxied share then sees Open Dialog and Explorer hang for ~60-75s on
every directory listing when the backend device is off (CNC powered
down, NAS rebooted). With `soft` + a 10-second heartbeat, the kernel
returns I/O errors ~10s after the backend disappears.

Companion defenses ship alongside `soft`:

- `x-systemd.mount-timeout=4` in fstab caps each automount attempt
  at 4 s (down from a ~6 s same-/24 ARP probe cycle) for the
  device-was-off-all-along case.
- `root preexec = /usr/local/sbin/smbproxy-probe-backend %S` with
  `root preexec close = yes` runs a 1 s TCP probe of the backend at
  tree-connect time. An unreachable backend short-circuits the tree
  connect at ~1 s instead of letting the client cycle through
  chdir-on-automount.

The legacy profile deliberately stays HARD with no probe — under
.TPS multi-writer workloads, a soft-mount mid-write error would
corrupt the database, and the legacy zone is expected to be
always-on so the offline annoyance doesn't apply there.

A residual ~30 s Windows-retry wait remains in the modern-profile
offline case because Samba returns `NT_STATUS_ACCESS_DENIED` for
preexec failures (hardcoded), which Windows treats as a transient
condition and retries in bursts. The deferred design that closes it
(periodic `available = no` toggling via a systemd timer) is
documented in [`docs/OFFLINE-DEVICE-FAILFAST.md`](docs/OFFLINE-DEVICE-FAILFAST.md).

## Persistent Infrastructure

Do not tear these down casually:

- The Hyper-V switch carrying the LegacyZone subnet (172.29.137.0/24).
- The legacy SMB1 staging server VM. It contains test data only, but its
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

List configured proxied shares + their state:

```bash
ssh -J nmadmin@server debadmin@<proxy> 'sudo smbproxy-sconfig --list-shares'
ssh -J nmadmin@server debadmin@<proxy> 'sudo smbproxy-sconfig --status'
```

Verify backend mounts + share locks (one cifs entry per share):

```bash
ssh -J nmadmin@server debadmin@<proxy> 'sudo mount | grep cifs; sudo smbstatus -L'
```

## Multi-share data model

Each proxied share has independent state:

- `/var/lib/smbproxy/shares/<safe>.env` — the share's
  non-credential coordinates (`SHARE_NAME`, `BACKEND_IP`,
  `BACKEND_USER`, `BACKEND_DOMAIN`, `BACKEND_MOUNT`, `FRONT_GROUP`,
  `FRONT_FORCE_USER`).
- `/etc/samba/.creds-<safe>` (mode 0600 root:root) — the cifs
  username / password / domain for THIS share's backend mount. Each
  share authenticates to the backend with its own account.
- One line in `/etc/fstab` per share, each pointing at its own
  creds file.
- One `[SHARE_NAME]` section in `/etc/samba/smb.conf` per share.

`SHARE_NAME` is used as **both** the backend share name and the
published SMB3 share name (operator picks one name; it appears at
both ends). `<safe>` is `SHARE_NAME` with non-alphanumeric
characters replaced by underscore — a `$`-bearing share like
`Engineering$` stores as `Engineering_.env` /
`.creds-Engineering_` on the filesystem while the literal name
lives in `SHARE_NAME` and in `smb.conf`.

Domain-level state (`REALM`, `DOMAIN_SHORT`, `DC_HOST`, `DC_IP`)
lives in `/var/lib/smbproxy/deploy.env`; nothing share-specific is
kept there.

## Checks

```bash
bash -n prepare-image.sh smbproxy-sconfig.sh lab/run-scenario.sh lab/scenarios/*.sh tests/unit-helpers.sh
```

## Development Rules

- Prefer small, reviewable changes.
- Never bake realm, DC IP, backend IP, share name, or credentials into
  `prepare-image.sh`. They belong in `smbproxy-sconfig`.
- For any whiptail dialog that operates on **one specific share**
  (input prompt, password prompt, confirmation yesno), put the share
  name in the dialog **body**, not just the title. Title-only context
  is too subtle for an operator working through a multi-share flow.
  The convention used throughout `menu_shares` is to open the body
  with `Share: ${SHARE_NAME}` on its own line followed by a blank
  line and then the prompt. Same rule applies to per-NIC dialogs
  (the role being assigned goes in the body) and any future
  per-instance dialog.
- Never commit `*creds*` files or anything containing the backend
  password. The `.gitignore` covers the obvious paths; if you add a new
  one, extend the `.gitignore` rather than rely on memory.
- Do not modify the legacy backend server from this repo. Backend
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
- Backend cifs creds live at `/etc/samba/.creds-<safe>`, mode 0600,
  owned by root, **one file per proxied share**. Each frontend
  share section enforces an AD security group via `valid users =
  <SID>` (the AD group's SID, resolved by `wbinfo --name-to-sid`
  at config time) and maps all incoming AD identities to a single
  local backend user via `force user = <username>` — that local
  user's credentials sit in this share's `.creds-<safe>` file.
  Different shares can use different backend users with different
  passwords against the same backend server; that's the multi-share
  model.
- **Why SIDs for `valid users` and usernames for `force user`.**
  The proxy runs with `winbind use default domain = yes`, which
  publishes every AD account to NSS under its bare lowercased name.
  Two different forms are required for two different reasons:
  - `valid users = @"DOMAIN\Group"` fails to match in Samba 4.22 on
    this appliance under default-domain mode; the SID form is
    NSS-independent and unambiguous. `configure_share` resolves the
    group to its SID via `wbinfo --name-to-sid` at config time.
  - `force user = <numeric UID>` does **not** work — Samba resolves
    `force user` via `getpwnam()`, and `getpwnam("1003")` fails even
    though `getpwuid(1003)` succeeds. This causes `NT_STATUS_NO_SUCH_USER`
    at tree-connect (confirmed 2026-05-07, broke the WorkData share).
    `force user` must use the local username string. Because the NSS
    order is `files systemd winbind`, the local `/etc/passwd` entry is
    found before winbind is consulted, so `getpwnam("tubelaser")`
    returns the local account even when winbind is active.
  - The remaining collision risk — a force-user name that also exists
    as an AD account — is caught at config time: `configure_share`
    calls `wbinfo --name-to-sid` on the chosen name and **refuses**
    the configuration (returns rc=9) if it resolves. The check uses
    `wbinfo` rather than `id` / `getent` because those go through NSS
    and a local entry shadows the winbind one, hiding the collision.
    The cifs `uid=` and `gid=` mount options continue to use the
    numeric UID (that is a kernel cifs option and is correctly
    interpreted as a UID).
- **`nosharesock` is non-optional in cifs fstab options.** Without
  it, two cifs mounts to the same backend with different per-share
  creds get multiplexed onto a single TCP/SMB session and the second
  mount silently reuses the first's credentials, defeating the
  multi-share model. Same prod incident, 2026-05-05.
- **Operator mental model: the force-user is a backend identity,
  not a login.** Treat `force user` as "the local Linux account that
  owns the cifs mount and presents to the legacy backend" — it is
  not the AD user that Windows clients authenticate as, and it
  should not share a name with any AD account in use. AD identity
  is enforced upstream of `force user` by the SID-based `valid
  users` ACL.

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
