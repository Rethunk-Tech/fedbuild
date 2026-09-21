#!/usr/bin/env bash
# tests/diff-packages.sh — report drift between blueprint-declared RPMs and
# what's actually installed on a running devbox VM.
#
# Usage:
#   VM_HOST=user@localhost VM_SSH_PORT=2222 SSH_KEY=keys/authorized_key \
#       bash tests/diff-packages.sh
#
# Exits 0 on success (drift reported as warnings, never failure, so this
# target is safe to run in CI as a report). Exits non-zero only on
# connection / parse errors.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

BLUEPRINT="${BLUEPRINT:-$SCRIPT_DIR/../blueprint.toml}"
VM_HOST="${VM_HOST:-user@localhost}"
VM_SSH_PORT="${VM_SSH_PORT:-2222}"
SSH_KEY="${SSH_KEY:-keys/authorized_key}"

log() { echo "[diff-packages] $*"; }

command -v yq >/dev/null || { echo "ERROR: yq required"; exit 1; }
test -f "$BLUEPRINT" || { echo "ERROR: $BLUEPRINT not found"; exit 1; }
test -f "$SSH_KEY"  || { echo "ERROR: $SSH_KEY not found"; exit 1; }

EXPECTED=$(mktemp)
ACTUAL=$(mktemp)
trap 'rm -f "$EXPECTED" "$ACTUAL"' EXIT

log "Reading expected packages from $BLUEPRINT"
yq -p toml -oy '.packages[].name' "$BLUEPRINT" | sort -u > "$EXPECTED"
log "  $(wc -l < "$EXPECTED") packages declared"

log "Querying installed RPMs on $VM_HOST:$VM_SSH_PORT"
ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 \
    -i "$SSH_KEY" -p "$VM_SSH_PORT" "$VM_HOST" \
    "rpm -qa --qf '%{NAME}\n'" | sort -u > "$ACTUAL"
log "  $(wc -l < "$ACTUAL") RPMs installed"

MISSING=$(comm -23 "$EXPECTED" "$ACTUAL" || true)

echo
echo "=== Drift: declared but NOT installed ==="
if [[ -z "$MISSING" ]]; then
    echo "  (none)"
else
    # shellcheck disable=SC2086  # word-splitting intentional: one arg per token
    printf '  - %s\n' $MISSING
fi

echo
echo "=== Summary ==="
echo "  declared  : $(wc -l < "$EXPECTED")"
echo "  installed : $(wc -l < "$ACTUAL")"
echo "  missing   : $(echo -n "$MISSING" | grep -c . || true)"
