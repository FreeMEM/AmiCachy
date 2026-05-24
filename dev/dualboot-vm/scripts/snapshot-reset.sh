#!/usr/bin/env bash
# Clean up overlay qcow2 files and per-run OVMF VARS from previous test runs.
#
# By default, lists what would be removed and asks for confirmation.
# Use --yes to skip the prompt (CI mode).
# Use --older-than DAYS to only remove items older than N days.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DUALBOOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
OVERLAYS_DIR="$DUALBOOT_DIR/overlays"
LOGS_DIR="$DUALBOOT_DIR/logs"
OVMF_DIR="$DUALBOOT_DIR/ovmf"

YES=0
OLDER_THAN_DAYS=""
KEEP_LOGS=0

usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Removes overlay qcow2, per-run OVMF VARS, and (optionally) logs from previous
test runs. Baselines are never touched.

Options:
  --yes                 Skip confirmation prompt
  --older-than DAYS     Only delete files older than N days
  --keep-logs           Don't delete logs/*.log (default: delete them too)

Examples:
  $0                          # Interactive cleanup of everything
  $0 --yes --older-than 7     # CI: delete artifacts older than a week
EOF
    exit 1
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --yes)         YES=1; shift ;;
        --older-than)  OLDER_THAN_DAYS="$2"; shift 2 ;;
        --keep-logs)   KEEP_LOGS=1; shift ;;
        -h|--help)     usage ;;
        *)             echo "Unknown option: $1" >&2; usage ;;
    esac
done

# Build find expressions
FIND_AGE=()
if [[ -n "$OLDER_THAN_DAYS" ]]; then
    FIND_AGE=(-mtime "+${OLDER_THAN_DAYS}")
fi

# Collect candidates
declare -a CANDIDATES=()
while IFS= read -r f; do CANDIDATES+=("$f"); done < <(
    find "$OVERLAYS_DIR" -maxdepth 1 -name '*.qcow2' "${FIND_AGE[@]}" 2>/dev/null || true
)
while IFS= read -r f; do CANDIDATES+=("$f"); done < <(
    find "$OVMF_DIR" -maxdepth 1 -name 'OVMF_VARS-run-*.4m.fd' "${FIND_AGE[@]}" 2>/dev/null || true
)
if [[ $KEEP_LOGS -eq 0 ]]; then
    while IFS= read -r f; do CANDIDATES+=("$f"); done < <(
        find "$LOGS_DIR" -maxdepth 1 \( -name '*.log' -o -name '*.serial' -o -name '*.monitor' -o -name '*.sock' \) "${FIND_AGE[@]}" 2>/dev/null || true
    )
fi

if [[ ${#CANDIDATES[@]} -eq 0 ]]; then
    echo ">>> Nothing to clean up."
    exit 0
fi

echo ">>> Files to delete:"
TOTAL_BYTES=0
for f in "${CANDIDATES[@]}"; do
    if [[ -f "$f" ]]; then
        sz="$(stat -c%s "$f")"
        TOTAL_BYTES=$((TOTAL_BYTES + sz))
        printf "    %s (%s)\n" "$f" "$(numfmt --to=iec --suffix=B "$sz" 2>/dev/null || echo "${sz}B")"
    fi
done
printf ">>> Total: %s\n" "$(numfmt --to=iec --suffix=B "$TOTAL_BYTES" 2>/dev/null || echo "${TOTAL_BYTES}B")"

if [[ $YES -ne 1 ]]; then
    read -rp ">>> Proceed? [y/N] " ans
    [[ "$ans" =~ ^[Yy]$ ]] || { echo "Aborted."; exit 0; }
fi

for f in "${CANDIDATES[@]}"; do
    rm -f "$f"
done
echo ">>> Done."
