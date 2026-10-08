#!/usr/bin/env bash
# Restore the apt hold marks, helper, and banner snippet saved by install.sh.

set -euo pipefail

BACKUP_DIR="${1:?usage: rollback.sh BACKUP_DIR}"
[[ ${EUID:-$(id -u)} -eq 0 ]] || { echo "run with sudo" >&2; exit 2; }
[[ -r "$BACKUP_DIR/holds-before" ]] || { echo "not a samba-hold backup: $BACKUP_DIR" >&2; exit 2; }

mapfile -t now < <(apt-mark showhold)
mapfile -t added < <(comm -13 <(sort -u "$BACKUP_DIR/holds-before") <(printf '%s\n' "${now[@]}" | sort -u))
[[ ${#added[@]} -eq 0 ]] || apt-mark unhold "${added[@]}" >/dev/null

for name in smbproxy-samba-hold:/usr/local/sbin 17-smbproxy-samba:/etc/update-motd.d; do
    file="${name%%:*}" dir="${name#*:}"
    if [[ -e "$BACKUP_DIR/$file" ]]; then
        cp -a "$BACKUP_DIR/$file" "$dir/$file"
    else
        rm -f "$dir/$file"
    fi
done
echo "Rolled back samba-hold-1.0 from $BACKUP_DIR"
