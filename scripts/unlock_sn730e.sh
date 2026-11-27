#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: sudo $0 /dev/nvmeX [mode2|mid|high|max]"
  exit 1
fi

DEV="$1"
TIER="${2:-mode2}"

case "$TIER" in
  mode2) P1=0x22; P2=0x18 ;; # Stock SanDisk USB-C 3A (34 / 24)
  mid)   P1=0x40; P2=0x1c ;; # Mid PCIe table tier (64 / 28)
  high)  P1=0x60; P2=0x29 ;; # High PCIe table tier (96 / 41)
  max)   P1=0x80; P2=0x36 ;; # Max WD table tier (128 / 54)
  *)
    echo "Unknown tier: $TIER (expected: mode2, mid, high, max)"
    exit 1
    ;;
esac

MODEL=$(nvme id-ctrl "$DEV" 2>/dev/null | awk -F':' '/^mn[[:space:]]*:/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2}')
if [[ "$MODEL" != *"SN730E"* ]]; then
  echo "Refusing to run: $DEV reports model '$MODEL' (expected SN730E)."
  exit 1
fi

echo "Unlocking $DEV ($MODEL) with tier '$TIER' (param1=$P1, param2=$P2)..."

# Ensure PS0 (6.00W) and Volatile Write Cache are enabled
nvme set-feature "$DEV" -f 0x02 -v 0
nvme set-feature "$DEV" -f 0x06 -v 1

# Send WD vendor-specific NVMe Admin unlock commands (0xFD / 0xFE)
nvme admin-passthru "$DEV" --opcode=0xfd --cdw10=0x01 --cdw11="$P1"
nvme admin-passthru "$DEV" --opcode=0xfe --cdw10=0x01 --cdw11=0x00
nvme admin-passthru "$DEV" --opcode=0xfd --cdw10=0x02 --cdw11="$P2"
nvme admin-passthru "$DEV" --opcode=0xfe --cdw10=0x02 --cdw11=0x00

echo "Done! Current temperature:"
nvme smart-log "$DEV" | grep -i temp || true
