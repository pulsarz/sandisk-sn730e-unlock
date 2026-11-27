# SanDisk Extreme 4TB (`SN730E`) & ASM2362 Speed Unlock Guide

Technical notes and scripts for fixing the ~140–200 MB/s write bottleneck on **2022 SanDisk Extreme 4TB Portable SSDs** (`SDSSDE61-4T00`, USB ID `0781:55ae`) — both when **shucked into a motherboard M.2 slot** and when **restoring an ASM2362 enclosure** that was flashed with generic ASMedia firmware.

> **Disclaimer:** Use at your own risk. Back up your data before flashing bridge firmware or sending vendor-specific NVMe commands. No proprietary SanDisk/ASMedia firmware binaries are included in this repository.

---

## Hardware Architecture

- **USB-to-NVMe Bridge:** ASMedia `ASM2362` (USB 3.2 Gen 2, 10 Gbps, 8051 MCU + 64 KB SPI NOR flash)
- **Internal M.2 NVMe SSD:** Western Digital `SN730E` 4TB (firmware `11E25100`, PCIe Gen3 x4, DRAM + 3D TLC, OEM sibling of WD Black SN750 / PC SN730)
- **Stock Bridge Firmware:** `181206_81_E3_7F` (SanDisk/WD custom branch with WD SES / Virtual CD / `TWDTCG`)

---

## Root Cause: Why Both Shucking and Generic Bridge Firmware Are Slow

Disassembling the stock SanDisk ASM2362 firmware (`181206_81_E3_7F`) and comparing it against generic ASMedia firmware (`210527_81_00_00`) revealed why the `SN730E` throttles outside its stock shell:

1. **Both firmwares send the exact same standard NVMe `Set Features` (`0x09`) commands** on init (`FID 0x07` Num Queues, `FID 0x08` Int Coalescing, `FID 0x01` Arbitration, `FID 0x06` Volatile Write Cache = 1, `FID 0x02` Power State = PS0).
2. **However, the `SN730E` (`11E25100`) boots into a low-power USB 2.0 throttle (~140–200 MB/s sequential writes)** by default so it won't brown out a 500 mA USB 2.0 port.
3. **Only SanDisk's stock ASM2362 firmware unlocks it:** On boot, `181206_81_E3_7F` loads a power-budget table into XRAM `0x031D` (gated by `0x0BC7`), checks USB speed and USB-C current (`0x90E5`), and sends **two WD vendor-specific NVMe Admin commands** (`0xFD` and `0xFE`) to raise the drive's power/bandwidth budget:

| Mode | Table Bytes (`0x031D`) | `CDW10` (`param1`) | `CDW11` (`param2`) | Meaning |
| :--- | :--- | :---: | :---: | :--- |
| **Mode 0** (USB 2.0) | `00 01 00` / `00 02 00` | `0x01` / `0x02` | `0x00` / `0x00` | Default boot state (~140–200 MB/s writes) |
| **Mode 1** (USB 3.x 1.5A) | `01 01 14` / `01 02 10` | `0x01` / `0x02` | `0x14` (20) / `0x10` (16) | Medium USB 3.x budget |
| **Mode 2** (USB-C 3.0A) | `02 01 22` / `02 02 18` | `0x01` / `0x02` | `0x22` (34) / `0x18` (24) | Full 10 Gbps USB-C speed (~1,050 MB/s) |

The disabled (`0xFF`) entries following Mode 2 in `0x031D` also list higher power-budget tiers scaling up to `0x80` / `0x36` (128 / 54) for full PCIe Gen3 x4 / higher-power operation:

| Tier | `CDW10=0x01` (`CDW11`) | `CDW10=0x02` (`CDW11`) |
| :--- | :---: | :---: |
| `mode2` (stock USB-C 3A) | `0x22` (34) | `0x18` (24) |
| `mid` | `0x40` (64) | `0x1c` (28) |
| `high` | `0x60` (96) | `0x29` (41) |
| `max` (highest table entry) | `0x80` (128) | `0x36` (54) |

---

## Method 1: Unlocking a Shucked `SN730E` in a Motherboard M.2 Slot (Linux)

> **Thermal note:** Use an M.2 heatsink + thermal pad if running above `mode2` — at full 6 W (PS0), the bare `SN730E` will thermally throttle at 84 °C.

Requires `nvme-cli`. Replace `/dev/nvmeX` with your `SN730E` controller (e.g. `/dev/nvme2`):

```bash
# Ensure Power State 0 (6.00W) and Volatile Write Cache are enabled
sudo nvme set-feature /dev/nvmeX -f 0x02 -v 0
sudo nvme set-feature /dev/nvmeX -f 0x06 -v 1

# Unlock (Mode 2: 0x22 / 0x18 — or use 0x80 / 0x36 for max table tier)
sudo nvme admin-passthru /dev/nvmeX --opcode=0xfd --cdw10=0x01 --cdw11=0x22
sudo nvme admin-passthru /dev/nvmeX --opcode=0xfe --cdw10=0x01 --cdw11=0x00
sudo nvme admin-passthru /dev/nvmeX --opcode=0xfd --cdw10=0x02 --cdw11=0x18
sudo nvme admin-passthru /dev/nvmeX --opcode=0xfe --cdw10=0x02 --cdw11=0x00
```

Or use the included helper script (verifies the model is `SN730E` first):

```bash
sudo ./scripts/unlock_sn730e.sh /dev/nvmeX mode2   # or: mid | high | max
```

### Persisting Across Reboots

Because `0xFD`/`0xFE` is volatile (resets on power cycle), install `scripts/unlock_sn730e.sh` to `/usr/local/sbin/unlock_sn730e.sh` and copy `udev/99-wd-sn730e-unlock.rules` to `/etc/udev/rules.d/`.

### Optional: 4K Native LBAs (Wipes Data)

The `SN730E` reports `4096`-byte LBAs as higher relative performance (`Rel_Perf = 1`) than `512`-byte (`Rel_Perf = 2`). On an empty drive:

```bash
sudo nvme format /dev/nvmeXn1 -l 1
```

---

## Method 2: Dumping & Restoring Stock SanDisk ASM2362 Bridge Firmware

If you previously flashed a SanDisk Extreme ASM2362 enclosure with generic ASMedia firmware and still have **one stock enclosure**, you can dump the stock firmware **read-only over USB on Linux** without opening the case.

### 1. Dump from the Stock Enclosure (Linux)

Requires `sg3_utils` (`sg_raw`) and `python3`:

```bash
sudo ./scripts/dump_asm2362.sh /dev/sdX
```

This performs strictly read-only ASMedia vendor SCSI reads:
- `0xE0`: Reads the 128-byte config block (`0x00..0x7F`)
- `0xE2`: Reads the 128 KB SPI flash (`0x0000..0x1FFFF`; firmware uses the first 64 KB)
- `0xE4`: Reads the 6-byte live firmware version from XRAM `0x07F0` (e.g. `181206_81_E3_7F`)
- Strips the 130-byte SPI header (`0x00..0x81`) and trailing `5A <checksum>` footer to produce an **ASMedia MPTool-ready `.bin`** named `AS_PCIE_<VERSION>.bin` (and verifies the 8-bit firmware checksum).

### 2. Flash onto the Slow Enclosure (Windows)

1. Open **ASMedia ASM2360/ASM2362 MPTool** (e.g. `2360MPTool_v1.1.0.29`) **as Administrator**.
2. Click the padlock icon and unlock with password **`asmedia`**.
3. Select the extracted `AS_PCIE_181206_81_E3_7F.bin` file.
4. Set the SanDisk config fields:
   - **VID:** `0781` | **PID:** `55AE`
   - **Vendor:** `SanDisk` | **Product:** `SanDisk Extreme 55AE` | **SCSI Product:** `Extreme 55AE`
5. Click **Start**, wait for **PASS**, then unplug and replug.

### Important Caveat: 256 MB Reserved Area & GPT Partition Tables

SanDisk's stock firmware reserves ~256 MB at the end of the drive for its WD Virtual CD / SES area (`4,000,518,533,120` bytes instead of the full `4,000,787,030,016` bytes exposed by generic firmware).

If a drive was partitioned while running generic firmware and its last partition extends into that final 256 MB, Windows may show it as **"Unallocated"** after restoring SanDisk firmware even though the data is intact. **Do not initialize or format it** if you need the data:
- Temporarily place the internal `SN730E` M.2 drive into a motherboard M.2 slot (or generic USB-NVMe adapter) to expose the full capacity, back up your files (or shrink the last partition by 512 MB), then return it to the SanDisk shell and run `sudo sgdisk -e /dev/sdX` on Linux to update the GPT `LastUsableLBA`.

---

## Verified Before & After Results (CrystalDiskMark 9, 10 Gbps USB-C)

| Benchmark | Before (Generic ASM2362 FW) | After (Restored `181206_81_E3_7F`) | Gain |
| :--- | :---: | :---: | :---: |
| **SEQ1M Q8T1 Read** | 549.10 MB/s | **1,049.04 MB/s** | **1.9×** |
| **SEQ1M Q8T1 Write** | 141.16 MB/s | **1,003.33 MB/s** | **7.1×** |
| **SEQ1M Q1T1 Read** | 318.06 MB/s | **769.31 MB/s** | **2.4×** |
| **SEQ1M Q1T1 Write** | 198.58 MB/s | **815.25 MB/s** | **4.1×** |
