#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: sudo $0 /dev/sdX [output_dir]"
  exit 1
fi

DEV="$1"
OUTDIR="${2:-.}"
mkdir -p "$OUTDIR"

echo "[1/4] Reading 128-byte ASM2362 config block (0xE0) from $DEV..."
sg_raw -r 128 -o "$OUTDIR/asm2362_config.bin" "$DEV" \
  e0 00 00 00 00 00 00 00 00 00 00 00 00 00 00 00

echo "[2/4] Dumping 128 KB SPI flash (0xE2) from $DEV..."
sg_raw -r 131072 -o "$OUTDIR/asm2362_flash_128k.bin" "$DEV" \
  e2 00 00 02 00 00 00 00 00 00 00 00 00 00 00 00

echo "[3/4] Reading live 6-byte firmware version from XRAM 0x07F0 (0xE4)..."
sg_raw -r 6 -o "$OUTDIR/asm2362_ver.bin" "$DEV" \
  e4 06 00 07 f0 00

echo "[4/4] Verifying checksum and extracting MPTool-ready .bin..."
python3 - "$OUTDIR" <<'PY'
import os, sys

outdir = sys.argv[1]
raw = open(os.path.join(outdir, "asm2362_flash_128k.bin"), "rb").read()
ver = open(os.path.join(outdir, "asm2362_ver.bin"), "rb").read()

fw_len = int.from_bytes(raw[0x80:0x82], "little")
fw_body = raw[0x82 : 0x82 + fw_len]
marker = raw[0x82 + fw_len]
stored_csum = raw[0x82 + fw_len + 1]
calc_csum = sum(fw_body) & 0xFF

ver_str = f"{ver[0]:02X}{ver[1]:02X}{ver[2]:02X}_{ver[3]:02X}_{ver[4]:02X}_{ver[5]:02X}"
print(f"  FW version : {ver_str}")
print(f"  FW length  : {fw_len} bytes (0x{fw_len:04X})")
print(f"  End marker : 0x{marker:02X} (expected 0x5A)")
print(f"  Checksum   : calc=0x{calc_csum:02X}, stored=0x{stored_csum:02X}")

if marker != 0x5A or calc_csum != stored_csum:
    sys.exit("ERROR: Firmware marker/checksum mismatch — do not flash this dump!")

out_bin = os.path.join(outdir, f"AS_PCIE_{ver_str}.bin")
open(out_bin, "wb").write(fw_body)
print(f"  Wrote MPTool image: {out_bin}")
PY
