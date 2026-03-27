# setup-disk.sh

A script to partition, format, and persistently mount a **GCP Persistent Disk** on Debian/Ubuntu — with automatic fstab registration and rollback on failure.

---

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/<your-username>/<your-repo>/main/setup-disk.sh \
  | sudo bash -s -- <disk> <mount-path>
```

| Argument | Description | Example |
|---|---|---|
| `<disk>` | Block device path of the Persistent Disk | `/dev/sdb` |
| `<mount-path>` | Directory where the disk will be mounted | `/mnt/data` |

---

## Examples

**Mount `/dev/sdb` at `/mnt/data`**
```bash
curl -fsSL https://raw.githubusercontent.com/<your-username>/<your-repo>/main/setup-disk.sh \
  | sudo bash -s -- /dev/sdb /mnt/data
```

**Mount an NVMe disk at `/mnt/storage`**
```bash
curl -fsSL https://raw.githubusercontent.com/<your-username>/<your-repo>/main/setup-disk.sh \
  | sudo bash -s -- /dev/nvme0n1 /mnt/storage
```

---

## What the script does

1. Verifies the disk exists as a block device
2. Checks if the disk or mount path is already in `/etc/fstab` — skips if so
3. Creates a GPT partition if the disk is empty
4. Formats the partition as `ext4` if no filesystem is present
5. Backs up `/etc/fstab` then adds a `UUID`-based entry with `defaults,nofail`
6. Runs `mount -a` to test — **auto-rolls back fstab if mount fails**

> **Note:** Requires root. Run with `sudo` or as the root user.
