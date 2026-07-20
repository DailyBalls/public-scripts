#!/usr/bin/env bash
# =============================================================================
# setup-docker-disk.sh — Use a GCP Persistent Disk as Docker + containerd storage
# Usage : curl -fsSL <raw-url> | sudo bash -s -- <disk> [mount-path]
# Example: curl -fsSL https://raw.githubusercontent.com/DailyBalls/public-scripts/refs/heads/main/setup-docker-disk/setup-docker-disk.sh \
#            | sudo bash -s -- /dev/sdb /mnt/docker-data
#
# What it does:
#   1. Partitions/formats/mounts the disk via setup-disk.sh (if not already mounted)
#   2. Creates <mount>/docker and <mount>/containerd
#   3. Stops Docker + containerd, migrates existing data if present
#   4. Sets Docker data-root and containerd root to those paths
#   5. Adds systemd RequiresMountsFor so services wait for the disk
#   6. Starts services again (if they were installed/running)
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

DOCKER_DEFAULT_ROOT="/var/lib/docker"
CONTAINERD_DEFAULT_ROOT="/var/lib/containerd"

DOCKER_WAS_ACTIVE=false
CONTAINERD_WAS_ACTIVE=false

# ── root guard ────────────────────────────────────────────────────────────────
[[ $EUID -eq 0 ]] || error "Run as root (or prefix with sudo)."

# ── arguments ─────────────────────────────────────────────────────────────────
[[ $# -ge 1 ]] || error "Usage: $0 <disk> [mount-path]  e.g. $0 /dev/sdb /mnt/docker-data"

DISK="$1"
MOUNT_PATH="${2:-$DEFAULT_MOUNT}"
MOUNT_PATH="${MOUNT_PATH%/}"

DOCKER_DATA_ROOT="${MOUNT_PATH}/docker"
CONTAINERD_ROOT="${MOUNT_PATH}/containerd"

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
    info "Docker / containerd not installed yet — will only write configs and dirs."
  fi
}

restore_docker_stack() {
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

migrate_tree() {
  local src="$1"
  local dst="$2"
  local label="$3"
  local backup

  mkdir -p "$dst"

  if ! dir_has_content "$src"; then
    info "No existing $label data at '$src' — skipping migration."
    return
  fi

  # Already pointing at the new location (bind/same path)
  if [[ "$(realpath -m "$src")" == "$(realpath -m "$dst")" ]]; then
    info "$label source and destination are the same path — nothing to migrate."
    return
  fi

  if dir_has_content "$dst"; then
    warn "Destination '$dst' already has data. Leaving '$src' in place (no overwrite)."
    return
  fi

  info "Migrating $label: '$src' → '$dst'..."
  rsync -aHAX --info=progress2 "$src"/ "$dst"/
  success "$label data copied."

  backup="${src}.pre-docker-disk-$(date -u +%Y%m%d%H%M%S)"
  info "Renaming original '$src' → '$backup'..."
  mv "$src" "$backup"
  mkdir -p "$src"
  success "Original $label data backed up at '$backup'."
  warn "Remove '$backup' after you verify Docker works on the new disk."
}

write_docker_daemon_json() {
  mkdir -p /etc/docker
  python3 - "$DOCKER_DATA_ROOT" <<'PY'
import json, os, sys

data_root = sys.argv[1]
path = "/etc/docker/daemon.json"
data = {}
if os.path.isfile(path):
    with open(path, encoding="utf-8") as f:
        try:
            data = json.load(f) or {}
        except json.JSONDecodeError as e:
            raise SystemExit(f"Invalid JSON in {path}: {e}") from e
    if not isinstance(data, dict):
        raise SystemExit(f"{path} must contain a JSON object")

data["data-root"] = data_root
with open(path, "w", encoding="utf-8") as f:
    json.dump(data, f, indent=2)
    f.write("\n")
print(path)
PY
  success "Docker data-root set to '$DOCKER_DATA_ROOT' in /etc/docker/daemon.json"
}

write_containerd_config() {
  mkdir -p /etc/containerd

  if [[ ! -f /etc/containerd/config.toml ]]; then
    if command -v containerd &>/dev/null; then
      info "Generating default /etc/containerd/config.toml..."
      containerd config default > /etc/containerd/config.toml
    else
      info "containerd not installed — writing minimal config.toml..."
      cat > /etc/containerd/config.toml <<EOF
# Generated by setup-docker-disk.sh
version = 2
root = "${CONTAINERD_ROOT}"
state = "/run/containerd"
EOF
      success "Wrote minimal containerd config (root=${CONTAINERD_ROOT})."
      return
    fi
  fi

  if grep -qE '^[[:space:]]*root[[:space:]]*=' /etc/containerd/config.toml; then
    sed -i -E "s|^[[:space:]]*root[[:space:]]*=.*|root = \"${CONTAINERD_ROOT}\"|" \
      /etc/containerd/config.toml
  else
    # Insert near top after version if present, else prepend
    if grep -qE '^[[:space:]]*version[[:space:]]*=' /etc/containerd/config.toml; then
      sed -i -E "0,/^[[:space:]]*version[[:space:]]*=.*/s||&\nroot = \"${CONTAINERD_ROOT}\"|" \
        /etc/containerd/config.toml
    else
      sed -i "1iroot = \"${CONTAINERD_ROOT}\"" /etc/containerd/config.toml
    fi
  fi
  success "containerd root set to '$CONTAINERD_ROOT' in /etc/containerd/config.toml"
}

write_systemd_mount_deps() {
  local unit dropin
  for unit in docker.service containerd.service; do
    dropin="/etc/systemd/system/${unit}.d/docker-disk.conf"
    mkdir -p "$(dirname "$dropin")"
    cat > "$dropin" <<EOF
# Generated by setup-docker-disk.sh — wait for Docker data disk
[Unit]
RequiresMountsFor=${MOUNT_PATH}
EOF
    success "Wrote $dropin"
  done
  systemctl daemon-reload
}

verify() {
  echo
  info "Verification:"
  findmnt "$MOUNT_PATH" || warn "findmnt failed for $MOUNT_PATH"
  df -h "$MOUNT_PATH" || true

  if command -v docker &>/dev/null && systemctl is-active --quiet docker 2>/dev/null; then
    docker info 2>/dev/null | grep -i 'Docker Root Dir' || true
    local reported
    reported="$(docker info 2>/dev/null | awk -F': ' '/Docker Root Dir/{print $2; exit}')"
    if [[ -n "$reported" ]]; then
      if [[ "$(realpath -m "$reported")" == "$(realpath -m "$DOCKER_DATA_ROOT")" ]]; then
        success "Docker is using '$reported'."
      else
        warn "Docker Root Dir is '$reported' (expected '$DOCKER_DATA_ROOT')."
      fi
    fi
  else
    info "Docker is not running yet — start it after install to use the new paths."
  fi

  if [[ -f /etc/containerd/config.toml ]]; then
    grep -E '^[[:space:]]*root[[:space:]]*=' /etc/containerd/config.toml | head -1 || true
  fi
}

# =============================================================================
echo -e "\n${BOLD}=== Setup Docker Data Disk ===${NC}"
info "Disk              : $DISK"
info "Mount path        : $MOUNT_PATH"
info "Docker data-root  : $DOCKER_DATA_ROOT"
info "containerd root   : $CONTAINERD_ROOT"
echo

ensure_dependencies
echo
ensure_mount
echo

mkdir -p "$DOCKER_DATA_ROOT" "$CONTAINERD_ROOT"
success "Created '$DOCKER_DATA_ROOT' and '$CONTAINERD_ROOT'."

stop_docker_stack
echo

migrate_tree "$DOCKER_DEFAULT_ROOT" "$DOCKER_DATA_ROOT" "Docker"
migrate_tree "$CONTAINERD_DEFAULT_ROOT" "$CONTAINERD_ROOT" "containerd"
echo

write_docker_daemon_json
write_containerd_config
write_systemd_mount_deps
echo

restore_docker_stack
trap - EXIT

verify

echo
echo -e "${BOLD}${GREEN}=== Docker Disk Setup Complete ===${NC}"
echo -e "  Mount      : $MOUNT_PATH"
echo -e "  Docker     : $DOCKER_DATA_ROOT"
echo -e "  containerd : $CONTAINERD_ROOT"
echo -e "  Configs    : /etc/docker/daemon.json , /etc/containerd/config.toml"
echo
warn "Back up both '$DOCKER_DATA_ROOT' and '$CONTAINERD_ROOT' (e.g. with Zerobyte) — not only Docker."
echo
