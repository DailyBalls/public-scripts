#!/usr/bin/env bash
# =============================================================================
# setup-docker-disk.sh — Use a GCP Persistent Disk as Docker + containerd storage
# Usage : curl -fsSL <raw-url> | sudo bash -s -- <disk> [mount-path]
# Example: curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/refs/heads/main/setup-docker-disk/setup-docker-disk.sh \
#            | sudo bash -s -- /dev/sdb /mnt/docker-data
#
# Layout (canonical Docker paths, data on the new disk):
#   <mount>/docker      → bind-mounted to /var/lib/docker
#   <mount>/containerd  → bind-mounted to /var/lib/containerd
#
# What it does:
#   1. Partitions/formats/mounts the disk via setup-disk.sh (if not already mounted)
#   2. Creates <mount>/docker and <mount>/containerd
#   3. Stops Docker + containerd, migrates existing /var/lib data onto the disk
#   4. Bind-mounts those dirs to /var/lib/docker and /var/lib/containerd (fstab)
#   5. Keeps default Docker/containerd paths (clears custom data-root/root if set)
#   6. Adds systemd RequiresMountsFor so services wait for the binds
#   7. Starts services again (if Docker is installed)
# =============================================================================
set -euo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

info()    { echo -e "${CYAN}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

SETUP_DISK_RAW_URL="https://raw.githubusercontent.com/DailyBalls/public-scripts/refs/heads/main/setup-disk/setup-disk.sh"
DEFAULT_MOUNT="/mnt/docker-data"
FSTAB="/etc/fstab"

DOCKER_LIB="/var/lib/docker"
CONTAINERD_LIB="/var/lib/containerd"

DOCKER_WAS_ACTIVE=false
CONTAINERD_WAS_ACTIVE=false

# ── root guard ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "Run as root (or prefix with sudo)."

# ── arguments ─────────────────────────────────────────────────────────────────
[[ $# -ge 1 ]] || error "Usage: $0 <disk> [mount-path]  e.g. $0 /dev/sdb /mnt/docker-data"

DISK="$1"
MOUNT_PATH="${2:-$DEFAULT_MOUNT}"
MOUNT_PATH="${MOUNT_PATH%/}"

DISK_DOCKER="${MOUNT_PATH}/docker"
DISK_CONTAINERD="${MOUNT_PATH}/containerd"

# ── helpers ───────────────────────────────────────────────────────────────────
ensure_dependencies() {
  local -a needed=()
  local cmd pkg pair already p

  for pair in "rsync:rsync" "python3:python3" "realpath:coreutils" "mountpoint:util-linux"; do
    cmd="${pair%%:*}"
    pkg="${pair##*:}"
    if ! command -v "$cmd" &>/dev/null; then
      already=false
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

  for cmd in rsync python3 realpath mountpoint; do
    command -v "$cmd" &>/dev/null || error "'$cmd' is still missing after package install."
  done
  success "Required tools installed."
}

run_setup_disk() {
  local local_script="" script_dir

  if [[ -n "${BASH_SOURCE[0]:-}" && -f "${BASH_SOURCE[0]}" ]]; then
    script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${script_dir}/../setup-disk/setup-disk.sh" ]]; then
      local_script="${script_dir}/../setup-disk/setup-disk.sh"
    fi
  fi

  if [[ -n "$local_script" ]]; then
    info "Running local setup-disk.sh to prepare '$DISK' → '$MOUNT_PATH'..."
    bash "$local_script" "$DISK" "$MOUNT_PATH"
  else
    info "Fetching setup-disk.sh to prepare '$DISK' → '$MOUNT_PATH'..."
    curl -fsSL "$SETUP_DISK_RAW_URL" | bash -s -- "$DISK" "$MOUNT_PATH"
  fi
}

ensure_mount() {
  if mountpoint -q "$MOUNT_PATH" 2>/dev/null; then
    success "'$MOUNT_PATH' is already mounted."
    return
  fi
  info "'$MOUNT_PATH' is not mounted — preparing disk with setup-disk.sh..."
  run_setup_disk
  mountpoint -q "$MOUNT_PATH" 2>/dev/null \
    || error "'$MOUNT_PATH' is still not a mount point after setup-disk."
}

stop_docker_stack() {
  DOCKER_WAS_ACTIVE=false
  CONTAINERD_WAS_ACTIVE=false

  if systemctl is-active --quiet docker 2>/dev/null; then
    DOCKER_WAS_ACTIVE=true
  fi
  if systemctl is-active --quiet containerd 2>/dev/null; then
    CONTAINERD_WAS_ACTIVE=true
  fi

  if $DOCKER_WAS_ACTIVE || $CONTAINERD_WAS_ACTIVE \
     || command -v docker &>/dev/null \
     || command -v containerd &>/dev/null; then
    info "Stopping Docker / containerd for safe migration..."
    systemctl stop docker.socket docker 2>/dev/null || true
    systemctl stop containerd 2>/dev/null || true
    success "Docker stack stopped (or was not running)."
  else
    info "Docker / containerd not installed yet — preparing bind mounts only."
  fi
}

restore_docker_stack() {
  if $DOCKER_WAS_ACTIVE || command -v docker &>/dev/null; then
    if command -v containerd &>/dev/null; then
      info "Starting containerd..."
      systemctl start containerd
      success "containerd started."
    fi
    if command -v docker &>/dev/null; then
      info "Starting Docker..."
      systemctl start docker
      success "Docker started."
    fi
  elif $CONTAINERD_WAS_ACTIVE; then
    info "Starting containerd..."
    systemctl start containerd
    success "containerd started."
  else
    info "Docker is not installed yet — services left stopped. Bind mounts are ready."
  fi
}

_emergency_restore() {
  local exit_code=$?
  if [[ $exit_code -ne 0 ]]; then
    warn "Script failed ($exit_code). Attempting to restart Docker stack..."
    restore_docker_stack || true
  fi
}
trap '_emergency_restore' EXIT

dir_has_content() {
  local dir="$1"
  [[ -d "$dir" ]] || return 1
  [[ "$(find "$dir" -mindepth 1 -maxdepth 1 2>/dev/null | wc -l)" -gt 0 ]]
}

# True if $1 is already bound to the same inode as $2
is_bound_to() {
  local target="$1"
  local source="$2"
  mountpoint -q "$target" 2>/dev/null || return 1
  [[ -d "$source" && -d "$target" ]] || return 1
  local s_ino t_ino
  s_ino=$(stat -c '%d:%i' "$source" 2>/dev/null || true)
  t_ino=$(stat -c '%d:%i' "$target" 2>/dev/null || true)
  [[ -n "$s_ino" && "$s_ino" == "$t_ino" ]]
}

migrate_lib_to_disk() {
  local lib_path="$1"   # e.g. /var/lib/docker
  local disk_path="$2"  # e.g. /mnt/docker-data/docker
  local label="$3"
  local backup

  mkdir -p "$disk_path"

  # Already bind-mounted correctly
  if is_bound_to "$lib_path" "$disk_path"; then
    success "$label: '$lib_path' already bound to disk data."
    return
  fi

  # If lib path is a mount of something else, unmount first (safe only when stack stopped)
  if mountpoint -q "$lib_path" 2>/dev/null; then
    warn "'$lib_path' is a mount point — unmounting before rebinding..."
    umount "$lib_path" || error "Could not unmount '$lib_path'."
  fi

  if dir_has_content "$lib_path"; then
    if dir_has_content "$disk_path"; then
      warn "$label: both '$lib_path' and '$disk_path' have data."
      warn "Keeping disk copy; backing up lib path without merging."
    else
      info "Migrating $label: '$lib_path' → '$disk_path'..."
      rsync -aHAX --info=progress2 "$lib_path"/ "$disk_path"/
      success "$label data copied to disk."
    fi
    backup="${lib_path}.pre-docker-disk-$(date -u +%Y%m%d%H%M%S)"
    info "Renaming original '$lib_path' → '$backup'..."
    mv "$lib_path" "$backup"
    success "Original backed up at '$backup'."
    warn "Remove '$backup' after you verify Docker works."
  fi

  mkdir -p "$lib_path"
}

ensure_fstab_bind() {
  local source="$1"
  local target="$2"
  local comment="# Added by setup-docker-disk.sh — bind $target → $source"

  # Match existing entry for this target
  if grep -qE "^[^#]*[[:space:]]${target}[[:space:]]" "$FSTAB" 2>/dev/null; then
    if grep -qE "^[^#]*${source}[[:space:]]+${target}[[:space:]]" "$FSTAB" 2>/dev/null; then
      info "fstab already has bind for '$target'."
      return
    fi
    warn "fstab already references '$target' with a different source — leaving it unchanged."
    warn "Expected: $source  $target  none  bind,nofail,x-systemd.requires-mounts-for=${MOUNT_PATH}  0  0"
    return
  fi

  info "Adding fstab bind: $source → $target"
  cp "$FSTAB" /etc/fstab.bak.docker-disk
  {
    echo ""
    echo "$comment"
    echo "$source  $target  none  bind,nofail,x-systemd.requires-mounts-for=${MOUNT_PATH}  0  0"
  } >> "$FSTAB"
  success "fstab updated for '$target'."
}

bind_mount_now() {
  local source="$1"
  local target="$2"

  mkdir -p "$source" "$target"

  if is_bound_to "$target" "$source"; then
    success "'$target' already mounted from disk."
    return
  fi

  if mountpoint -q "$target" 2>/dev/null; then
    error "'$target' is mounted from something else. Unmount it and re-run."
  fi

  info "Bind-mounting '$source' → '$target'..."
  mount --bind "$source" "$target"
  success "Mounted '$target'."
}

# Prefer default paths: undo prior setup-docker-disk data-root / containerd root customizations
restore_default_docker_paths() {
  if [[ -f /etc/docker/daemon.json ]]; then
    info "Ensuring Docker uses default data-root (/var/lib/docker)..."
    python3 - <<'PY'
import json, os
path = "/etc/docker/daemon.json"
if not os.path.isfile(path):
    raise SystemExit(0)
with open(path, encoding="utf-8") as f:
    try:
        data = json.load(f) or {}
    except json.JSONDecodeError as e:
        raise SystemExit(f"Invalid JSON in {path}: {e}") from e
if not isinstance(data, dict):
    raise SystemExit(f"{path} must contain a JSON object")
if "data-root" in data:
    del data["data-root"]
    with open(path, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2)
        f.write("\n")
    print("removed data-root")
else:
    print("data-root already absent")
PY
    success "Docker will use /var/lib/docker (via bind mount)."
  fi

  if [[ -f /etc/containerd/config.toml ]]; then
    if grep -qE '^[[:space:]]*root[[:space:]]*=' /etc/containerd/config.toml; then
      sed -i -E 's|^[[:space:]]*root[[:space:]]*=.*|root = "/var/lib/containerd"|' \
        /etc/containerd/config.toml
      success "containerd root set to /var/lib/containerd (via bind mount)."
    fi
  fi
}

write_systemd_mount_deps() {
  local unit dropin
  for unit in docker.service containerd.service; do
    dropin="/etc/systemd/system/${unit}.d/docker-disk.conf"
    mkdir -p "$(dirname "$dropin")"
    cat > "$dropin" <<EOF
# Generated by setup-docker-disk.sh — wait for bind mounts on the data disk
[Unit]
RequiresMountsFor=${MOUNT_PATH} ${DOCKER_LIB} ${CONTAINERD_LIB}
EOF
    success "Wrote $dropin"
  done
  systemctl daemon-reload
}

verify() {
  echo
  info "Verification:"
  findmnt "$MOUNT_PATH" || warn "findmnt failed for $MOUNT_PATH"
  findmnt "$DOCKER_LIB" || warn "'$DOCKER_LIB' is not mounted"
  findmnt "$CONTAINERD_LIB" || warn "'$CONTAINERD_LIB' is not mounted"
  df -h "$DOCKER_LIB" "$CONTAINERD_LIB" 2>/dev/null || df -h "$MOUNT_PATH" || true

  if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
    docker info 2>/dev/null | grep -i 'Docker Root Dir' || true
    local reported
    reported="$(docker info 2>/dev/null | awk -F': ' '/Docker Root Dir/{print $2; exit}')"
    if [[ -n "$reported" ]]; then
      if [[ "$(realpath -m "$reported")" == "$(realpath -m "$DOCKER_LIB")" ]]; then
        success "Docker Root Dir is '$reported' (on the data disk via bind)."
      else
        warn "Docker Root Dir is '$reported' (expected '$DOCKER_LIB')."
      fi
    fi
  elif command -v docker &>/dev/null; then
    info "Docker is installed but not running. Start with: systemctl start containerd docker"
  else
    info "Docker is not installed yet — that is OK."
    info "Install Docker next; it will use $DOCKER_LIB and $CONTAINERD_LIB (on the new disk)."
  fi
}

# =============================================================================
echo -e "\n${BOLD}=== Setup Docker Data Disk ===${NC}"
info "Disk           : $DISK"
info "Mount path     : $MOUNT_PATH"
info "On-disk Docker : $DISK_DOCKER  →  bind $DOCKER_LIB"
info "On-disk ctrd   : $DISK_CONTAINERD  →  bind $CONTAINERD_LIB"
echo

ensure_dependencies
echo
ensure_mount
echo

mkdir -p "$DISK_DOCKER" "$DISK_CONTAINERD" "$DOCKER_LIB" "$CONTAINERD_LIB"
success "Created on-disk dirs and bind targets:"
info "  $DISK_DOCKER → $DOCKER_LIB"
info "  $DISK_CONTAINERD → $CONTAINERD_LIB"

stop_docker_stack
echo

migrate_lib_to_disk "$DOCKER_LIB" "$DISK_DOCKER" "Docker"
migrate_lib_to_disk "$CONTAINERD_LIB" "$DISK_CONTAINERD" "containerd"
echo

# Mount first so paths exist and work; only then persist in fstab
bind_mount_now "$DISK_DOCKER" "$DOCKER_LIB"
bind_mount_now "$DISK_CONTAINERD" "$CONTAINERD_LIB"
ensure_fstab_bind "$DISK_DOCKER" "$DOCKER_LIB"
ensure_fstab_bind "$DISK_CONTAINERD" "$CONTAINERD_LIB"
echo

restore_default_docker_paths
write_systemd_mount_deps
echo

restore_docker_stack
trap - EXIT

verify

echo
echo -e "${BOLD}${GREEN}=== Docker Disk Setup Complete ===${NC}"
echo -e "  Data disk     : $MOUNT_PATH  (${DISK})"
echo -e "  $DOCKER_LIB     ← bind → $DISK_DOCKER"
echo -e "  $CONTAINERD_LIB ← bind → $DISK_CONTAINERD"
echo
info "Docker still uses the default paths; data lives on the new disk."
if ! command -v docker &>/dev/null; then
  info "Next: install Docker, then verify with:"
  echo "  findmnt $DOCKER_LIB $CONTAINERD_LIB"
  echo "  docker info | grep -i 'Docker Root Dir'"
  echo "  df -h $DOCKER_LIB"
fi
warn "For backups (Zerobyte), protect '$MOUNT_PATH' (covers both Docker and containerd)."
echo
