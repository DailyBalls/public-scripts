#!/usr/bin/env bash
#
# resize-disk.sh — Grow partition and filesystem after a GCP Persistent Disk resize.
#
# Follows Google Cloud manual resize steps:
#   https://cloud.google.com/compute/docs/disks/resize-persistent-disk
#   (parted resizepart → partprobe → resize2fs / xfs_growfs / btrfs)
#
# Supports Debian 12, Alma Linux, and other RHEL/Debian derivatives.
# Run AFTER increasing disk size in GCP (Console or gcloud compute disks resize).
#
# Usage:
#   sudo ./resize-disk.sh [-d|--disk /dev/sda] [-y|--yes]
#
set -euo pipefail

readonly SCRIPT_NAME="${0##*/}"
DISK=""
ASSUME_YES=false

usage() {
	cat <<EOF
Usage: ${SCRIPT_NAME} [OPTIONS]

Grow the root (or primary data) partition on a disk to fill all unallocated space,
then extend LVM and/or the filesystem as needed.

Options:
  -d, --disk DEVICE   Target whole disk (e.g. /dev/sda, /dev/nvme0n1)
  -y, --yes           Do not prompt for confirmation before resizing
  -h, --help          Show this help

If --disk is omitted:
  - One eligible disk  → that disk is used automatically
  - Multiple disks     → interactive menu (shows unallocated space per disk)

Examples:
  sudo ${SCRIPT_NAME}
  sudo ${SCRIPT_NAME} -d /dev/sda
  sudo ${SCRIPT_NAME} --disk /dev/nvme0n1 -y
EOF
}

log()  { printf '%s\n' "$*" >&2; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die()  { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# Read from the terminal (works when script is piped: curl ... | sudo bash).
read_tty() {
	local prompt="$1"
	local __var="$2"
	if [[ ! -r /dev/tty ]]; then
		die "No terminal for interactive input. Re-run with -y to skip confirmation."
	fi
	printf '%s' "$prompt" >&2
	read -r "${__var?}" </dev/tty
}

require_root() {
	[[ "${EUID:-$(id -u)}" -eq 0 ]] || die "This script must be run as root (sudo)."
}

parse_args() {
	while [[ $# -gt 0 ]]; do
		case "$1" in
		-d | --disk)
			[[ $# -ge 2 ]] || die "Option $1 requires a device path."
			DISK="$2"
			shift 2
			;;
		-y | --yes) ASSUME_YES=true; shift ;;
		-h | --help) usage; exit 0 ;;
		*) die "Unknown option: $1 (use --help)" ;;
		esac
	done
}

normalize_disk() {
	local d="$1"
	[[ -b "$d" ]] || die "Not a block device: $d"
	# Ensure we have the whole disk, not a partition.
	if lsblk -no TYPE "$d" 2>/dev/null | grep -qx disk; then
		printf '%s\n' "$d"
		return
	fi
	local pk
	pk="$(lsblk -no PKNAME "$d" 2>/dev/null | head -1)"
	[[ -n "$pk" ]] || die "Cannot resolve whole disk for: $d"
	printf '/dev/%s\n' "$pk"
}

human_size() {
	# bytes -> human readable
	numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || awk -v b="$1" 'BEGIN{
		split("B KiB MiB GiB TiB", u, " ");
		i=1; while(b>=1024 && i<5){b/=1024;i++}
		printf("%.2f %s\n", b, u[i])
	}'
}

# Unallocated bytes at the end of the disk (largest trailing free region).
unallocated_bytes() {
	local disk="$1"
	local bytes=""

	if command -v parted >/dev/null 2>&1; then
		# Last "Free Space" row is usually the trailing gap we can grow into.
		bytes="$(
			parted -s "$disk" unit B print free 2>/dev/null |
				awk '/Free Space/ { gsub(/B$/, "", $3); print $3 }' |
				tail -1
		)"
	fi

	if [[ -z "${bytes:-}" || ! "$bytes" =~ ^[0-9]+$ ]]; then
		# Fallback: disk size minus end of last partition (sector-based).
		if command -v sfdisk >/dev/null 2>&1; then
			local disk_sectors last_end
			disk_sectors="$(blockdev --getsize64 "$disk" 2>/dev/null || echo 0)"
			last_end="$(sfdisk -l -o Device,End "$disk" 2>/dev/null | awk 'NR>1 && $2 ~ /^[0-9]+$/ { if ($2 > m) m=$2 } END { print m+0 }')"
			if [[ "$disk_sectors" -gt 0 && "$last_end" -gt 0 ]]; then
				local sector_size
				sector_size="$(blockdev --getss "$disk" 2>/dev/null || echo 512)"
				bytes=$((disk_sectors - (last_end + 1) * sector_size))
				[[ "$bytes" -lt 0 ]] && bytes=0
			fi
		fi
	fi

	[[ "${bytes:-}" =~ ^[0-9]+$ ]] || bytes=0
	printf '%s\n' "$bytes"
}

disk_size_bytes() {
	blockdev --getsize64 "$1" 2>/dev/null || echo 0
}

# Eligible whole disks: TYPE=disk, not loop/ram, size > 0, and has at least one partition or is in use.
list_eligible_disks() {
	lsblk -dpn -o NAME,TYPE,SIZE,RM,RO,TRAN 2>/dev/null |
		awk '$2=="disk" && $4=="0" && $5=="0" {
			name=$1
			# skip loop and obvious zero-size
			if (name ~ /^\/dev\/(loop|ram|fd)/) next
			print name
		}'
}

partition_count_on_disk() {
	local disk="$1" base="${disk##*/}"
	lsblk -ln -o NAME,TYPE "$disk" 2>/dev/null | awk -v b="$base" '
		$2=="part" {
			n=$1
			sub(/^.*\//, "", n)
			if (n ~ "^" b) print n
		}' | wc -l
}

choose_disk_interactive() {
	local -a disks=()
	local d free human_free disk_human i choice

	mapfile -t disks < <(list_eligible_disks)
	[[ "${#disks[@]}" -gt 0 ]] || die "No eligible disks found."

	if [[ "${#disks[@]}" -eq 1 ]]; then
		printf '%s\n' "${disks[0]}"
		return
	fi

	log ""
	log "Multiple disks detected. Select which disk to resize:"
	log ""

	for i in "${!disks[@]}"; do
		d="${disks[$i]}"
		free="$(unallocated_bytes "$d")"
		human_free="$(human_size "$free")"
		disk_human="$(human_size "$(disk_size_bytes "$d")")"
		log "  [$((i + 1))] $d  total: $disk_human  unallocated: $human_free"
	done

	log ""
	while true; do
		read_tty "Enter choice [1-${#disks[@]}]: " choice
		if [[ "$choice" =~ ^[0-9]+$ ]] && ((choice >= 1 && choice <= ${#disks[@]})); then
			printf '%s\n' "${disks[$((choice - 1))]}"
			return
		fi
		warn "Invalid selection. Try again."
	done
}

resolve_target_disk() {
	if [[ -n "$DISK" ]]; then
		normalize_disk "$DISK"
		return
	fi

	local -a disks=()
	mapfile -t disks < <(list_eligible_disks)
	[[ "${#disks[@]}" -gt 0 ]] || die "No eligible disks found."

	if [[ "${#disks[@]}" -eq 1 ]]; then
		log "Single disk detected, using: ${disks[0]} (unallocated: $(human_size "$(unallocated_bytes "${disks[0]}")"))"
		printf '%s\n' "${disks[0]}"
		return
	fi

	choose_disk_interactive
}

# Partition number for growpart (handles nvme0n1p2 -> disk nvme0n1, part 2).
partition_number() {
	local part="$1"
	local disk="$2"
	local name="${part##*/}"
	local base="${disk##*/}"

	if [[ "$name" =~ ^${base}p?([0-9]+)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return
	fi

	# lsblk NAME may be full path or short name
	local short="${name##*/}"
	if [[ "$short" =~ p?([0-9]+)$ ]]; then
		printf '%s\n' "${BASH_REMATCH[1]}"
		return
	fi

	die "Cannot determine partition number for $part on $disk"
}

# Find partition on TARGET_DISK that holds / (walks LVM/dm/crypt up to the disk).
find_root_partition_on_disk() {
	local disk="$1"
	local cur pk btype

	cur="$(findmnt -n -o SOURCE /)"
	[[ -n "$cur" ]] || return 1

	while [[ -e "$cur" || -L "$cur" ]]; do
		btype="$(lsblk -no TYPE "$cur" 2>/dev/null | head -1)"
		if [[ "$btype" == "part" ]]; then
			pk="$(lsblk -no PKNAME "$cur" 2>/dev/null | head -1)"
			if [[ -n "$pk" && "/dev/${pk}" == "$disk" ]]; then
				printf '%s\n' "$cur"
				return 0
			fi
			return 1
		fi
		pk="$(lsblk -no PKNAME "$cur" 2>/dev/null | head -1)"
		[[ -n "$pk" ]] || return 1
		cur="/dev/${pk}"
	done
	return 1
}

# Partition to grow: root on this disk, else last partition on disk.
pick_grow_partition() {
	local disk="$1"
	local part

	if part="$(find_root_partition_on_disk "$disk" 2>/dev/null)"; then
		printf '%s\n' "$part"
		return
	fi

	# Last partition by device name order (common layout: data at end).
	part="$(
		lsblk -ln -o NAME,TYPE "$disk" 2>/dev/null |
			awk '$2=="part" { print $1 }' |
			sort -V |
			tail -1
	)"
	[[ -n "$part" ]] || die "No partitions found on $disk"
	[[ "$part" != /* ]] && part="/dev/${part}"
	printf '%s\n' "$part"
}

ensure_parted() {
	command -v parted >/dev/null 2>&1 && return
	log "parted not found; attempting to install..."
	export DEBIAN_FRONTEND=noninteractive
	if command -v apt-get >/dev/null 2>&1; then
		apt-get update -qq && apt-get install -y -qq parted
	elif command -v dnf >/dev/null 2>&1; then
		dnf install -y parted
	elif command -v yum >/dev/null 2>&1; then
		yum install -y parted
	else
		die "Install parted manually."
	fi
	command -v parted >/dev/null 2>&1 || die "parted still not available after install."
}

# GCP docs: sudo parted /dev/sda → resizepart N → Yes → 100% → quit → partprobe
show_disk_status() {
	local disk="${1:-}"
	log ""
	log "=== Before resize (GCP: df -Th / lsblk) ==="
	df -Th 2>/dev/null || true
	log ""
	if [[ -n "$disk" ]]; then
		lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$disk" 2>/dev/null || lsblk
	else
		lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT
	fi
	log ""
}

check_partition_table() {
	local disk="$1"
	local table size_b

	table="$(parted -s "$disk" print 2>/dev/null | awk -F': ' '/Partition Table:/ { print $2; exit }')"
	[[ "$table" == "msdos" ]] || return 0

	size_b="$(disk_size_bytes "$disk")"
	if [[ "$size_b" -gt $((2 * 1024 * 1024 * 1024 * 1024)) ]]; then
		die "Disk $disk uses MBR (msdos); GCP max is 2 TiB. Use GPT or a smaller disk."
	fi
	warn "Partition table is MBR (msdos). GCP disks cannot grow past 2 TiB."
}

# Filesystem lives directly on the whole disk (no partition table) — GCP non-boot example.
filesystem_on_whole_disk() {
	local disk="$1"
	local fstype
	fstype="$(lsblk -dn -o FSTYPE "$disk" 2>/dev/null | head -1)"
	[[ -n "$fstype" && "$fstype" != "-" ]]
}

grow_partition_gcp() {
	local disk="$1" partnum="$2"

	ensure_parted
	check_partition_table "$disk"

	log "Resizing partition ${partnum} on ${disk} to 100% (parted resizepart)..."

	# GCP: resizepart → Yes (partition in use) → End 100%
	if parted -s "$disk" resizepart "$partnum" 100% 2>/dev/null; then
		:
	elif parted ---pretend-input-tty "$disk" resizepart "$partnum" 100% <<< "Yes" 2>/dev/null; then
		:
	elif command -v growpart >/dev/null 2>&1 && growpart "$disk" "$partnum" 2>&1; then
		warn "parted resizepart failed; used growpart fallback."
	else
		die "Failed to resize partition ${partnum} on ${disk}."
	fi

	# GCP: sudo partprobe /dev/sda
	if command -v partprobe >/dev/null 2>&1; then
		partprobe "$disk"
	else
		partx -u "$disk" 2>/dev/null || true
	fi
}

lv_device_path() {
	local vg="$1" lv="$2"
	if [[ -e "/dev/mapper/${vg}-${lv}" ]]; then
		printf '/dev/mapper/%s-%s\n' "$vg" "$lv"
	elif [[ -e "/dev/${vg}/${lv}" ]]; then
		printf '/dev/%s/%s\n' "$vg" "$lv"
	else
		printf '/dev/%s/%s\n' "$vg" "$lv"
	fi
}

extend_lvm_on_partition() {
	local part="$1" pv vg_name root_src lv lv_path

	if ! command -v pvs >/dev/null 2>&1; then
		return 0
	fi

	pv="$(pvs --noheadings -o pv_name 2>/dev/null | tr -d ' ' | grep -Fx "$part" || true)"
	[[ -z "$pv" ]] && return 0

	log "Resizing physical volume $pv..."
	pvresize "$pv"

	vg_name="$(pvs --noheadings -o vg_name "$pv" 2>/dev/null | tr -d ' ')"
	[[ -n "$vg_name" ]] || return 0

	root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"

	# Prefer the LV that backs /
	while read -r lv; do
		[[ -z "$lv" ]] && continue
		lv_path="$(lv_device_path "$vg_name" "$lv")"
		if [[ -n "$root_src" && "$lv_path" == "$root_src" ]]; then
			log "Extending root logical volume ${vg_name}/${lv}..."
			lvextend -l +100%FREE "$lv_path"
			return 0
		fi
	done < <(lvs --noheadings -o lv_name "$vg_name" 2>/dev/null)

	# Otherwise extend any mounted LV on this VG
	while read -r lv; do
		[[ -z "$lv" ]] && continue
		lv_path="$(lv_device_path "$vg_name" "$lv")"
		if findmnt -rn "$lv_path" >/dev/null 2>&1; then
			log "Extending logical volume ${vg_name}/${lv}..."
			lvextend -l +100%FREE "$lv_path"
		fi
	done < <(lvs --noheadings -o lv_name "$vg_name" 2>/dev/null)
}

grow_filesystem() {
	local device="$1"
	# Follow stack: partition -> PV -> LV -> what is actually mounted
	local to_grow="$device"
	local fstype mountpoint

	# If LVM, grow the root LV (or first mounted LV) on this PV
	if command -v pvs >/dev/null 2>&1 && pvs "$device" &>/dev/null; then
		local vg lv lv_path root_src
		vg="$(pvs --noheadings -o vg_name "$device" 2>/dev/null | tr -d ' ')"
		root_src="$(findmnt -n -o SOURCE / 2>/dev/null || true)"
		while read -r lv; do
			[[ -z "$lv" ]] && continue
			lv_path="$(lv_device_path "$vg" "$lv")"
			if [[ -n "$root_src" && "$lv_path" == "$root_src" ]]; then
				to_grow="$lv_path"
				break
			fi
			if [[ "$to_grow" == "$device" ]] && findmnt -rn "$lv_path" >/dev/null 2>&1; then
				to_grow="$lv_path"
			fi
		done < <(lvs --noheadings -o lv_name "$vg" 2>/dev/null)
	fi

	# If still partition with direct mount
	if [[ "$to_grow" == "$device" ]]; then
		if findmnt -rn "$device" >/dev/null 2>&1; then
			to_grow="$device"
		else
			# dm-crypt child?
			local child
			child="$(lsblk -ln -o NAME,TYPE "$device" 2>/dev/null | awk '$2!="part" && $2!="disk" {print $1; exit}')"
			if [[ -n "$child" ]]; then
				[[ "$child" != /* ]] && child="/dev/${child}"
				findmnt -rn "$child" >/dev/null 2>&1 && to_grow="$child"
			fi
		fi
	fi

	fstype="$(blkid -o value -s TYPE "$to_grow" 2>/dev/null || true)"
	mountpoint="$(findmnt -rn -o TARGET -S "$to_grow" 2>/dev/null | head -1 || true)"

	log "Extending filesystem on ${to_grow} (type: ${fstype:-unknown})..."

	# GCP: online grow only — no e2fsck on mounted ext4
	case "$fstype" in
	ext2 | ext3 | ext4)
		resize2fs "$to_grow"
		;;
	xfs)
		[[ -n "$mountpoint" ]] || die "XFS must be mounted to grow; mount ${to_grow} first."
		# GCP: sudo xfs_growfs -d /
		xfs_growfs -d "$mountpoint"
		;;
	btrfs)
		[[ -n "$mountpoint" ]] || die "btrfs must be mounted to grow."
		# GCP: sudo btrfs filesystem resize max MOUNT_DIR
		btrfs filesystem resize max "$mountpoint"
		;;
	'')
		warn "No filesystem detected on ${to_grow}; partition grown only."
		;;
	*)
		warn "Unsupported filesystem type '${fstype}' on ${to_grow}. Partition/LVM may still be grown."
		;;
	esac
}

confirm_resize() {
	local disk="$1" part="$2" free="$3"
	local free_h disk_h part_size

	free_h="$(human_size "$free")"
	disk_h="$(human_size "$(disk_size_bytes "$disk")")"
	part_size="$(lsblk -no SIZE "$part" 2>/dev/null || echo '?')"

	log ""
	log "=== Resize plan ==="
	log "  Disk:        $disk ($disk_h)"
	log "  Partition:   $part ($part_size)"
	log "  Unallocated: $free_h"
	log ""

	[[ "$free" -gt 1048576 ]] || die "Less than ~1 MiB unallocated on $disk; nothing to do."

	if $ASSUME_YES; then
		return 0
	fi

	read_tty "Proceed with resize? [y/N]: " ans
	[[ "${ans,,}" == "y" || "${ans,,}" == "yes" ]] || die "Aborted by user."
}

main() {
	parse_args "$@"
	require_root

	command -v lsblk >/dev/null 2>&1 || die "lsblk required (util-linux)."
	command -v numfmt >/dev/null 2>&1 || warn "numfmt not found; sizes may be less readable."

	local disk part partnum free

	disk="$(resolve_target_disk)"
	disk="$(normalize_disk "$disk")"

	show_disk_status "$disk"

	free="$(unallocated_bytes "$disk")"

	# Whole-disk filesystem (GCP non-boot disk with no partition table)
	if filesystem_on_whole_disk "$disk"; then
		confirm_resize "$disk" "$disk" "$free"
		grow_filesystem "$disk"
	else
		part="$(pick_grow_partition "$disk")"
		partnum="$(partition_number "$part" "$disk")"
		confirm_resize "$disk" "$part" "$free"
		grow_partition_gcp "$disk" "$partnum"
		extend_lvm_on_partition "$part"
		grow_filesystem "$part"
	fi

	log ""
	log "=== After resize (GCP: verify with df) ==="
	df -Th 2>/dev/null || true
	log ""
	log "Block layout:"
	lsblk -o NAME,SIZE,TYPE,FSTYPE,MOUNTPOINT "$disk"
	log ""
	free="$(unallocated_bytes "$disk")"
	log "Remaining unallocated on ${disk}: $(human_size "$free")"
}

main "$@"
