#!/usr/bin/env bash
# tests/compliance.sh — invoke appliance-core's compliance checker
# against this appliance.
#
# Runs from any CWD. Picks the sibling appliance-core checkout (the
# documented layout per dev-commons/REPO-SPLIT.md). Skips with a clear
# message when appliance-core is not checked out next to this repo —
# the checker is a build-time gate, not a runtime dependency.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPDIR="$(cd "$SCRIPT_DIR/.." && pwd)"
CHECKER="$APPDIR/../appliance-core/bin/compliance-check.sh"

if [[ ! -x "$CHECKER" ]]; then
    echo "[compliance] appliance-core/bin/compliance-check.sh not found at:" >&2
    echo "             $CHECKER" >&2
    echo "             Check out appliance-core as a sibling of this repo." >&2
    exit 0
fi

exec "$CHECKER" "$@" "$APPDIR"
