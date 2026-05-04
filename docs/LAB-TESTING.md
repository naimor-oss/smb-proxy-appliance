# Lab Testing Guide

This guide describes the tests that matter for the SMB1↔SMB3 proxy
appliance and how to add them to the lab scenario runner.

The goal is not only "does smbd start?" The goal is to prove the proxy
faithfully bridges a hardened Windows Server 2025 forest to a legacy
WS2008 SP2 file server: NIC role assignment, AD join, backend SMB1
mount with the right `nobrl` / `cache=none` semantics, frontend SMB3
share with strict locking and oplocks-off, identity mapping via
winbind to a single local backend `force user`, and recovery from the
common deployment mistakes.

## Test Runner Model

`lab/run-scenario.sh` runs from the Mac. It is a thin wrapper that
invokes the generic `../lab-kit/bin/run-scenario.sh` with
`LAB_ENV=lab/proxy.env`. A scenario is a shell file in
`lab/scenarios/` that defines:

| Function | Required | Purpose |
| --- | --- | --- |
| `run_scenario` | yes | Performs the action under test, usually over SSH into `smbproxy-1`. |
| `verify` | yes | Asserts the desired final state and returns non-zero on failure. |
| `pre_hook` | no | Optional setup after VM revert and push, e.g. WS2025-side AD cleanup of the proxy's computer account. |
| `post_hook` | no | Optional evidence collection or cleanup after verification. |

The generic pipeline (from `lab-kit`) is:

1. Stage helper scripts listed in `LAB_STAGE_SOURCES` to `LAB_STAGE_DIR`
   (`/Volumes/ISO/lab-scripts`). For the proxy this pulls from this repo
   plus `../lab-kit/hypervisors/hyperv/` and
   `../lab-router/hypervisors/hyperv/`. The proxy does **not** stage
   WS2025-DC1 helpers — the samba-addc-appliance lab already provides
   the DC and we just join it.
2. Revert `smbproxy-1` to `golden-image` via `Revert-TestVM.ps1`.
3. Push `prepare-image.sh` and `smbproxy-sconfig.sh` to the VM.
4. Run `LAB_POST_PUSH_CMD` (installs `smbproxy-sconfig` under
   `/usr/local/sbin`).
5. `pre_hook` (scenario-owned — this is where AD or backend-mount
   cleanup lives; the smoke scenario does not need cleanup).
6. `run_scenario` and `verify`.
7. `post_hook`.
8. Transcript is written to `test-results/<scenario>-<timestamp>.log`.

## Existing Scenarios

The implemented scenarios compose by sourcing each other. Each one is
runnable on its own from a freshly reverted `golden-image`; downstream
scenarios drive the upstream pipeline as their `pre_hook`.

```text
bootstrap-network ── used by ──► join-domain
                              └► backend-mount ── used by ──► frontend-share ──► end-to-end
                                                          └► multi-share
```

Source-time relationships:
- `frontend-share` sources `join-domain` + `backend-mount` and adds
  `SC_GROUP` so `do_configure_backend()` becomes a full backend +
  frontend `--configure-share`.
- `multi-share` sources `join-domain` + `backend-mount` and calls
  `do_configure_backend()` twice with different `SC_*_A` / `SC_*_B`
  per-share inputs.
- `end-to-end` sources `frontend-share` and adds the per-share
  `--status` check + the optional WS2008 read/write roundtrip
  (`SC_WRITE_ROUNDTRIP=1`).

Backend credentials handling: scenarios that need the WS2008 password
read it from `SC_BACKEND_PASS`. `lab/run-scenario.sh` automatically
sources `lab/backend-creds.env` (gitignored by `*creds*` in
`.gitignore`) before invoking the scenario, so the local workflow is:

```bash
cp lab/backend-creds.env.example lab/backend-creds.env
$EDITOR lab/backend-creds.env       # set SC_BACKEND_PASS to the real value
```

The original credential is in `docs/sketch-smb1-smb3-proxy.sh`. Never
copy it into a scenario file.

### `smoke-prepared-image`

Purpose: verify the golden image is still a clean appliance base
before any domain or backend operation.

Assertions (see `lab/scenarios/smoke-prepared-image.sh` for the full list):

- `smbproxy-sconfig` is installed and executable.
- The required tooling is present: samba/smbd/winbindd, smbclient,
  mount.cifs, net, wbinfo, kinit/klist, nft, chronyd, dig, whiptail.
- `samba-ad-dc` is **not** installed (the proxy is a member server only).
- `/etc/samba/smb.conf` does not exist.
- `smbd`, `nmbd`, and `winbind` are not enabled yet.
- `/etc/krb5.conf` is the deployment-neutral skeleton with `YOURREALM.LAN`.
- chrony has no public NTP pool baked into the image.
- No backend cifs creds files (no `/etc/samba/.creds-*`, no
  legacy-singleton paths) and no live cifs mount.
- `smbproxy-firstboot` has run (the marker exists in golden-image),
  but `smbproxy-init` has not been completed by an operator.
- NIC role mapping is empty (operator picks via the wizard).
- The domain NIC has the dnsmasq-reserved IP `10.10.10.30`.
- A second ethernet link is present at the kernel level (the
  LegacyZone NIC).
- Network is alive through `router1`.

Why it matters: failed domain joins and silent backend-mount
mis-mounts are much easier to debug when the base image is known-good
and deliberately unprovisioned.

Run:

```bash
lab/run-scenario.sh smoke-prepared-image
```

Iterate only on verification:

```bash
lab/run-scenario.sh smoke-prepared-image --verify-only
```

### `bootstrap-network`

Purpose: headless equivalent of the `smbproxy-init` wizard's "assign
NIC roles + bring up legacy NIC" step. Without this, every subsequent
scenario fails because there's no roles file and the legacy NIC has
no IP.

What it does:

- Identifies the domain NIC by its current IP (`LAB_VM_IP` =
  10.10.10.30) and the legacy NIC as the only other ethernet.
- Writes `/etc/smbproxy/nic-roles.env` in the format the wizard
  produces.
- Writes `/etc/netplan/60-smbproxy-init.yaml` with the legacy NIC
  pinned to `SC_LEGACY_CIDR` (default 172.29.137.10/24, gateway-less,
  DNS-less). Domain NIC stanza keeps DHCP.
- `netplan apply`.

Verification:

- `nic-roles.env` populated with both names + MACs.
- Netplan file is mode 0600.
- Domain NIC still has 10.10.10.30; legacy NIC has the configured
  CIDR.
- Default route does NOT go via the legacy NIC.
- LegacyZone reachability (informational ping; the cifs mount in
  `backend-mount` is the authoritative test).

Run:

```bash
lab/run-scenario.sh bootstrap-network
```

### `join-domain`

Purpose: join the proxy to the WS2025 forest the samba-addc-appliance
lab already runs (`lab.test` / WS2025-DC1 @ 10.10.10.10) as a member
server.

`pre_hook` runs `bootstrap_network` and removes the `smbproxy-1`
computer account from WS2025-DC1. The cleanup respects
`--no-cleanup` (sets `SC_SKIP_CLEANUP=1`) and `--dry-cleanup` (sets
`SC_DRY_CLEANUP=1`), the same way the samba sibling's `join-dc` does.

`run_scenario` drives `smbproxy-sconfig --join-domain` headlessly,
piping `SC_PASS` to `--pass-stdin` so the password never lands in a
process listing on the VM.

Verification:

- `smbproxy-sconfig --status` shows `joined: yes` and the right realm.
- `smbd` and `winbind` are active.
- `net ads info -P` reports a live KDC for the upper-cased realm.
- `wbinfo -t` (trust check) succeeds and `wbinfo -u` lists at least
  Administrator.
- `kinit Administrator@LAB.TEST` succeeds and `klist` shows the
  krbtgt entry.
- `/etc/krb5.conf` no longer mentions `YOURREALM.LAN`; default_realm
  is the deployed realm.
- chrony's source is the DC (or its FQDN), not a public pool.
- `smb.conf` reflects `realm=lab.test`, `workgroup=LAB`,
  `security=ads`.
- `Get-ADComputer smbproxy-1` succeeds on WS2025-DC1.

Run:

```bash
lab/run-scenario.sh join-domain
lab/run-scenario.sh join-domain --dry-cleanup    # inspect AD without removing
lab/run-scenario.sh join-domain --no-cleanup     # skip AD cleanup entirely
```

### `backend-mount`

Purpose: configure ONE proxied share's backend half via
`smbproxy-sconfig --configure-share` (without `--group`, so smb.conf
is not touched) and verify the cifs mount comes up with the
locking-correct options. This is the "configure backend pre-join"
test path.

Requires `SC_BACKEND_PASS` in the environment — see
`lab/backend-creds.env.example` for the recommended
`lab/backend-creds.env` workflow. The scenario fails fast in
`pre_hook` with a clear error if the password is unset.

`pre_hook` runs `bootstrap_network` only; backend mount is
independent of AD join (cifs uses username/password, not Kerberos),
so this scenario is safe to run on a non-joined proxy.

`run_scenario` drives `smbproxy-sconfig --configure-share
--name SC_SHARE_NAME --backend-ip ... --pass-stdin` (omitting
`--group` so the smb.conf section is deliberately skipped), then
triggers the systemd automount by `ls`-ing the mount path.

Verification:

- The per-share creds file at `/etc/samba/.creds-<safe>` is mode
  0600 root:root with the right username and domain (the password
  is never echoed).
- The per-share fstab line carries `vers=1.0`, `nobrl`,
  `cache=none`, `serverino`, `x-systemd.automount`, and points at
  the share's own creds file.
- Force-user account exists with `/usr/sbin/nologin`.
- The live cifs mount has the same options.
- The mount is readable and contains at least one entry (an empty
  share is warned about, not a failure — fresh labs may legitimately
  be empty).
- The per-share state file at `/var/lib/smbproxy/shares/<safe>.env`
  carries `SHARE_NAME` plus the backend coordinates.

Run:

```bash
lab/run-scenario.sh backend-mount
```

### `frontend-share`

Purpose: publish ONE proxied share end-to-end (backend cifs mount +
frontend smb.conf section + smbd reload + firewall) and prove the
share answers SMB3 + Kerberos with the strict-locking stanza intact.

With the multi-share refactor, frontend-share is a thin wrapper over
backend-mount that sets `SC_GROUP` so the underlying
`do_configure_backend()` (now an alias for the unified
`--configure-share`) also publishes the smb.conf section.

`pre_hook` composes `bootstrap_network`, `do_ad_cleanup_proxy`,
`require_backend_pass`, `do_join_domain`.

`run_scenario` drives `do_configure_backend` (which, with `SC_GROUP`
set, becomes the full backend+frontend `--configure-share`) and then
`--apply-firewall`.

Verification:

- The `[$SC_SHARE_NAME]` block exists in `smb.conf` with
  `oplocks=no`, `level2 oplocks=no`, `strict locking=yes`,
  `kernel oplocks=no`, `posix locking=yes`, `force user=pfuser`, the
  configured `path`, and the `valid users = @"LAB\Domain Users"` ACL.
- `testparm -s` reports no warnings/errors.
- `smbd` is listening on 445/tcp; nmbd-style 137/138 sockets are
  not open.
- nftables ruleset is loaded.
- A localhost-from-proxy `smbclient -k -L //$LAB_VM_IP -m SMB3`
  (after a `kinit Administrator@LAB.TEST`) lists the share — proving
  the SMB3 + Kerberos path end to end. A true cross-host check from
  WS2025-DC1 / samba-dc1 belongs in a future
  `Verify-FrontendShare.ps1` helper.
- The per-share state file persisted the frontend coordinates
  (`SHARE_NAME`, `FRONT_GROUP`, `FRONT_FORCE_USER`).

Run:

```bash
lab/run-scenario.sh frontend-share
```

### `multi-share`

Purpose: configure TWO proxied shares from the SAME WS2008 backend
with DIFFERENT credentials and DIFFERENT AD access groups +
force-users. This is the use case the multi-share refactor was
built for and the regression test that catches future bugs in
`remove_share`, `save_share`, `configure_share`'s sed/awk patterns,
and similar.

Requires both `SC_BACKEND_PASS_A` (defaults to `SC_BACKEND_PASS`)
and `SC_BACKEND_PASS_B` (must be set explicitly). See
`lab/backend-creds.env.example` for the full per-share knob list.

Verification:

- Two distinct per-share state files at
  `/var/lib/smbproxy/shares/<safe-A>.env` /
  `/var/lib/smbproxy/shares/<safe-B>.env`.
- Two distinct creds files at `/etc/samba/.creds-<safe>`, both
  mode 0600 root:root, each with its own username.
- Two distinct fstab cifs lines with distinct `credentials=` paths.
- Two distinct `[SHARE]` sections in `smb.conf`, each with its own
  `valid users` and `force user`.
- `testparm -s` clean for the combined config.
- `smbproxy-sconfig --list-shares` enumerates both.
- `smbproxy-sconfig --status` shows both as active with
  `smb_section: yes`.
- `smbclient -k -L` from the proxy lists both.
- Final destructive step: `--remove-share --name $SC_SHARE_B` and
  assert share A's state, fstab line, and smb.conf section are
  intact while share B's are gone — exercises `remove_share`'s
  per-share sed pattern under the exact "another share is
  configured against the same backend" condition where a wrong
  pattern would clobber the other share.

Run:

```bash
lab/run-scenario.sh multi-share
```

### `end-to-end`

Purpose: single-shot release-gate test. Composes
bootstrap → AD cleanup → join → configure-share → firewall →
roundtrip access in one continuous scenario flow (instead of split
across pre_hook + run_scenario), so the runner log shows the whole
green-field deployment as one timeline.

Reuses the `frontend-share` verify (renamed to `_frontend_verify`
via the standard `eval $(declare -f ... | sed)` pattern) and adds:

- `smbproxy-sconfig --status` shows `joined: yes`, `smbd` +
  `winbind` active, and the configured share present with
  `active=yes` and `smb_section: yes`.
- `ls $SC_BACKEND_MOUNT` is readable.
- Optional WS2008 read/write roundtrip when `SC_WRITE_ROUNDTRIP=1`:
  writes a uniquely-named test file
  (`.smb-proxy-roundtrip-<ts>-<pid>.tmp`) through the proxy, reads
  it back, deletes it. Off by default to keep the shared
  production WS2008 backend strictly read-only during test runs.

Run:

```bash
lab/run-scenario.sh end-to-end
SC_WRITE_ROUNDTRIP=1 lab/run-scenario.sh end-to-end
```

## Important Tests To Add

The following tests are the highest-value next additions.

### 1. `.TPS` lock concentration: `tps-lock-isolation`

Purpose: prove the proxy is genuinely the single arbiter of byte-range
locks against the WS2008 backend.

Assertions:

- Two concurrent SMB3 clients open the same `.TPS` file through the
  proxy; the second open observing strict-locking behavior matches
  what the application expects.
- `smbstatus -L` on the proxy lists the locks.
- `mount | grep cifs` confirms `nobrl` is still in effect (so locks
  never propagate to WS2008).
- `Get-SmbOpenFile` on the WS2008 server (or a `psexec`
  shell + `openfiles /query`) shows only the proxy's session, with no
  byte-range lock churn.

### 2. Hardening compatibility: `hardening-ws2025`

Purpose: prove the appliance keeps up with WS2025 security posture.

Assertions:

- `client min protocol = SMB3`, `server min protocol = SMB3`.
- `server signing = mandatory`, `client signing = mandatory`.
- SMB1 negotiation against the frontend share is refused.
- LDAP simple bind without TLS/signing fails when expected; SASL
  GSSAPI bind succeeds.
- Kerberos uses strong encryption.
- `testparm -s` clean.

### 3. Firewall apply: `firewall-apply`

Purpose: deeper assertions on the nftables ruleset than `frontend-share`
already does. Beyond "ruleset is loaded", verify:

- `nft list ruleset` matches the rendered template byte-for-byte.
- `ss -tnlp` shows `smbd` listening on 445 of the domain NIC only.
- An SSH from `samba-dc1` to `smbproxy-1:22` succeeds; an SSH from a
  pretend-WS2008 (using a temp listener on the LegacyZone segment) is
  rejected.

### 4. WS2008 unreachable resilience: `ws2008-down-recovery`

Purpose: prove the proxy degrades gracefully when the backend goes
away and recovers when it returns.

Assertions:

- Stop the backend cifs mount; the cifs auto-unmount logic reflects
  the failure within a bounded time.
- Frontend share `dir` returns a clear I/O error rather than hanging
  indefinitely.
- After the backend is reachable again, `systemctl restart
  remote-fs.target` (or the systemd-automount equivalent) re-attaches
  cleanly without restarting `smbd`.

### 5. Cross-host frontend access: `verify-from-ws2025`

Purpose: prove the SMB3 frontend share is reachable from a real
Windows client, not just from the proxy itself.

Add a `lab/hyperv/Verify-FrontendShare.ps1` helper that runs on the
Hyper-V host, talks to WS2025-DC1 via PSRemoting (or to the host
directly if it's domain-joined), and:

- Resolves `smbproxy-1.lab.test` and pings 445/tcp on it.
- `Get-SmbConnection` after a `New-SmbMapping` to the share with
  Kerberos credentials.
- Lists directory contents.
- Confirms an SMB1-only attempt is refused.

Then add a `verify-from-ws2025` scenario that calls the script via
`ssh_host` and asserts on its output, similar to how
`samba-addc-appliance/lab/scenarios/join-dc.sh` consumes
`Verify-JoinFromWS2025.ps1`.

## Scenario Template

Use this as a starting point for new files under `lab/scenarios/`.

```bash
# lab/scenarios/example.sh

run_scenario() {
    ssh_vm 'sudo smbproxy-sconfig --status'
}

verify() {
    local rc=0

    say "smbproxy-sconfig exists"
    ssh_vm 'test -x /usr/local/sbin/smbproxy-sconfig' || rc=1

    say "example assertion"
    ssh_vm 'true' || rc=1

    return "$rc"
}
```

Prefer assertions that check final state instead of relying only on
command exit codes. Keep evidence in the log: print the relevant
`systemctl`, `mount`, `smbstatus`, `nft list ruleset`, `wbinfo`, or
`net ads info` output before deciding pass/fail.

## Verification Commands Worth Reusing

From the proxy:

```bash
sudo smbproxy-sconfig --status            # domain-level + per-share
sudo smbproxy-sconfig --list-shares       # one SHARE_NAME per line
sudo systemctl is-active smbd winbind
sudo net ads info -P
sudo wbinfo -t
sudo wbinfo -u | head
sudo mount | grep cifs
sudo smbstatus -L
sudo testparm -s
sudo nft list ruleset
sudo cat /etc/smbproxy/nic-roles.env
sudo cat /var/lib/smbproxy/deploy.env       # domain-level only now
sudo ls /var/lib/smbproxy/shares/           # per-share state files
sudo cat /var/lib/smbproxy/shares/<SAFE>.env  # one share's coords
```

From WS2025-DC1:

```powershell
Get-ADComputer -Identity 'smbproxy-1'
Resolve-DnsName smbproxy-1.lab.test
Test-NetConnection -ComputerName 10.10.10.30 -Port 445
Get-SmbConnection
```

From the WS2008 backend (via a console session or the operator's
runbook — not from this repo's automation):

```text
net session
openfiles /query /v
```

## Adding Headless Commands

When a scenario needs to drive TUI-only behavior, add a focused
headless subcommand to `smbproxy-sconfig.sh` instead of scripting
whiptail. The current pattern (`--join-domain`, `--configure-share`,
`--list-shares`, `--remove-share`, `--apply-firewall`, `--status`) is:

- Validate required flags with explicit checks; fail with a clear
  error when missing.
- Reuse the same helper functions as the TUI.
- Read passwords from stdin (`--pass-stdin`) so scenarios can pipe
  them in without exposing them in process listings.
- Return non-zero only for failures the test should treat as scenario
  failure.

Good candidates for new headless subcommands:

- `smbproxy-sconfig --assign-roles --domain-mac MAC --legacy-mac MAC --legacy-ip CIDR`
- `smbproxy-sconfig --diag-backend`
- `smbproxy-sconfig --diag-frontend`
- `smbproxy-sconfig --enable-services` / `--disable-services`

## Test Data Hygiene

- Treat logs in `test-results/` as evidence. Keep representative
  passing logs, but avoid committing every ad-hoc run; the
  `.gitignore` already drops raw `*.log` files.
- Never commit the WS2008 backend password into a scenario file. Use
  `SC_BACKEND_PASS` env or a gitignored `lab/backend-creds.env`.
- Never rely on stale AD objects. Add a pre_hook that removes the
  proxy's computer account before scenarios that join.
- Do not tear down `router1`, `WS2025-DC1`, the `LegacyZone` switch,
  or the WS2008 SP2 backend casually. They are persistent fixtures.
- The Samba sibling and the proxy share `lab.test` — if you re-provision
  the WS2025 forest, both labs need a fresh `golden-image` rebuild.
