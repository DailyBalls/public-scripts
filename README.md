# public-scripts

Bash scripts for **GCP Persistent Disk** tasks on Linux VMs (Debian, Ubuntu, Alma Linux).

| Script | Use when |
|---|---|
| [setup-disk](setup-disk/README.md) | Attach a **new** disk — partition, format, mount, and add to `/etc/fstab` |
| [setup-docker-disk](setup-docker-disk/README.md) | Use a **new** disk for Docker **and** containerd via bind mounts to `/var/lib/docker` + `/var/lib/containerd` |
| [resize-disk](resize-disk/README.md) | **Grow** a disk after increasing its size in GCP — extend partition and filesystem |

These scripts are meant to be run on the VM as root (`sudo`).

---

## Quick start

**New data disk → Docker + containerd storage (recommended)**

```bash
curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/main/setup-docker-disk/setup-docker-disk.sh \
  | sudo bash -s -- /dev/sdb /mnt/docker-data
```

**New data disk → generic mount only**

```bash
curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/main/setup-disk/setup-disk.sh \
  | sudo bash -s -- /dev/sdb /mnt/data
```

**Disk already resized in GCP → use all space on the VM**

```bash
# gcloud compute disks resize DISK_NAME --size=SIZE_GB --zone=ZONE
curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/main/resize-disk/resize-disk.sh \
  | sudo bash -s --
```

See each folder’s README for options, examples, and details.
