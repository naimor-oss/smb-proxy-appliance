# Modern-profile offline-device fail-fast

## What this is about

A modern-profile proxied share fronts a backend device that is
expected to be powered off some of the time (CNC, NAS unit, HMI). The
goal is that when the backend is off, a Windows client opening
`\\smb-proxy\<share>` sees a fast, clean error — ideally a greyed-out
share in Explorer — instead of the ~60–75 second hang that direct
SMB to the device produces.

This document records the layered defenses we ship today, the
**residual ~30-second wait** that we have not yet eliminated, and the
deferred design that would close it.

## Layered defenses currently shipped

1. **`soft,echo_interval=10` cifs mount options.** When the device
   goes offline *while* the kernel cifs mount is established, the
   echo heartbeat detects the dead connection and `soft` makes
   pending I/O return errors instead of blocking. Tuned for the
   transition from connected→disconnected.

2. **`x-systemd.mount-timeout=4` in fstab.** Caps each automount
   attempt at 4 seconds. Without this, an offline backend on the
   same /24 takes ~6 seconds (ARP probe cycle) to fail. Tuned for
   the per-attempt cost when the device was off all along.

3. **`root preexec = smbproxy-probe-backend %S`** (modern profile
   only) with `root preexec close = yes`. A 1-second TCP probe of
   `BACKEND_IP:445` runs at tree-connect time. If it fails, Samba
   aborts the tree connect immediately rather than letting the
   client fall through to the chdir-on-automount path. Reduces
   per-attempt cost from ~4 s to ~1 s.

4. **`backend_mount_active` checks `/proc/mounts` for an actual cifs
   entry**, not `mountpoint -q` (which always returns true for the
   automount filesystem itself). So `smbproxy-sconfig --status`
   honestly reports `active=no` when the cifs mount is not
   established.

## Measured behaviour (proxy CLI)

Probe 192.168.0.105 from the proxy with the device off (same /24,
ARP probe cycle):

| Layer applied | `ls /mnt/device/<share>` |
|---|---|
| baseline (no `x-systemd.mount-timeout`) | 6.2 s per attempt |
| `+ x-systemd.mount-timeout=4`           | 4.1 s per attempt |
| `+ root preexec` short-circuit          | 1.0 s per attempt |

These are server-side per-attempt costs and are concretely measurable
with `time ls /mnt/device/<share>` and the `smbproxy-probe`
journal log (`journalctl -t smbproxy-probe`).

## What's left: the residual ~30 s wait

A Windows client hitting an offline backend currently waits ~30 s in
the Explorer dialog before the error is shown. That is roughly half
the original ~60 s hang and ~3× the per-attempt cost. The reason it
isn't ~1 s:

**`root preexec` failure with `close = yes` returns
`NT_STATUS_ACCESS_DENIED` from Samba.** The error code is hardcoded
in `source3/smbd/smb2_service.c` (`make_connection_snum`) — the
probe's exit code does not influence it. Windows treats
`NT_STATUS_ACCESS_DENIED` as a *transient* condition ("permissions
might come back, retry"), so it loops the tree connect in bursts:
~6 attempts back-to-back, ~20 s pause, another burst, until Windows
itself gives up. The probe makes each individual attempt fast, but
it does not change the burst count or the inter-burst wait.

To get Windows to give up immediately we need it to receive a
*non-retry* error code such as `NT_STATUS_BAD_NETWORK_NAME` ("share
doesn't exist"). Samba does not expose that as a configurable
mapping for preexec failures.

## Deferred design: dynamic `available = no` via systemd timer

The path to "share genuinely doesn't exist while device is off" is to
toggle the Samba `available` parameter based on a periodic
reachability probe.

**Sketch:**

- `smbproxy-share-availability.timer` runs `smbproxy-share-availability.service`
  every ~30 s.
- The service script enumerates `/var/lib/smbproxy/shares/*.env`,
  filters to `PROFILE=modern`, TCP-probes each share's
  `BACKEND_IP:445` with the same 1-second timeout used by
  `smbproxy-probe-backend`.
- For each share:
  - Reachable + `available = no` currently in `smb.conf` → remove the
    line, mark dirty.
  - Unreachable + no `available = no` line currently → insert it,
    mark dirty.
- If dirty, run `smbcontrol smbd reload-config`.
- Optionally also a separate `smbcontrol smbd close-share <name>`
  on transition-to-unavailable so any lingering tree connect on a
  now-unreachable share is dropped (cifs `soft` will already have
  surfaced EIO to clients in practice, so this is belt-and-braces).

**What `reload-config` does and does not do** (this was the question
that made us pause):

- It is *non-disruptive* to active tree connects. Samba evaluates
  `valid users`, `force user`, `available`, etc. only at
  tree-connect time, not on every operation. Existing sessions keep
  working with their tree-connect-time state.
- New tree connects after the reload see the new config — i.e. an
  unavailable share returns `NT_STATUS_BAD_NETWORK_NAME` to the
  client, and Explorer greys it out promptly.
- Legacy shares are untouched; the timer only flips state on shares
  whose `.env` file says `PROFILE=modern`.

**Race window:** with a 30 s probe interval, a client that hits the
share within the 30 s after the device goes off (but before the
timer catches up) gets the current ~30 s preexec/retry experience.
After the timer runs, subsequent attempts are fast. Tightening the
interval (10 s, 5 s) trades probe load for race-window size.

## Why it was deferred

- The improvements already shipped (status bug fix, broken
  `force user`, `x-systemd.mount-timeout=4`, preexec) are the
  high-value, low-complexity bugs and they're durable.
- The dynamic-availability work is a state machine: a new systemd
  unit pair, edits to `smb.conf` from a periodic script, and a
  reload protocol. It is straightforward but it is *new
  infrastructure*, and infrastructure should not be added on the
  day a single share's hang behaviour is being debugged.
- The current 30 s wait is a 50% improvement over the original 60 s
  and is acceptable for the operator's day-to-day flow until the
  full design is built and tested in the lab.

## Where to verify behaviour

```bash
# Per-attempt server cost (offline)
ssh debadmin@smb-proxy 'time ls /mnt/device/<share> 2>/dev/null; true'

# Probe traces from real Windows tree connects
ssh debadmin@smb-proxy 'sudo journalctl -t smbproxy-probe --since "5 min ago"'

# Tree-connect path through Samba (look for "root preexec gave 124"
# when device is off, or normal "signed connect" when device is on)
ssh debadmin@smb-proxy 'sudo tail -200 /var/log/samba/log.smbd | \
  grep -E "make_connection_snum|root preexec|NT_STATUS"'
```
