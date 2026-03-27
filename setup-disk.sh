#!/usr/bin/env bash
# =============================================================================
# setup-disk.sh — Partition, format, and fstab-mount a GCP Persistent Disk
# Usage : curl -fsSL <raw-url> | sudo bash -s -- <disk> <mount-path>
# Example: curl -fsSL https://raw.githubusercontent.com/.../setup-disk.sh \
#            | sudo bash -s -- /dev/sdb /mnt/data
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

echo -e "\n${BOLD}=== GCP Persistent Disk Setup ===${NC}"
info "Disk       : $DISK"
info "Mount path : $MOUNT_PATH"
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

# Gather UUID of the disk itself (pre-partition) and any partition UUIDs
DISK_UUIDS=$(blkid -s UUID -o value "$DISK"* 2>/dev/null || true)

ALREADY_IN_FSTAB=false

# Check raw device path
if grep -qE "^[[:space:]]*${DISK}[^[:space:]]*[[:space:]]" "$FSTAB" 2>/dev/null; then
  ALREADY_IN_FSTAB=true
fi

# Check by UUID
if [[ -n "$DISK_UUIDS" ]]; then
  while IFS= read -r uuid; do
    if grep -q "$uuid" "$FSTAB" 2>/dev/null; then
      ALREADY_IN_FSTAB=true
      warn "UUID $uuid already present in $FSTAB."
    fi
  done <<< "$DISK_UUIDS"
fi

# Check by mount path
if grep -qE "[[:space:]]${MOUNT_PATH}[[:space:]]" "$FSTAB" 2>/dev/null; then
  ALREADY_IN_FSTAB=true
  warn "Mount path '$MOUNT_PATH' already present in $FSTAB."
fi

if $ALREADY_IN_FSTAB; then
  warn "This disk / mount path is already configured in $FSTAB. Skipping fstab update."
  echo -e "\nCurrent fstab entries for this disk:"
  grep -E "(${DISK}|${MOUNT_PATH})" "$FSTAB" || true

  # Still try to mount if not mounted
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

PARTITION_COUNT=$(lsblk -n -o TYPE "$DISK" 2>/dev/null | grep -c '^part$' || true)
EXISTING_PARTITION=""

if [[ "$PARTITION_COUNT" -gt 0 ]]; then
  # Use first existing partition
  EXISTING_PARTITION=$(lsblk -n -o NAME,TYPE "$DISK" | awk '$2=="part"{print "/dev/"$1; exit}')
  info "Found existing partition: $EXISTING_PARTITION"
else
  info "No partitions found. Will create a new partition."
fi

# ── 4. Create partition if needed ─────────────────────────────────────────────
if [[ -z "$EXISTING_PARTITION" ]]; then
  info "Creating a single primary partition spanning the whole disk..."

  # Wipe any stale signatures first (safe on a fresh PD)
  wipefs -a "$DISK" &>/dev/null || true

  # Create GPT label + one partition
  parted -s "$DISK" mklabel gpt
  parted -s "$DISK" mkpart primary ext4 0% 100%
  partprobe "$DISK"
  sleep 2  # let the kernel re-read

  # Resolve partition name (/dev/sdb1 or /dev/nvme0n1p1, etc.)
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

# ── 7. Create mount point ─────────────────────────────────────────────────────
if [[ ! -d "$MOUNT_PATH" ]]; then
  info "Creating mount directory '$MOUNT_PATH'..."
  mkdir -p "$MOUNT_PATH"
  success "Directory created."
else
  info "Mount directory '$MOUNT_PATH' already exists."
fi

# ── 8. Add to fstab ───────────────────────────────────────────────────────────
FSTAB_ENTRY="UUID=${UUID}  ${MOUNT_PATH}  ext4  defaults,nofail  0  2"

info "Backing up fstab to /etc/fstab.bak..."
cp "$FSTAB" /etc/fstab.bak

info "Adding entry to $FSTAB..."
echo "" >> "$FSTAB"
echo "# Added by setup-disk.sh on $(date -u '+%Y-%m-%d %H:%M UTC') — $DISK" >> "$FSTAB"
echo "$FSTAB_ENTRY" >> "$FSTAB"
success "fstab updated."

echo -e "\nNew fstab entry:\n  ${BOLD}${FSTAB_ENTRY}${NC}\n"

# ── 9. Test fstab mount ───────────────────────────────────────────────────────
info "Testing fstab with 'mount -a'..."

# Run mount -a and capture errors
if MOUNT_ERR=$(mount -a 2>&1); then
  success "'mount -a' completed without errors."
else
  warn "'mount -a' reported issues:\n$MOUNT_ERR"
  warn "Rolling back fstab to backup..."
  cp /etc/fstab.bak "$FSTAB"
  error "fstab test failed — original fstab restored. Fix the issue and re-run."
fi

# Verify the mount point is actually mounted
if mountpoint -q "$MOUNT_PATH"; then
  success "'$MOUNT_PATH' is now mounted."
else
  # Attempt direct mount as a fallback
  warn "'$MOUNT_PATH' not yet mounted — attempting direct mount..."
  if mount "UUID=${UUID}" "$MOUNT_PATH"; then
    success "Mounted '$MOUNT_PATH' successfully."
  else
    warn "Rolling back fstab..."
    cp /etc/fstab.bak "$FSTAB"
    error "Failed to mount '$MOUNT_PATH'. fstab restored."
  fi
fi

# ── 10. Summary ───────────────────────────────────────────────────────────────
echo
echo -e "${BOLD}${GREEN}=== Setup Complete ===${NC}"
echo -e "  Disk      : $DISK"
echo -e "  Partition : $PARTITION"
echo -e "  UUID      : $UUID"
echo -e "  Mounted at: $MOUNT_PATH"
echo -e "  fstab     : $FSTAB_ENTRY"
echo
df -h "$MOUNT_PATH"
echo
