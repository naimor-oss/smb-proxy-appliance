# Offline backend behavior

Offline behavior is selected per share and is separate from the backend
protocol/locking profile:

| Mode | Frontend path | Backend offline |
| --- | --- | --- |
| `direct` | Live cifs backend mount | New connections fail fast |
| `queued` | Local secondary data disk | Share remains available; office changes wait |

Existing share state without `OFFLINE_MODE` migrates to `direct`.
`queued` is allowed only with the `modern` profile. Legacy ISAM shares
must remain direct because replaying cached writes would bypass their
live locking contract.

## Direct mode

Direct mode layers three bounded failure controls:

1. `soft,echo_interval=10` on modern cifs mounts returns an I/O error
   when an established connection dies. Legacy mounts remain hard for
   ISAM write integrity.
2. `x-systemd.mount-timeout=4` caps modern automount attempts.
3. Modern/direct shares use `root preexec = smbproxy-probe-backend`
   for a one-second TCP/445 check at tree-connect time.

The `smbproxy-share-worker.timer` runs every 15 seconds. After two
consecutive failed TCP/445 probes it inserts this managed setting into
the share section and reloads Samba:

```ini
# smbproxy-health: backend unavailable
available = no
```

New tree connects then receive the normal unavailable-share response
instead of Windows repeatedly retrying a failed preexec. A successful
probe removes the managed lines and reloads the configuration.

The worker does not force-close existing Samba sessions. This is
intentional: for a legacy hard-mounted ISAM share, an in-flight write
must either finish when the backend returns or remain blocked. Health
state only controls new tree connects.

Runtime status is written to:

```text
/var/lib/smbproxy/health/<safe-share-name>.env
```

## Queued mode

Queued mode does not switch a Samba share between live and cached
paths. Samba always serves:

```text
/srv/smbproxy-data/shares/<safe-share-name>
```

The worker treats this local copy as the office-authoritative program
set and delivers changes one-way to the machine backend:

- New and changed office files upload when the machine is reachable.
- A file must have the same checksum on two worker passes before
  deployment, so an in-progress office copy is not exposed as a
  partial CNC program.
- Uploads use a temporary file in the destination directory followed
  by an atomic rename.
- The manifest records the local checksum only after a successful
  deployment.
- An unchanged office file is not re-applied. A same-name manual edit
  on the machine therefore survives until the office changes and
  redeploys that source file.
- An office update intentionally overwrites a same-name machine edit.
- An office deletion removes only a backend path previously recorded
  in the manifest.
- A rename uploads the new path before deleting the old managed path.
- Machine-only files, operator nest files, and operator-renamed copies
  are never imported or deleted.

The appliance does not pull an initial copy from the machine. Populate
the published queued share from the office-authoritative source.

Queued data and manifests live on a separately attached ext4 disk:

```text
/srv/smbproxy-data/shares/<safe>/...
/srv/smbproxy-data/state/<safe>/manifest/...
```

Configure it in the TUI under **System Configuration → Offline-share
Data Disk**, or headlessly:

```bash
sudo smbproxy-sconfig --init-data-disk \
  --device /dev/sdX --yes-really-erase
```

The command erases the selected whole disk, formats it as ext4, and
mounts it by UUID. After enlarging the virtual disk in the hypervisor:

```bash
sudo smbproxy-sconfig --grow-data-disk
```

Removing a queued share leaves its local data on the data disk for
manual recovery but deletes its delivery manifest, preventing stale
delete intent from being replayed if the name is later reused.

## Verification

```bash
sudo smbproxy-sconfig --status
sudo smbproxy-sconfig --check-share --name CNC
sudo systemctl status smbproxy-share-worker.timer
sudo journalctl -u smbproxy-share-worker.service

bash tests/unit-helpers.sh
bash tests/share-worker.sh
```
