#!/usr/bin/env bash
# Passwords must never reach a process argument vector (code-review session
# plan 01). The join already feeds kinit through a pipe; domain leave uses
# a root-only authentication file. Backend share credentials live in the
# 0600 creds files and never pass through argv.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCONFIG="$ROOT/smbproxy-sconfig.sh"
T=$(mktemp -d "${TMPDIR:-/tmp}/proxy-secret-free-auth.XXXXXX")
trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }
SECRET='Zq9!marker $(id) `x` "q" back\slash'

leaks=$(grep -nE -- '--(adminpass|password|newpassword)=|-U[[:space:]]*"?[^ ]*%\$' "$ROOT"/smbproxy-sconfig.sh "$ROOT"/smbproxy-* \
    | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#' || true)
[[ -z "$leaks" ]] || fail "password-bearing argument:"$'\n'"$leaks"

eval "$(sed -n '/^run_with_auth_file() {/,/^}$/p' "$SCONFIG")"
mkdir -p "$T/bin" "$T/run"
cat > "$T/bin/net" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$FAKE_ARGV"
for ((i = 1; i <= $#; i++)); do
    if [[ "${!i}" == -A ]]; then j=$((i + 1)); cp "${!j}" "$FAKE_AUTH"; stat -c %a "${!j}" > "$FAKE_MODE"; fi
done
SH
chmod +x "$T/bin/net"
PATH="$T/bin:$PATH" SCONFIG_AUTH_DIR="$T/run" FAKE_ARGV="$T/argv" FAKE_AUTH="$T/auth" FAKE_MODE="$T/mode" \
    run_with_auth_file Administrator "$SECRET" net ads leave
[[ "$(cat "$T/argv")" == "ads leave -A $T/run/"* ]] || fail "unexpected argv: $(cat "$T/argv")"
! grep -qF 'Zq9!marker' "$T/argv" || fail "secret reached net argv"
grep -qxF "password = $SECRET" "$T/auth" || fail "auth file password line wrong"
[[ "$(cat "$T/mode")" == 600 ]] || fail "auth file mode is $(cat "$T/mode"), want 600"
[[ -z "$(ls -A "$T/run")" ]] || fail "auth directory not removed"

grep -q 'run_with_auth_file "$user" "$pass" net ads leave' "$SCONFIG" || fail "domain leave does not use the auth file"

echo "proxy secret-free auth tests passed"
