# Operator SSH public keys baked into the appliance image

`lab/stage-proxy-base.sh` reads every `*.pub` file in this directory at
master-build time, concatenates the keys, and writes them into the
cloud-init seed under `users[debadmin].ssh_authorized_keys`. The
deployed appliance accepts SSH logins from any of those keys (plus
whatever password the operator sets via the console wizard's `[P]`
action in `smbproxy-init`).

## What goes here

One or more standard OpenSSH public-key files:

```text
lab/keys/
├── README.md                    # tracked in git
├── alice.pub                    # gitignored — drop yours here
├── bob.pub                      # gitignored
└── shared-team-deploy-key.pub   # gitignored
```

File naming is just for your own reference. Comment lines (starting
with `#`) and blank lines are stripped before substitution.

## Why a directory, not a single file

The previous design baked in `~/.ssh/id_ed25519.pub` from the build
operator's home directory. That worked for solo development but had
two problems:

1. Cloning the repo onto a different machine to build a new master
   silently picked up *that* machine's key, not the original
   operator's. Easy to ship a master that only the cloning operator
   could log into.
2. Releasing the master image outside the original team baked in the
   builder's pubkey forever — fine for internal use, awkward
   otherwise.

Putting keys in this folder makes the pubkey set explicit per build,
and `.gitignore` keeps the keys out of the repo so a clone always
starts with an empty `lab/keys/` and the builder consciously adds
their own.

## What if I don't add any keys?

`stage-proxy-base.sh` will refuse to build the seed. The deployed
appliance would have no SSH path in — only the `smbproxy-init`
console wizard's `[P]assword` action would work. If that's actually
what you want (console-only deploy), pass `--allow-no-keys` to the
stager.

## How to verify

After running the stager, mount the seed ISO and inspect `user-data`:

```bash
hdiutil attach -nobrowse /Volumes/ISO/<hostname>-seed.iso
grep -A20 ssh_authorized_keys /Volumes/CIDATA/user-data
hdiutil detach /Volumes/CIDATA
```
