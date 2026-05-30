# public-scripts

Bash scripts for **GCP Persistent Disk** tasks on Linux VMs (Debian, Ubuntu, Alma Linux).

| Script | Use when |
|---|---|
| [setup-disk](setup-disk/README.md) | Attach a **new** disk — partition, format, mount, and add to `/etc/fstab` |
| [resize-disk](resize-disk/README.md) | **Grow** a disk after increasing its size in GCP — extend partition and filesystem |

Both scripts are meant to be run on the VM as root (`sudo`).

---

## Quick start

**New data disk → mount at `/mnt/data`**

```bash
curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/main/setup-disk/setup-disk.sh \
  | sudo bash -s -- /dev/sdb /mnt/data
```

**Disk already resized in GCP → use all space on the VM**

```bash
# gcloud compute disks resize DISK_NAME --size=SIZE_GB --zone=ZONE
curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/main/resize-disk/resize-disk.sh \
  | sudo bash -s -- -d /dev/sda -y
```

See each folder’s README for options, examples, and details.
