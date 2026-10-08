#!/usr/bin/env bash
# Behavioral test for smbproxy-samba-hold with fake dpkg-query/apt-mark.
# The real-package behavior (full-upgrade keeps Samba and the module) was
# verified on Debian 13; this keeps the selection and check logic in CI.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOLD="$ROOT/smbproxy-samba-hold"
T=$(mktemp -d "${TMPDIR:-/tmp}/smbproxy-samba-hold-test.XXXXXX")
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"

# Installed packages: name<TAB>source<TAB>status. libldb2 comes from the
# samba source; cifs-utils does not; samba-dev is removed (rc) and ignored.
printf '%s\n' \
    $'samba\tsamba\tii ' \
    $'samba-libs:amd64\tsamba\tii ' \
    $'libldb2:amd64\tsamba\tii ' \
    $'winbind\tsamba\tii ' \
    $'samba-dev\tsamba\trc ' \
    $'cifs-utils\tcifs-utils\tii ' > "$T/installed"
: > "$T/holds"

cat > "$T/bin/dpkg-query" <<FAKE
#!/usr/bin/env bash
case "\$*" in
    *'\${Version}'*samba) printf '2:4.22.10+dfsg-0+deb13u2' ;;
    *) cat "$T/installed" ;;
esac
FAKE
cat > "$T/bin/apt-mark" <<FAKE
#!/usr/bin/env bash
cmd=\$1; shift
case "\$cmd" in
    showhold) cat "$T/holds" ;;
    hold)   printf '%s\n' "\$@" >> "$T/holds"; sort -u -o "$T/holds" "$T/holds" ;;
    unhold) for p in "\$@"; do grep -vxF "\$p" "$T/holds" > "$T/h" || true; mv "$T/h" "$T/holds"; done ;;
esac
FAKE
chmod +x "$T/bin/"*

export SMBPROXY_ALLOW_NON_ROOT_TEST=1
export SMBPROXY_DPKG_QUERY_BIN="$T/bin/dpkg-query"
export SMBPROXY_APT_MARK_BIN="$T/bin/apt-mark"

fail() { echo "FAIL: $*" >&2; exit 1; }

"$HOLD" check 2>/dev/null && fail "check passed with nothing held"
"$HOLD" status | grep -q 'NOT held' || fail "status did not report unheld"

"$HOLD" apply | grep -qF 'held at 2:4.22.10+dfsg-0+deb13u2' || fail "apply output"
expected=$'libldb2\nsamba\nsamba-libs\nwinbind'
[[ "$(cat "$T/holds")" == "$expected" ]] || fail "held set: $(tr '\n' ' ' < "$T/holds")"
"$HOLD" check || fail "check after apply"
"$HOLD" status | grep -q 'held to match' || fail "status after apply"

# A samba-source package installed later (e.g. python3-samba) must be
# reported until the hold is re-applied.
printf '%s\n' $'python3-samba\tsamba\tii ' >> "$T/installed"
"$HOLD" check 2>"$T/err" && fail "check missed a new samba package"
grep -q 'python3-samba' "$T/err" || fail "check did not name the unheld package"
"$HOLD" apply >/dev/null && "$HOLD" check || fail "re-apply"

# Holds the operator set on unrelated packages survive release.
echo cifs-utils >> "$T/holds"
"$HOLD" release >/dev/null
[[ "$(cat "$T/holds")" == "cifs-utils" ]] || fail "release touched unrelated holds"

# Overrides are ignored outside test mode, so a root caller cannot be
# pointed at a substitute binary through the environment.
grep -q 'APT_MARK_BIN=apt-mark$' "$HOLD" || fail "production apt-mark path not fixed"

# The field bundle carries the same banner snippet that new images get.
snippet=$(awk '/^cat > \/etc\/update-motd.d\/17-smbproxy-samba <</ {on=1; next}
               on && /^MOTDEOF$/ {exit} on {print}' "$ROOT/prepare-image.sh")
[[ -n "$snippet" ]] || fail "banner snippet missing from prepare-image.sh"
grep -q 'smbproxy-samba-hold apply' "$ROOT/prepare-image.sh" || fail "image does not apply the hold"
grep -q 'SAMBA_HOLD_HELPER" apply' "$ROOT/smbproxy-sconfig.sh" || fail "sconfig update path does not apply the hold"

echo "samba hold tests passed"
