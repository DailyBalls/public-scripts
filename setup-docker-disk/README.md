# setup-docker-disk.sh

Prepare a **GCP Persistent Disk** as storage for **Docker + containerd** (not only `/var/lib/docker`).

Mounts the disk (via `setup-disk.sh` if needed), then points:

- Docker `data-root` → `<mount>/docker`
- containerd `root` → `<mount>/containerd`

This avoids the common failure where `/var/lib/docker` is on the new disk but image/container layers stay on `/var/lib/containerd` on the root disk.

---

## Usage

```bash
curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/main/setup-docker-disk/setup-docker-disk.sh \
  | sudo bash -s -- <disk> [mount-path]
```

| Argument | Description | Default |
|---|---|---|
| `<disk>` | Block device of the Persistent Disk | required |
| `[mount-path]` | Where to mount the disk | `/mnt/docker-data` |

---

## Examples

**Default mount at `/mnt/docker-data`**

```bash
curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/main/setup-docker-disk/setup-docker-disk.sh \
  | sudo bash -s -- /dev/sdb
```

**Custom mount path**

```bash
curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/main/setup-docker-disk/setup-docker-disk.sh \
  | sudo bash -s -- /dev/sdb /mnt/docker-data
```

---

## What the script does

1. Installs missing tools (`rsync`, `python3`, …) if needed
2. Runs `setup-disk.sh` when the mount path is not already mounted
3. Creates `<mount>/docker` and `<mount>/containerd`
4. Stops Docker / containerd
5. Migrates existing `/var/lib/docker` and `/var/lib/containerd` onto the new disk (renames originals as `.pre-docker-disk-*` backups)
6. Writes `/etc/docker/daemon.json` (`data-root`) and `/etc/containerd/config.toml` (`root`)
7. Adds systemd `RequiresMountsFor=` drop-ins so services wait for the disk
8. Starts containerd and Docker again

---

## Verify

```bash
findmnt /mnt/docker-data
docker info | grep -i 'Docker Root Dir'
df -h /mnt/docker-data/docker /mnt/docker-data/containerd
# After pulling an image, overlay usage should match the new disk size — not /
```

---

## Notes

- Requires root (`sudo`).
- Works before or after Docker is installed (configs are written either way).
- For backups (e.g. Zerobyte), protect **both** `<mount>/docker` and `<mount>/containerd` (or the whole mount).
