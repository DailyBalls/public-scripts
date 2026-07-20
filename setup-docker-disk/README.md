# setup-docker-disk.sh

Prepare a **GCP Persistent Disk** as storage for **Docker + containerd**, while keeping the default paths:

- `/var/lib/docker` ← bind mount ← `<mount>/docker`
- `/var/lib/containerd` ← bind mount ← `<mount>/containerd`

No custom `data-root` / containerd `root` required. Docker still “sees” `/var/lib/docker`; the bytes live on the new disk.

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

```bash
curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/main/setup-docker-disk/setup-docker-disk.sh \
  | sudo bash -s -- /dev/sdb /mnt/docker-data
```

---

## What the script does

1. Installs missing tools if needed  
2. Runs `setup-disk.sh` when the mount path is not already mounted  
3. Creates `<mount>/docker` and `<mount>/containerd`  
4. Stops Docker / containerd  
5. Migrates existing `/var/lib/docker` and `/var/lib/containerd` onto the disk (backs up originals as `.pre-docker-disk-*`)  
6. Adds **bind** mounts to `/etc/fstab` and mounts them now  
7. Clears a custom Docker `data-root` / resets containerd `root` to `/var/lib/containerd` if a previous run customized them  
8. Adds systemd `RequiresMountsFor=` so services wait for the binds  
9. Starts Docker again if installed  

---

## Verify

```bash
findmnt /mnt/docker-data /var/lib/docker /var/lib/containerd
docker info | grep -i 'Docker Root Dir'   # expect /var/lib/docker
df -h /var/lib/docker                     # expect the new disk size (e.g. 98G)
```

---

## Notes

- Requires root (`sudo`).
- Works before or after Docker is installed.
- For backups (e.g. Zerobyte), protect `/mnt/docker-data` (covers both Docker and containerd).
- If you already ran an older version that set `data-root` to `/mnt/docker-data/docker`, re-run this script — it switches to bind mounts and restores default paths.
