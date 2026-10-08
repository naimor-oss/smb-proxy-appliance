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
(e.g. Clarion `.TPS`) to AD-joined Windows clients while Samba preserves one
frontend share-mode/lock namespace and byte-range locks also reach the legacy
SMB1 server. The proxy preserves independent client lock ownership by mapping
every downstream authenticated tree to a distinct upstream SMB1 session while
normalizing their Samba file IDs. The same machinery generalizes to any aging SMB1/SMB2 file server that needs to
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

For the legacy profile, the dedicated link contains the SMB1 traffic. Each
downstream authenticated tree gets a distinct upstream SMB1 session and
forwards byte-range locks to the legacy server. Samba must also remain the
shared frontend lock/share-mode arbiter across those sessions.

| NIC role | Network | Initial state | Final state |
| --- | --- | --- | --- |
| **Domain NIC** | AD domain LAN | DHCP (for install + updates) | Static; gateway + DNS = WS2025 DC |
| **Legacy NIC** | LegacyZone (e.g. 172.29.137.0/24) | unconfigured | Static, **no gateway, no DNS** |

NIC role identification happens once at first-boot via the `smbproxy-init`
console wizard. The operator picks each NIC by MAC address (the wizard
shows MAC, link-up state, and any DHCP lease present, so the choice is
unambiguous). The mapping is persisted as `/etc/smbproxy/nic-roles.env`
and consumed by `smbproxy-sconfig` thereafter.

Samba binds only to the loopback and domain interfaces. Before `smbd` starts,
the member server replaces its AD DNS A-record set with the current IPv4
address(es) from the domain NIC; the private legacy address must never be
published to office clients.

## Locking Semantics for ISAM-style Databases (legacy profile)

The frontend share disables oplocks and requests strict locking. A private VFS
module maps each downstream authenticated tree to its own CIFS mount, SMB1
transport/session, and CIFS superblock. Samba's real `vuid` (authenticated
session wire ID) and `cnum` (tree wire ID), plus the serving process ID, form
the lifecycle key; usernames and process-name heuristics are not used.

The canonical module source, exact-Samba package build, compatibility ledger,
and Trixie update automation live in the sibling
[`../smbproxy-session-vfs`](../smbproxy-session-vfs/) repository. This
appliance owns the mount helper and configuration, and pins the component in
`components/smbproxy-session-vfs.env`. Advance the component first and the
appliance pin second.

Because the module is built for one exact Samba revision, every installed
package from Debian's `samba` source is held (`smbproxy-samba-hold apply`,
run by `prepare-image.sh` and before every menu-driven update). Never remove
the hold to "fix" a pending-update warning: an unheld `apt full-upgrade`
either moves Samba past the module (the version guard then stops `smbd`) or
removes the module package. Samba moves only through a qualified update
bundle that releases the hold, installs the new Samba and matching module
together, and re-applies the hold. Already-deployed units get the hold from
`updates/samba-hold-1.0`.

Distinct CIFS superblocks have distinct `st_dev` values. Without correction,
Samba therefore treats the same backend inode as unrelated files and splits
its share-mode and lock databases, which breaks SMB semantics and can corrupt
multi-user ISAM data. The standard `fileid` VFS module must follow
`smbproxy_session` with `fileid:algorithm = fsname`; it maps mounts of the same
backend share to one Samba device identity while leaving the upstream SMB1
transports distinct. With `posix locking = yes` and no `nobrl`, byte-range
locks are also translated to SMB1 locking requests. Reusing the same
credentials is valid: lock ownership is separated by upstream sessions and
opens, not by usernames.

Frontend (`/etc/samba/smb.conf` per share):

```
vfs objects     = smbproxy_session fileid
fileid:algorithm = fsname
oplocks         = no
level2 oplocks  = no
strict locking  = yes
kernel oplocks  = no
posix locking   = yes
```

Backend (cifs mount options) — diverges per profile:

```
legacy:  vers=1.0,cache=none,hard,serverino,nosharesock
modern:  vers=3,seal,serverino,nosharesock,soft,echo_interval=10
```

Legacy mounts are transient under `/run/smbproxy/sessions/` and never appear
in `/etc/fstab`. `nobrl` is forbidden because it would suppress the lock
requests the design must preserve. `cache=none` avoids client data caching;
each tree uses a separate mount point and `nosharesock` forces a distinct SMB1
transport/session. The lock-isolation gate must confirm distinct live `st_dev`
identities and one normalized Samba file ID for the same file across them;
`serverino` supplies backend inode numbers. `hard` is explicit so an in-flight database write waits for the
backend rather than failing mid-write. A tree disconnect unmounts its upstream session. Service start/stop
also sweeps stale mounts left by crashes.

The VFS module uses Samba's private source3 ABI and is built against the exact
Debian Samba package revision installed in the image. If that package revision
changes, the service version guard fails closed for configured legacy shares
until the module is rebuilt. Do not weaken that guard.

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
  chdir-on-automount. This applies to both direct profiles. A failed probe
  writes a runtime hint and wakes the health worker; the worker still performs
  its own independent probe before withdrawing the share.

The legacy profile deliberately stays HARD — under .TPS multi-writer
workloads, a soft-mount mid-write error would corrupt the database. The legacy
pre-connect TCP probe affects only new trees and never closes an existing hard
session mount.
The periodic share worker marks every direct share `available = no`
after two failed probes, overrides its effective path with the inert local
`/run/smbproxy/offline` directory, and reloads Samba. The path override keeps
unrelated tree connects from blocking while Samba checks a disconnected CIFS
mount. New connections fail with an unavailable-share response; existing
sessions are not force-closed.

For a modern/direct share whose backend is offline, the worker waits until a
later pass after the Samba withdrawal. It then stops the generated `.mount`
and `.automount` units only if `smbstatus` reports no frontend session for that
share. If a session exists or session state cannot be read, cleanup is deferred
and retried. Recovery starts the automount and must pass a bounded backend
mount/list probe before the share is published again.

## Share lifecycle (add, reconfigure, remove)

Code-review session plan 02. A legacy share is never changed or removed
underneath live SMB1 sessions:

1. **Withdraw.** `smbproxy-session-mount withdraw SHARE REASON` writes a
   durable marker (`/var/lib/smbproxy/lifecycle/<safe>.withdrawn`) and then
   takes the per-share lock (`/run/lock/smbproxy-share/<safe>.lock`)
   exclusively once, as a barrier. Every VFS `connect` holds that lock
   shared while it checks the marker and mounts, so once `withdraw`
   returns no new upstream session can start.
2. **Drain.** `share_drain` closes the share's trees and waits
   (`SMBPROXY_DRAIN_SECONDS`, default 30) for their sessions to end, then
   releases the upstream mounts. A session still in use is never
   force-unmounted; the operation fails instead.
3. **Commit.** Removal strips the section, reloads `smbd` (checked), and
   deletes state and credentials. A reconfigure writes the new generation.
4. **Unwithdraw.** Only after the commit succeeds.

Lock order everywhere: per-share lifecycle → share worker → smb.conf.
Nothing holds a lock while waiting for clients to disconnect.

Applying a change is transactional (code-review session plan 06).
`configure_share` snapshots the share's credentials, state file,
`/etc/fstab`, and `smb.conf` into a root-only directory under `/run`
before writing anything, then checks `daemon-reload`, the state write,
and the `smbd` reload. Any failure restores the snapshot byte for byte
and reloads (rc 14: the previous configuration is active). If even that
fails, a legacy share is withdrawn, the snapshot is kept and named in
`/var/log/smbproxy-share.log`, and rc 15 is returned. The backend
password variable is cleared on every return path.
`tests/root/config-transaction.sh` covers each case.

Failure behavior: a removal that cannot drain returns non-zero, keeps
state and credentials, and leaves the share **withdrawn** (connections
refused) with the exact re-run command. A reconfigure that cannot drain
changes nothing and re-admits clients. The marker survives a reboot, so
an interrupted change fails closed; the share status shows `WITHDRAWN`.
Re-running the removal or the change clears it. Only backend, identity,
credential, profile, offline-mode, or locking changes drain; an AD-group
change does not. `tests/root/share-lifecycle.sh` (root, disposable
container; CI runs it) reproduces the old removal race and proves the
new ordering.

## Offline behavior

`PROFILE` selects backend protocol, caching, and locking. `OFFLINE_MODE`
selects what office clients see when that backend is unavailable:

- `direct` (default and migration behavior) publishes the live cifs
  mount and fails new connections quickly while the backend is down.
- `queued` publishes a local directory on `/srv/smbproxy-data` at all
  times and delivers office-managed changes one-way when the backend
  returns. It is supported only for the modern file-copy profile.

Queued mode never imports machine-side files. It requires a stable
checksum on two worker passes, uploads changed office files by temporary
name plus atomic rename, records successful local checksums in a
manifest, and deletes only previously managed paths.
Thus machine-only nests and operator-renamed copies remain untouched.
An unchanged office source does not overwrite a same-name machine edit;
the next office update intentionally does. Office-side deletion is
authoritative for previously managed programs.

Queued data must live on a separately attached ext4 disk mounted at
`/srv/smbproxy-data`; it is not embedded in the release OVA. See
[`docs/OFFLINE-DEVICE-FAILFAST.md`](docs/OFFLINE-DEVICE-FAILFAST.md).

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

Verify active upstream sessions + frontend lock state:

```bash
ssh -J nmadmin@server debadmin@<proxy> 'sudo findmnt -t cifs; sudo smbstatus -L; sudo tail -40 /var/log/smbproxy-session-mount.log'
```

## Multi-share data model

Each proxied share has independent state:

- `/var/lib/smbproxy/shares/<safe>.env` — the share's
  non-credential coordinates (`SHARE_NAME`, `BACKEND_IP`,
  `BACKEND_USER`, `BACKEND_DOMAIN`, `BACKEND_MOUNT`, `FRONT_GROUP`,
  `FRONT_FORCE_USER`, `PROFILE`, `OFFLINE_MODE`).
- `/etc/samba/.creds-<safe>` (mode 0600 root:root) — the cifs
  username / password / domain for THIS share's backend mount. Each
  share authenticates to the backend with its own account.
- Modern/direct shares have one `/etc/fstab` line pointing at their own creds
  file. Legacy/direct shares have no static mount; each downstream tree gets a
  runtime mount under `/run/smbproxy/sessions/` using that share's creds file.
- One `[SHARE_NAME]` section in `/etc/samba/smb.conf` per share.
- Queued office data under `/srv/smbproxy-data/shares/<safe>` and its
  delivery manifest under `/srv/smbproxy-data/state/<safe>/manifest`.

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

### Persisted state is data, never code

Every state file above, plus `/etc/smbproxy/nic-roles.env`, the worker
health records under `/var/lib/smbproxy/health/`, and the first-boot
detection cache `/var/lib/smbproxy-init-detected.env`, is read with
appliance-core `kvstate.sh` (`appcore_kv_load` / `appcore_kv_get`) and
written with `appcore_kv_write`, against a fixed key list per file
(`SHARE_STATE_KEYS`, `ROLES_KEYS`, `DEPLOY_KEYS`, `HEALTH_KEYS` in
`smbproxy-sconfig.sh`). Nothing sources them. A malformed file fails
closed: the session helper refuses the connect, the version guard treats
the share as legacy (guard applies), the worker skips the share, and the
configurator drains before changing it. If `kvstate.sh` is missing, every
reader fails closed the same way; `prepare-image.sh` refuses to build an
image without it. The POSIX `sh` login banner reads single keys with
`awk` and keeps only name/MAC/domain characters.
`configure_share_apply` validates every field (`share_fields_validate`)
before anything is written. The frozen `updates/inplace-0.4.0/` bundle
still sources state on the pre-0.4.0 units it targets and is not changed.

## Checks

```bash
bash -n prepare-image.sh smbproxy-sconfig.sh smbproxy-share-worker \
  lab/run-scenario.sh lab/scenarios/*.sh tests/*.sh
bash tests/unit-helpers.sh
bash tests/share-worker.sh
bash tests/domain-dns.sh
bash tests/session-mount.sh
bash tests/vfs-contract.sh
bash tests/vfs-version-check.sh
bash tests/samba-hold.sh
# root-only, in a throwaway container (CI runs it):
# (mounts the parent so ../appliance-core supplies kvstate.sh)
docker run --rm -v "$PWD/..":/ws:ro -e DISPOSABLE_ROOT_TEST=1 \
    debian:trixie bash /ws/smb-proxy-appliance/tests/root/share-lifecycle.sh
docker run --rm -v "$PWD/..":/ws:ro -e DISPOSABLE_ROOT_TEST=1 \
    debian:trixie bash /ws/smb-proxy-appliance/tests/root/config-transaction.sh
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
- Never put a password in a command's arguments (`--password=`,
  `--adminpass=`, `--newpassword=`, `-U user%pass`): `/proc/<pid>/cmdline`
  is readable by every local user. The join feeds `kinit` through a
  pipe; `smbclient`/`net` use `run_with_auth_file` (`-A` file in a 0700
  directory under `/run`, mode 0600, removed when the command returns;
  secrets with leading/trailing spaces are refused because Samba trims
  them). `tests/secret-free-auth.sh` enforces this.
- Never `source` or `.` a persisted state file, and never write one
  with a heredoc or `printf %q`. Use `appcore_kv_load`/`appcore_kv_write`
  with the file's key list (see "Persisted state is data, never code").
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
- **`nosharesock` is non-optional for every CIFS mount.** For legacy
  session mounts it creates the distinct upstream SMB1 transports required by
  the locking contract. For static modern mounts it prevents two shares from
  silently multiplexing onto the first share's credentials. Legacy mounts
  must never contain `nobrl`.
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
