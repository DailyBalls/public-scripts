# resize-disk.sh

A script to grow a **GCP Persistent Disk** partition and filesystem on the VM after you increase disk size in Google Cloud — following [Google Cloud’s manual resize steps](https://cloud.google.com/compute/docs/disks/resize-persistent-disk).

Supports **Debian 12**, **Alma Linux**, and other RHEL/Debian derivatives.

---

## Prerequisites

1. **Resize the disk in GCP first** (Console or CLI). This script only expands partitions/filesystems on the VM; it does not change the disk size in Google Cloud.

   ```bash
   gcloud compute disks resize DISK_NAME --size=SIZE_GB --zone=ZONE
   ```

2. SSH into the VM and run this script as root.

> **Note:** Public GCP images often auto-resize the boot disk. Use this script for custom images, non-boot disks, or when `df` / `lsblk` still show unused space after a GCP resize.

---

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/main/resize-disk/resize-disk.sh \
  | sudo bash -s -- [OPTIONS]
```

| Option | Description | Example |
|---|---|---|
| `-d`, `--disk DEVICE` | Whole disk to resize | `/dev/sda`, `/dev/nvme0n1` |
| `-y`, `--yes` | Skip confirmation prompt | — |
| `-h`, `--help` | Show usage | — |

**Disk selection when `-d` is omitted:**

| Situation | Behavior |
|---|---|
| One eligible disk | Selected automatically |
| Multiple disks | Interactive menu (shows total and **unallocated** space per disk) |

---

## Examples

**Auto-detect the only disk (interactive confirm)**

```bash
curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/main/resize-disk/resize-disk.sh \
  | sudo bash -s --
```

**Resize boot disk `/dev/sda` without prompts**

```bash
curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/main/resize-disk/resize-disk.sh \
  | sudo bash -s -- -d /dev/sda -y
```

**Resize an NVMe data disk**

```bash
curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/main/resize-disk/resize-disk.sh \
  | sudo bash -s -- --disk /dev/nvme0n1 -y
```

**Run from a local clone**

```bash
sudo ./resize-disk.sh -d /dev/sdb -y
```

---

## What the script does

1. Lists disks with `df -Th` and `lsblk` (before and after)
2. Picks the target disk (argument, auto-detect, or interactive menu)
3. Warns if the disk uses **MBR (`msdos`)** and is over the 2 TiB GCP limit
4. Grows the root partition on that disk (or the last partition / whole-disk filesystem as needed)
5. Runs **`parted resizepart`** to `100%`, then **`partprobe`** (falls back to `growpart` if needed)
6. Extends **LVM** (`pvresize`, `lvextend`) when the partition is a physical volume
7. Grows the filesystem online:
   - **ext4** → `resize2fs` (no `e2fsck` on mounted volumes)
   - **xfs** → `xfs_growfs -d`
   - **btrfs** → `btrfs filesystem resize max`
8. Prints `df` and remaining unallocated space for verification

> **Note:** Requires root. Run with `sudo` or as the root user. Back up important data (e.g. disk snapshot) before resizing, as recommended by Google Cloud.

---

## Related

- [setup-disk.sh](../setup-disk/README.md) — partition, format, and mount a new Persistent Disk
- [Change the size of a Persistent Disk](https://cloud.google.com/compute/docs/disks/resize-persistent-disk) — official GCP documentation
