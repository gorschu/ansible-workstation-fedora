#!/usr/bin/env bash
# 02-zfs-setup.sh - ZFS bootstrap for Fedora (hybrid mode)
# Usage: sudo ./02-zfs-setup.sh /dev/disk/by-id/<disk-id>
#
# Creates ZFS partition and encrypted pool. Datasets are created by ansible.
# /home stays on btrfs; important data lives on ZFS.
# Based on https://openzfs.github.io/openzfs-docs/Getting%20Started/Fedora/index.html

set -euo pipefail

# Pool name
POOL_NAME="tank"

# Check arguments
if [[ $# -lt 1 ]]; then
  echo "Usage: $0 /dev/disk/by-id/<disk-id>"
  echo "Example: $0 /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_XXXXXX"
  echo ""
  echo "Available disks:"
  for disk in /dev/disk/by-id/*; do
    name=$(basename "$disk")
    [[ $name == dm-* ]] && continue
    [[ $name == *-part[0-9]* ]] && continue
    [[ $name == lvm-* ]] && continue
    echo "  $disk"
  done
  exit 1
fi

DISK="$1"

# Check if running as root
if [[ $EUID -ne 0 ]]; then
  echo "Error: This script must be run as root"
  exit 1
fi

# Validate by-id path
if [[ ! "$DISK" =~ ^/dev/disk/by-id/ ]]; then
  echo "Error: Disk must be a /dev/disk/by-id/ path"
  echo "Example: /dev/disk/by-id/nvme-Samsung_SSD_990_PRO_1TB_XXXXXX"
  exit 1
fi

# Check if disk exists
if [[ ! -b "$DISK" ]]; then
  echo "Error: $DISK does not exist or is not a block device"
  exit 1
fi

echo "==> ZFS Bootstrap for Fedora (Hybrid Mode)"
echo "Using disk: $DISK"
echo ""
echo "This will create an encrypted ZFS pool: ${POOL_NAME}"
echo "Datasets are created by ansible after bootstrap."
echo ""

# Remove zfs-fuse if present (conflicts with OpenZFS)
if rpm -q zfs-fuse &>/dev/null; then
  echo "==> Removing zfs-fuse (conflicts with OpenZFS)..."
  dnf remove -y zfs-fuse
fi

# Install ZFS repository and packages
echo "==> Installing ZFS repository..."
if [[ ! -f /etc/yum.repos.d/zfs.repo ]]; then
  dnf install -y "https://zfsonlinux.org/fedora/zfs-release-3-0$(rpm --eval "%{dist}").noarch.rpm"
fi

echo "==> Installing requirements and ZFS packages..."
dnf install -y gdisk kernel-devel kernel-headers zfs

# Load ZFS module if needed
if ! lsmod | grep -q "^zfs"; then
  echo "==> Loading ZFS kernel module..."
  modprobe zfs
fi

# Verify ZFS is working
if ! zpool version &>/dev/null; then
  echo "Error: ZFS module failed to load properly"
  echo "You may need to reboot and try again, or check dmesg for errors"
  exit 1
fi

# Show current partition layout
echo ""
echo "Current partition layout:"
sgdisk -p "$DISK"
echo ""

# Partition path uses -part suffix for by-id
ZFS_PART="${DISK}-part9"

# Check if partition 9 already exists
if [[ -b "$ZFS_PART" ]]; then
  echo "Partition 9 already exists: ${ZFS_PART}"
else
  echo "==> Creating ZFS partition (partition 9)..."
  sgdisk -n 9:0:0 -t 9:BF01 -c 9:"zfs-data" "$DISK"
  partprobe "$(readlink -f "$DISK")"
  sleep 2
  echo "Created: ${ZFS_PART}"
fi

echo ""

# Generate ZFS encryption key (hex format for easier backup)
ZFS_KEYFILE="/etc/zfs/zpool.key"
if [[ ! -f "$ZFS_KEYFILE" ]]; then
  echo "==> Generating ZFS encryption key..."
  mkdir -p /etc/zfs
  openssl rand -hex 32 > "$ZFS_KEYFILE"
  chmod 600 "$ZFS_KEYFILE"
  echo "Key created: ${ZFS_KEYFILE}"
else
  echo "ZFS key already exists: ${ZFS_KEYFILE}"
fi

echo ""

# Check if pool already exists
if zpool list "$POOL_NAME" &>/dev/null; then
  echo "Pool '${POOL_NAME}' already exists. Skipping pool creation."
else
  echo "==> Creating encrypted ZFS pool '${POOL_NAME}'..."

  # Verify partition symlink exists (should be created by udev after partprobe)
  if [[ ! -b "$ZFS_PART" ]]; then
    echo "Waiting for partition symlink..."
    for _ in {1..10}; do
      sleep 1
      [[ -b "$ZFS_PART" ]] && break
    done
    if [[ ! -b "$ZFS_PART" ]]; then
      echo "Error: Partition symlink ${ZFS_PART} not found after 10 seconds"
      exit 1
    fi
  fi

  ZFS_DEVICE="$ZFS_PART"
  echo "Using device: ${ZFS_DEVICE}"

  zpool create -f \
    -o ashift=12 \
    -o autotrim=on \
    -O acltype=posixacl \
    -O xattr=sa \
    -O dnodesize=auto \
    -O normalization=formD \
    -O relatime=on \
    -O canmount=off \
    -O mountpoint=none \
    -O compression=zstd \
    -O encryption=aes-256-gcm \
    -O keyformat=hex \
    -O keylocation="file://${ZFS_KEYFILE}" \
    "$POOL_NAME" "$ZFS_DEVICE"

  echo "Pool created successfully"
fi

echo ""

# Deploy zfs-load-key service
echo "==> Deploying zfs-load-key service..."
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ZFS_SERVICE="${REPO_ROOT}/roles/zfs/files/zfs-load-key.service"

if [[ ! -f "$ZFS_SERVICE" ]]; then
  echo "Error: ${ZFS_SERVICE} not found"
  echo "Run this script from the chezmoi repository"
  exit 1
fi

cp "$ZFS_SERVICE" /etc/systemd/system/
chmod 644 /etc/systemd/system/zfs-load-key.service

# Enable ZFS services
echo "==> Enabling ZFS services..."
systemctl daemon-reload
systemctl enable zfs-import-cache.service
systemctl enable zfs-load-key.service
systemctl enable zfs-mount.service
systemctl enable zfs-import.target
systemctl enable zfs.target
systemctl enable zfs-zed.service

# Generate zpool cache
zpool set cachefile=/etc/zfs/zpool.cache "$POOL_NAME"

echo ""
echo "==> ZFS setup complete!"
echo ""
zpool status "$POOL_NAME"
echo ""
zfs list -r "$POOL_NAME"
echo ""
echo "WARNING: Back up ${ZFS_KEYFILE} to a secure location!"
echo "         Without this key, your ZFS data is unrecoverable."
echo ""
echo "Next steps:"
echo "1. Run ansible to configure zfs/zrepl"
echo "2. Reboot to verify ZFS mounts automatically"
