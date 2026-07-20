#!/usr/bin/env bash
# =============================================================================
# setup-disk.sh — Partition, format, and fstab-mount a GCP Persistent Disk
# Usage : curl -fsSL <raw-url> | sudo bash -s -- <disk> <mount-path>
# Example: curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/refs/heads/main/setup-disk/setup-disk.sh \
#            | sudo bash -s -- /dev/sdb /mnt/data
#
# New features:
#   • Detects existing data in the target mount path and migrates it
#   • Docker-aware: stops Docker before migrating /var/lib/docker, restores state
#   • Installs missing required tools (parted, rsync, e2fsprogs, …) before proceeding
# =============================================================================
set -euo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

# ── root guard ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "Run as root (or prefix with sudo)."

# ── argument validation ───────────────────────────────────────────────────────
[[ $# -ge 2 ]] || error "Usage: $0 <disk> <mount-path>  e.g. $0 /dev/sdb /mnt/data"

DISK="$1"
MOUNT_PATH="$2"
FSTAB="/etc/fstab"

# Normalise mount path (strip trailing slash) for reliable comparisons
MOUNT_PATH="${MOUNT_PATH%/}"

# ── Install required tools ────────────────────────────────────────────────────
# command → package name (Debian/Ubuntu; RHEL family uses the same names here)
ensure_dependencies() {
  # cmd:pkg pairs — only packages for missing commands are installed
  local -a needed=()
  local cmd pkg

  for pair in \
    "parted:parted" \
    "partprobe:parted" \
    "rsync:rsync" \
    "mkfs.ext4:e2fsprogs" \
    "wipefs:util-linux" \
    "blkid:util-linux" \
    "lsblk:util-linux" \
    "mountpoint:util-linux" \
    "realpath:coreutils" \
    "python3:python3"
  do
    cmd="${pair%%:*}"
    pkg="${pair##*:}"
    if ! command -v "$cmd" &>/dev/null; then
      # Avoid duplicate package names in the install list
      local already=false
      local p
      for p in "${needed[@]+"${needed[@]}"}"; do
        [[ "$p" == "$pkg" ]] && already=true && break
      done
      $already || needed+=("$pkg")
    fi
  done

  if [[ ${#needed[@]} -eq 0 ]]; then
    info "All required tools are already installed."
    return
  fi

  info "Missing tools — installing packages: ${needed[*]}"
  export DEBIAN_FRONTEND=noninteractive

  if command -v apt-get &>/dev/null; then
    apt-get update -qq
    apt-get install -y -qq "${needed[@]}"
  elif command -v dnf &>/dev/null; then
    dnf install -y "${needed[@]}"
  elif command -v yum &>/dev/null; then
    yum install -y "${needed[@]}"
  else
    error "Cannot install packages automatically. Install manually: ${needed[*]}"
  fi

  # Verify critical commands (python3 is optional; used only for daemon.json)
  for cmd in parted partprobe rsync mkfs.ext4 wipefs blkid lsblk mountpoint realpath; do
    command -v "$cmd" &>/dev/null \
      || error "'$cmd' is still missing after package install. Aborting."
  done

  success "Required tools installed."
}

# ── Docker detection helpers ──────────────────────────────────────────────────
DOCKER_DATA_ROOT="/var/lib/docker"   # canonical Docker data root
DOCKER_WAS_RUNNING=false             # track original Docker state

is_docker_path() {
  # Returns 0 (true) if MOUNT_PATH is or is a parent of the Docker data root,
  # or IS the Docker data root itself.
  local canonical_mount
  canonical_mount=$(realpath -m "$MOUNT_PATH" 2>/dev/null || echo "$MOUNT_PATH")
  local canonical_docker
  canonical_docker=$(realpath -m "$DOCKER_DATA_ROOT" 2>/dev/null || echo "$DOCKER_DATA_ROOT")

  # Also honour a custom dockerd --data-root if daemon.json exists
  if command -v docker &>/dev/null && [[ -f /etc/docker/daemon.json ]]; then
    local custom_root
    custom_root=$(python3 -c \
      "import json,sys; d=json.load(open('/etc/docker/daemon.json')); print(d.get('data-root',''))" \
      2>/dev/null || true)
    [[ -n "$custom_root" ]] && canonical_docker=$(realpath -m "$custom_root" 2>/dev/null || echo "$custom_root")
  fi

  [[ "$canonical_mount" == "$canonical_docker" || \
     "$canonical_docker" == "$canonical_mount"/* ]]
}

docker_stop_if_needed() {
  if ! command -v docker &>/dev/null; then return; fi
  if ! is_docker_path; then return; fi

  echo
  warn "Mount path '$MOUNT_PATH' overlaps with the Docker data root."
  warn "Docker must be stopped before data migration to avoid corruption."

  if systemctl is-active --quiet docker 2>/dev/null; then
    DOCKER_WAS_RUNNING=true
    info "Stopping Docker daemon and socket..."
    systemctl stop docker.socket docker 2>/dev/null || systemctl stop docker 2>/dev/null
    success "Docker stopped."
  else
    info "Docker is already stopped."
    DOCKER_WAS_RUNNING=false
  fi
}

docker_restore_if_needed() {
  if ! command -v docker &>/dev/null; then return; fi
  if ! is_docker_path; then return; fi

  if $DOCKER_WAS_RUNNING; then
    info "Restoring Docker to its previous running state..."
    systemctl start docker
    success "Docker restarted."
  else
    info "Docker was not running before; leaving it stopped."
  fi
}

# ── Pre-migration: stop Docker if needed, copy existing data ─────────────────
migrate_existing_data() {
  # Only act when the directory already exists and contains something
  if [[ ! -d "$MOUNT_PATH" ]]; then
    info "Mount path '$MOUNT_PATH' does not exist yet — no migration needed."
    return
  fi

  # Count items (hidden files included), excluding . and ..
  local item_count
  item_count=$(find "$MOUNT_PATH" -maxdepth 1 -mindepth 1 2>/dev/null | wc -l || echo 0)

  if [[ "$item_count" -eq 0 ]]; then
    info "Mount path '$MOUNT_PATH' is empty — no migration needed."
    return
  fi

  echo
  info "Mount path '$MOUNT_PATH' exists and contains $item_count item(s)."
  warn "Existing data will be copied to the new disk before mounting."

  # ── stop Docker if this is a Docker path ──────────────────────────────────
  docker_stop_if_needed

  # ── temporary staging directory for the new disk ──────────────────────────
  local staging
  staging=$(mktemp -d /tmp/new-disk-staging.XXXXXX)
  info "Mounting new partition temporarily at '$staging' for data copy..."

  if ! mount "UUID=${UUID}" "$staging"; then
    rmdir "$staging"
    error "Could not mount new partition at staging path. Aborting migration."
  fi

  # ── rsync with progress ───────────────────────────────────────────────────
  info "Copying data from '$MOUNT_PATH' → new disk (this may take a while)..."
  if rsync -aAX --info=progress2 "$MOUNT_PATH"/ "$staging"/; then
    success "Data copied successfully."
  else
    warn "rsync exited with errors. Unmounting staging and aborting."
    umount "$staging" || true
    rmdir  "$staging" || true
    # Restore Docker even on failure so the system isn't left broken
    docker_restore_if_needed
    error "Data migration failed. Original data is untouched."
  fi

  # ── unmount staging area ──────────────────────────────────────────────────
  umount "$staging"
  rmdir  "$staging"
  success "Staging mount released."

  # ── rename old data as a backup ───────────────────────────────────────────
  local backup_path="${MOUNT_PATH}.pre-migration-$(date -u +%Y%m%d%H%M%S)"
  info "Renaming original data directory to '$backup_path' as a safety backup..."
  mv "$MOUNT_PATH" "$backup_path"
  success "Original data backed up to '$backup_path'."
  warn "You may remove '$backup_path' once you have verified the new mount."
}

# ── Cleanup / rollback trap ───────────────────────────────────────────────────
# If anything fatal happens after Docker was stopped, make sure it comes back.
_emergency_restore() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    warn "Script exited with error ($exit_code). Attempting emergency Docker restore..."
    docker_restore_if_needed || true
  fi
}
trap '_emergency_restore' EXIT

# =============================================================================
echo -e "\n${BOLD}=== GCP Persistent Disk Setup ===${NC}"
info "Disk       : $DISK"
info "Mount path : $MOUNT_PATH"
echo

# ── 0. Ensure required tools are present ──────────────────────────────────────
ensure_dependencies
echo

# ── 1. Check disk exists ──────────────────────────────────────────────────────
info "Checking disk existence..."
if [[ ! -b "$DISK" ]]; then
  error "Block device '$DISK' not found. Available disks:\n$(lsblk -d -o NAME,SIZE,TYPE,MODEL 2>/dev/null || true)"
fi
success "Disk '$DISK' exists."

DISK_INFO=$(lsblk -d -o NAME,SIZE,MODEL "$DISK" 2>/dev/null || true)
info "Disk info:\n$DISK_INFO"

# ── 2. Check if already in fstab (by device path or UUID) ────────────────────
info "Checking fstab for existing entries..."

DISK_UUIDS=$(blkid -s UUID -o value "$DISK"* 2>/dev/null || true)

ALREADY_IN_FSTAB=false

if grep -qE "^[[:space:]]*${DISK}[^[:space:]]*[[:space:]]" "$FSTAB" 2>/dev/null; then
  ALREADY_IN_FSTAB=true
fi

if [[ -n "$DISK_UUIDS" ]]; then
  while IFS= read -r uuid; do
    if grep -q "$uuid" "$FSTAB" 2>/dev/null; then
      ALREADY_IN_FSTAB=true
      warn "UUID $uuid already present in $FSTAB."
    fi
  done <<< "$DISK_UUIDS"
fi

if grep -qE "[[:space:]]${MOUNT_PATH}[[:space:]]" "$FSTAB" 2>/dev/null; then
  ALREADY_IN_FSTAB=true
  warn "Mount path '$MOUNT_PATH' already present in $FSTAB."
fi

if $ALREADY_IN_FSTAB; then
  warn "This disk / mount path is already configured in $FSTAB. Skipping fstab update."
  echo -e "\nCurrent fstab entries for this disk:"
  grep -E "(${DISK}|${MOUNT_PATH})" "$FSTAB" || true

  if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
    success "'$MOUNT_PATH' is already mounted. Nothing to do."
    exit 0
  else
    info "Path not yet mounted — attempting to mount now..."
    mkdir -p "$MOUNT_PATH"
    mount "$MOUNT_PATH" && success "Mounted successfully." || error "Mount failed."
    exit 0
  fi
fi

# ── 3. Determine partition state ──────────────────────────────────────────────
info "Inspecting partition table on '$DISK'..."

# --raw suppresses the Unicode tree-drawing characters (└─ ├─) that lsblk
# emits in its default output and that would otherwise corrupt the device path.
# grep -c prints 0 on no match but exits 1; with pipefail that would abort.
# Use || true — NOT || echo 0 — or stdout becomes "0\n0" and breaks [[ -gt ]].
PARTITION_COUNT=$(lsblk --raw -n -o TYPE "$DISK" 2>/dev/null | grep -c '^part$' || true)
PARTITION_COUNT="${PARTITION_COUNT//$'\n'/}"
PARTITION_COUNT="${PARTITION_COUNT:-0}"
EXISTING_PARTITION=""

if [[ "$PARTITION_COUNT" -gt 0 ]]; then
  EXISTING_PARTITION=$(lsblk --raw -n -o NAME,TYPE "$DISK" \
    | awk '$2=="part"{print "/dev/"$1; exit}')
  # Defensive strip: remove any residual non-ASCII / non-printable bytes that
  # some older lsblk versions still emit even with --raw.
  EXISTING_PARTITION=$(printf '%s' "$EXISTING_PARTITION" | tr -cd '[:print:]')

  # Sanity-check: the resolved path must actually be a block device.
  if [[ -z "$EXISTING_PARTITION" || ! -b "$EXISTING_PARTITION" ]]; then
    warn "lsblk reported a partition but '$EXISTING_PARTITION' is not a valid block device."
    warn "Falling back to kernel sysfs enumeration..."
    # Walk /sys/block/<dev>/*/dev to find partition block devices reliably.
    DISK_BASE=$(basename "$DISK")
    EXISTING_PARTITION=""
    for part_sys in /sys/block/"$DISK_BASE"/"$DISK_BASE"*/; do
      part_dev="/dev/$(basename "$part_sys")"
      if [[ -b "$part_dev" ]]; then
        EXISTING_PARTITION="$part_dev"
        break
      fi
    done
    [[ -n "$EXISTING_PARTITION" ]] \
      || error "Could not resolve an existing partition on '$DISK' via sysfs either."
  fi

  info "Found existing partition: $EXISTING_PARTITION"
else
  info "No partitions found. Will create a new partition."
fi

# ── 4. Create partition if needed ─────────────────────────────────────────────
if [[ -z "$EXISTING_PARTITION" ]]; then
  info "Creating a single primary partition spanning the whole disk..."

  wipefs -a "$DISK" &>/dev/null || true

  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart primary ext4 0% 100%
  partprobe "$DISK"
  sleep 2

  if [[ "$DISK" =~ nvme ]]; then
    PARTITION="${DISK}p1"
  else
    PARTITION="${DISK}1"
  fi

  [[ -b "$PARTITION" ]] || error "Partition '$PARTITION' not found after creation."
  success "Partition created: $PARTITION"
else
  PARTITION="$EXISTING_PARTITION"
fi

# ── 5. Format if no filesystem present ───────────────────────────────────────
EXISTING_FS=$(blkid -s TYPE -o value "$PARTITION" 2>/dev/null || true)

if [[ -z "$EXISTING_FS" ]]; then
  info "No filesystem detected — formatting '$PARTITION' as ext4..."
  mkfs.ext4 -F -L "persistent-disk" "$PARTITION"
  success "Formatted '$PARTITION' as ext4."
else
  info "Existing filesystem on '$PARTITION': $EXISTING_FS (skipping format)."
fi

# ── 6. Get UUID ───────────────────────────────────────────────────────────────
UUID=$(blkid -s UUID -o value "$PARTITION")
[[ -n "$UUID" ]] || error "Could not determine UUID for '$PARTITION'."
success "UUID: $UUID"

# ── 7. Migrate existing data (if any) ────────────────────────────────────────
# Must run BEFORE we create the mount point and bind the new disk there.
# UUID is now known, so the helper can use it for the staging mount.
migrate_existing_data

# ── 8. Create mount point ─────────────────────────────────────────────────────
# After migration, the original directory was renamed, so recreate it cleanly.
if [[ ! -d "$MOUNT_PATH" ]]; then
  info "Creating mount directory '$MOUNT_PATH'..."
  mkdir -p "$MOUNT_PATH"
  success "Directory created."
else
  info "Mount directory '$MOUNT_PATH' already exists (empty after migration)."
fi

# ── 9. Add to fstab ───────────────────────────────────────────────────────────
FSTAB_ENTRY="UUID=${UUID}  ${MOUNT_PATH}  ext4  defaults,nofail  0  2"

info "Backing up fstab to /etc/fstab.bak..."
cp "$FSTAB" /etc/fstab.bak

info "Adding entry to $FSTAB..."
echo "" >> "$FSTAB"
echo "# Added by setup-disk.sh on $(date -u '+%Y-%m-%d %H:%M UTC') — $DISK" >> "$FSTAB"
echo "$FSTAB_ENTRY" >> "$FSTAB"
success "fstab updated."

echo -e "\nNew fstab entry:\n  ${BOLD}${FSTAB_ENTRY}${NC}\n"

# ── 10. Test fstab mount ──────────────────────────────────────────────────────
info "Testing fstab with 'mount -a'..."

if MOUNT_ERR=$(mount -a 2>&1); then
  success "'mount -a' completed without errors."
else
  warn "'mount -a' reported issues:\n$MOUNT_ERR"
  warn "Rolling back fstab to backup..."
  cp /etc/fstab.bak "$FSTAB"
  docker_restore_if_needed
  error "fstab test failed — original fstab restored. Fix the issue and re-run."
fi

# Verify the mount point is actually mounted
if mountpoint -q "$MOUNT_PATH"; then
  success "'$MOUNT_PATH' is now mounted."
else
  warn "'$MOUNT_PATH' not yet mounted — attempting direct mount..."
  if mount "UUID=${UUID}" "$MOUNT_PATH"; then
    success "Mounted '$MOUNT_PATH' successfully."
  else
    warn "Rolling back fstab..."
    cp /etc/fstab.bak "$FSTAB"
    docker_restore_if_needed
    error "Failed to mount '$MOUNT_PATH'. fstab restored."
  fi
fi

# ── 11. Restore Docker to original state ─────────────────────────────────────
docker_restore_if_needed

# Disable the trap's emergency handler now that we've restored cleanly
trap - EXIT

# ── 12. Summary ───────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}=== Setup Complete ===${NC}"
echo -e "  Disk      : $DISK"
echo -e "  Partition : $PARTITION"
echo -e "  UUID      : $UUID"
echo -e "  Mounted at: $MOUNT_PATH"
echo -e "  fstab     : $FSTAB_ENTRY"
if $DOCKER_WAS_RUNNING; then
  echo -e "  Docker    : ${GREEN}restarted${NC} (was running before migration)"
fi
echo
df -h "$MOUNT_PATH"
echo
