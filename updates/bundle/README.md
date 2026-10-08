# SMB proxy update bundle

Every change after an image is built ships as one versioned bundle,
built and applied by the appliance-core update framework
(`../appliance-core/docs/lib-update.md`). This directory holds the proxy's
part of it:

| File | Purpose |
| --- | --- |
| `hooks.sh` | detect a pre-framework unit, backup list, preflight, stop/apply/verify/start |
| `ACCEPTS` | starting versions this bundle may be applied to (no wildcard) |
| `migrations/` | `NNN-name.sh`, run once per unit, in order (none yet) |

The version is `../VERSION`. `../updates/build-bundle.sh` builds
`dist/smbproxy-update-<version>.tar.gz` and `.sha256` from the repo's
scripts and the generated scripts in `prepare-image.sh`, so a bundle and an
image built from the same commit install the same files.

## What a bundle changes

- Replaces the appliance scripts in `/usr/local/sbin` and the vendored
  appliance-core libs in `/usr/local/lib/appliance-core`.
- Installs `smbproxy-update` (the built-in updater) and writes
  `/etc/smbproxy.release`.
- Replaces the generated first-boot, init and login-banner scripts only
  where the unit already has them; a script the unit never had is installed
  only if the new scripts require it.
- Never changes Debian packages: Samba stays held and the VFS package is
  untouched (a VFS change ships as its own qualified `.deb`).

## Refusals (nothing is changed)

- The unit's version is unknown, or not listed in `ACCEPTS`, or newer.
- A share, NIC-role or domain state file cannot be read by the strict
  state parser (it is named; re-save it in `smbproxy-sconfig` first).
- The VFS/Samba version guard already fails.

## Applying it

On the first bundle for a unit built before release identity (the
production proxy, `0.4.0-inplace7`):

```bash
sha256sum -c smbproxy-update-0.5.0.tar.gz.sha256
tar -xzf smbproxy-update-0.5.0.tar.gz
sudo ./smbproxy-update-0.5.0/install.sh
```

From then on, and on every image built from 0.5.0 or later:

```bash
sudo smbproxy-update apply smbproxy-update-X.Y.Z.tar.gz   # .sha256 next to it
smbproxy-update status
sudo smbproxy-update rollback                             # newest backup
```

The update prints its backup directory and the exact rollback command.
A failure after the backup restores the unit automatically.

Lab first: apply to a lab proxy built from the same old image (T-UPG-1),
run the scenario suite, roll back and verify again (T-UPG-4), then
production. `tests/root/update-bundle.sh` covers the same paths in a
container against a simulated field unit.
