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

## Existing Scenario

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
- No backend cifs creds file (`/etc/samba/.legacy_creds` /
  `.ws2008_creds`) and no live cifs mount.
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

## Important Tests To Add

The following tests are the highest-value next additions, in roughly
the order they should be implemented.

### 1. NIC role assignment: `assign-nic-roles`

Purpose: verify `smbproxy-sconfig` (or a future headless variant)
records NIC roles correctly so subsequent steps know which interface
talks to AD vs. the WS2008 backend.

Assertions:

- After role assignment, `/etc/smbproxy/nic-roles.env` contains both
  `DOMAIN_NIC_NAME` and `LEGACY_NIC_NAME` with valid kernel interface
  names that resolve to MAC addresses present on the VM.
- The legacy NIC has the static IP set to a 172.29.137.0/24 address
  with no default route through it.
- The domain NIC retains its DHCP-assigned `10.10.10.30`.
- `smbproxy-sconfig --status` reflects both names.

Needed script support: a headless `smbproxy-sconfig --assign-roles`
subcommand that takes `--domain-mac` / `--legacy-mac` flags. Until
that exists, this scenario can pre-write `/etc/smbproxy/nic-roles.env`
directly and then drive `smbproxy-sconfig --apply-firewall`.

### 2. Domain join: `join-domain`

Purpose: prove the proxy can join the WS2025 forest as a member
server.

Assertions:

- `smbproxy-sconfig --join-domain` against `lab.test` /
  `WS2025-DC1@10.10.10.10` / `Administrator` succeeds.
- `net ads info -P` reports a live KDC.
- `wbinfo -t` (trust check) succeeds.
- `wbinfo -u | head` returns at least the AD Administrator account.
- `kinit Administrator@LAB.TEST` and `klist` succeed.
- `/etc/krb5.conf` no longer mentions `YOURREALM.LAN`.
- chrony's time source is the WS2025 DC, not a public pool.

Pre-hook: remove the `smbproxy-1` computer account from AD so a
re-join doesn't hit "object already exists":

```powershell
ssh_host "pwsh -Command \"Get-ADComputer -Identity 'smbproxy-1' -ErrorAction SilentlyContinue | Remove-ADComputer -Confirm:\$false\""
```

Run:

```bash
lab/run-scenario.sh join-domain
```

### 3. Backend mount: `backend-mount-ws2008`

Purpose: prove the SMB1 cifs mount of the WS2008 share comes up with
the locking-correct options.

Assertions:

- `smbproxy-sconfig --configure-backend` against `172.29.137.1` /
  `ProfitFab$` / `pfuser` / `LEGACY` succeeds.
- `mount | grep cifs` shows `vers=1.0`, `nobrl`, `cache=none`,
  `serverino`.
- Reading a known-good file under the mount succeeds.
- `smbstatus -L` lists no leases or oplocks for that mount.

Backend password handling: scenarios that need the WS2008 password
read it from `SC_BACKEND_PASS` or, if unset, source
`lab/backend-creds.env` (gitignored by `*creds*` in `.gitignore`).
Never bake the password into a scenario file. Example:

```bash
# lab/backend-creds.env  (gitignored)
SC_BACKEND_PASS='replace-me'
```

### 4. Frontend share: `frontend-share-publish`

Purpose: prove the published SMB3 frontend share is reachable from
WS2025 with the strict-locking semantics intact.

Assertions:

- `smbproxy-sconfig --configure-frontend` succeeds with a sample share
  name and AD group.
- `testparm -s` reports no global-parameter-in-share-section warnings
  and the share has `oplocks = no`, `level2 oplocks = no`,
  `strict locking = yes`, `kernel oplocks = no`, `posix locking = yes`,
  `force user = pfuser`, `valid users = @"LAB\<group>"`.
- `smbclient //10.10.10.30/<share> -k` from `samba-dc1` (which is
  Kerberos-authenticated against `lab.test`) lists the share contents.
- A SMB3-only client mount from WS2025-DC1 succeeds; an SMB1 client
  attempt is rejected.

### 5. `.TPS` lock concentration: `tps-lock-isolation`

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

### 6. Hardening compatibility: `hardening-ws2025`

Purpose: prove the appliance keeps up with WS2025 security posture.

Assertions:

- `client min protocol = SMB3`, `server min protocol = SMB3`.
- `server signing = mandatory`, `client signing = mandatory`.
- SMB1 negotiation against the frontend share is refused.
- LDAP simple bind without TLS/signing fails when expected; SASL
  GSSAPI bind succeeds.
- Kerberos uses strong encryption.
- `testparm -s` clean.

### 7. Firewall apply: `firewall-apply`

Purpose: prove `--apply-firewall` produces a working nftables ruleset
that lets SMB3 in on the domain NIC, lets SMB1 *out* on the legacy
NIC, and blocks everything else.

Assertions:

- `nft list ruleset` after `smbproxy-sconfig --apply-firewall` matches
  the rendered template.
- `ss -tnlp` shows `smbd` listening on 445 of the domain NIC only.
- An SSH from `samba-dc1` to `smbproxy-1:22` succeeds; an SSH from a
  pretend-WS2008 (using a temp listener on the LegacyZone segment) is
  rejected.

### 8. WS2008 unreachable resilience: `ws2008-down-recovery`

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

### 9. End-to-end: `end-to-end`

Compose the above into a single sequenced scenario for release-gate
testing: assign roles → join → backend mount → frontend share →
firewall → smoke a `.TPS` access from a WS2025-side client.

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
sudo smbproxy-sconfig --status
sudo systemctl is-active smbd winbind
sudo net ads info -P
sudo wbinfo -t
sudo wbinfo -u | head
sudo mount | grep cifs
sudo smbstatus -L
sudo testparm -s
sudo nft list ruleset
sudo cat /etc/smbproxy/nic-roles.env
sudo cat /var/lib/smbproxy/deploy.env
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
whiptail. The current pattern (`--join-domain`,
`--configure-backend`, `--configure-frontend`, `--apply-firewall`,
`--status`) is:

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
