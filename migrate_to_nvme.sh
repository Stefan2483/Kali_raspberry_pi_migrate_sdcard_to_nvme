#!/bin/bash
#=============================================================================
# Raspberry Pi 5 - Migrate Kali OS from microSD to NVMe SSD
# Target: /dev/nvme0n1 (BIWIN CE930TF1R00-1TB)
# Source: /dev/mmcblk0 (32GB microSD)
#=============================================================================
# WARNING: This will ERASE all data on /dev/nvme0n1
# Run as root. Keep the microSD as fallback until verified.
#=============================================================================

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

SRC_BOOT="/dev/mmcblk0p1"
SRC_ROOT="/dev/mmcblk0p2"
DST_DISK="/dev/nvme0n1"
DST_BOOT="${DST_DISK}p1"
DST_ROOT="${DST_DISK}p2"

log()  { echo -e "${GREEN}[+]${NC} $1"; }
warn() { echo -e "${YELLOW}[!]${NC} $1"; }
err()  { echo -e "${RED}[-]${NC} $1"; exit 1; }
info() { echo -e "${CYAN}[*]${NC} $1"; }

# ── Pre-flight checks ──────────────────────────────────────────────────────
[[ $EUID -ne 0 ]] && err "Run as root"
[[ ! -b "$DST_DISK" ]] && err "NVMe disk $DST_DISK not found"
[[ ! -b "$SRC_BOOT" ]] && err "Source boot partition $SRC_BOOT not found"
[[ ! -b "$SRC_ROOT" ]] && err "Source root partition $SRC_ROOT not found"

# Check required tools
for tool in parted mkfs.vfat mkfs.ext4 rsync blkid sed; do
    command -v "$tool" &>/dev/null || err "Missing tool: $tool"
done

echo ""
echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${RED}║  WARNING: ALL DATA ON /dev/nvme0n1 WILL BE DESTROYED       ║${NC}"
echo -e "${RED}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${RED}║  Source:  /dev/mmcblk0  (microSD - Kali)                    ║${NC}"
echo -e "${RED}║  Target:  /dev/nvme0n1  (NVMe SSD - 1TB BIWIN)             ║${NC}"
echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""
read -rp "Type YES to proceed: " CONFIRM
[[ "$CONFIRM" != "YES" ]] && err "Aborted by user"

# ── Step 1: Partition the NVMe SSD ──────────────────────────────────────────
log "Step 1/8: Partitioning NVMe SSD..."

# Wipe existing partition table
wipefs -af "$DST_DISK" &>/dev/null
dd if=/dev/zero of="$DST_DISK" bs=1M count=16 status=none

# Create partition table matching Pi 5 requirements
# p1: 512MB FAT32 boot (bigger than source for future kernel updates)
# p2: Remaining space ext4 root
parted -s "$DST_DISK" -- \
    mklabel msdos \
    mkpart primary fat32 4MiB 516MiB \
    set 1 lba on \
    mkpart primary ext4 516MiB 100%

sleep 2
partprobe "$DST_DISK"
sleep 2

# Verify partitions appeared
[[ ! -b "$DST_BOOT" ]] && err "Partition $DST_BOOT not created"
[[ ! -b "$DST_ROOT" ]] && err "Partition $DST_ROOT not created"
log "Partitions created successfully"

# ── Step 2: Format partitions ───────────────────────────────────────────────
log "Step 2/8: Formatting partitions..."
mkfs.vfat -F 32 -n BOOT "$DST_BOOT"
mkfs.ext4 -F -L kali-root "$DST_ROOT"
log "Formatting complete"

# ── Step 3: Mount destinations ──────────────────────────────────────────────
log "Step 3/8: Mounting partitions..."

MNT_BOOT="/mnt/nvme_boot"
MNT_ROOT="/mnt/nvme_root"

mkdir -p "$MNT_BOOT" "$MNT_ROOT"
mount "$DST_ROOT" "$MNT_ROOT"
mount "$DST_BOOT" "$MNT_BOOT"

# Cleanup function
cleanup() {
    warn "Cleaning up mounts..."
    umount "$MNT_BOOT" 2>/dev/null || true
    umount "$MNT_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

log "Mounted successfully"

# ── Step 4: Clone root filesystem ───────────────────────────────────────────
log "Step 4/8: Cloning root filesystem (this will take a while)..."
info "Source: / (mounted from $SRC_ROOT)"
info "Destination: $MNT_ROOT"

rsync -axHAWXS --numeric-ids --info=progress2 \
    --exclude='/boot/firmware/*' \
    --exclude='/mnt/*' \
    --exclude='/proc/*' \
    --exclude='/sys/*' \
    --exclude='/dev/*' \
    --exclude='/run/*' \
    --exclude='/tmp/*' \
    --exclude='/var/tmp/*' \
    --exclude='/var/cache/apt/archives/*.deb' \
    --exclude='/lost+found' \
    / "$MNT_ROOT/"

# Create required empty directories
mkdir -p "$MNT_ROOT"/{proc,sys,dev,run,tmp,mnt,boot/firmware}
chmod 1777 "$MNT_ROOT/tmp"

log "Root filesystem cloned"

# ── Step 5: Clone boot partition ────────────────────────────────────────────
log "Step 5/8: Cloning boot partition..."
rsync -avHAWXS --numeric-ids --info=progress2 \
    /boot/firmware/ "$MNT_BOOT/"

log "Boot partition cloned"

# ── Step 6: Get PARTUUIDs and update boot config ────────────────────────────
log "Step 6/8: Updating boot configuration..."

NVME_ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$DST_ROOT")
NVME_BOOT_PARTUUID=$(blkid -s PARTUUID -o value "$DST_BOOT")
NVME_ROOT_UUID=$(blkid -s UUID -o value "$DST_ROOT")
NVME_BOOT_UUID=$(blkid -s UUID -o value "$DST_BOOT")

SD_ROOT_PARTUUID=$(blkid -s PARTUUID -o value "$SRC_ROOT")
SD_BOOT_PARTUUID=$(blkid -s PARTUUID -o value "$SRC_BOOT")

info "NVMe root PARTUUID: $NVME_ROOT_PARTUUID"
info "NVMe boot PARTUUID: $NVME_BOOT_PARTUUID"

# Update cmdline.txt - change root= to point to NVMe
if [[ -f "$MNT_BOOT/cmdline.txt" ]]; then
    cp "$MNT_BOOT/cmdline.txt" "$MNT_BOOT/cmdline.txt.bak"
    # Replace any root= reference (PARTUUID, UUID, or device path)
    sed -i "s|root=PARTUUID=[^ ]*|root=PARTUUID=${NVME_ROOT_PARTUUID}|g" "$MNT_BOOT/cmdline.txt"
    sed -i "s|root=/dev/mmcblk0p2|root=PARTUUID=${NVME_ROOT_PARTUUID}|g" "$MNT_BOOT/cmdline.txt"
    sed -i "s|root=UUID=[^ ]*|root=PARTUUID=${NVME_ROOT_PARTUUID}|g" "$MNT_BOOT/cmdline.txt"
    info "cmdline.txt updated:"
    cat "$MNT_BOOT/cmdline.txt"
else
    warn "cmdline.txt not found - manual configuration needed"
fi

# ── Step 7: Update fstab on NVMe ────────────────────────────────────────────
log "Step 7/8: Updating fstab..."

cp "$MNT_ROOT/etc/fstab" "$MNT_ROOT/etc/fstab.bak"

# Build new fstab
cat > "$MNT_ROOT/etc/fstab" << FSTAB
# /etc/fstab - Kali on NVMe SSD
# <file system>                          <mount point>   <type>  <options>                <dump> <pass>
PARTUUID=${NVME_ROOT_PARTUUID}           /               ext4    defaults,noatime         0      1
PARTUUID=${NVME_BOOT_PARTUUID}           /boot/firmware  vfat    defaults                 0      2
tmpfs                                    /tmp            tmpfs   defaults,nosuid,nodev    0      0
FSTAB

info "New fstab:"
cat "$MNT_ROOT/etc/fstab"

# ── Step 8: Sync and verify ─────────────────────────────────────────────────
log "Step 8/8: Syncing and verifying..."
sync

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  MIGRATION COMPLETE                                         ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Next steps:                                                ║${NC}"
echo -e "${GREEN}║                                                             ║${NC}"
echo -e "${GREEN}║  1. Configure Pi 5 EEPROM to boot from NVMe:               ║${NC}"
echo -e "${GREEN}║     sudo rpi-eeprom-config --edit                           ║${NC}"
echo -e "${GREEN}║     Set: BOOT_ORDER=0xf416                                  ║${NC}"
echo -e "${GREEN}║     (NVMe first, then SD, then USB, then restart)           ║${NC}"
echo -e "${GREEN}║                                                             ║${NC}"
echo -e "${GREEN}║  2. Reboot:                                                 ║${NC}"
echo -e "${GREEN}║     sudo reboot                                             ║${NC}"
echo -e "${GREEN}║                                                             ║${NC}"
echo -e "${GREEN}║  3. After successful NVMe boot, verify with:                ║${NC}"
echo -e "${GREEN}║     lsblk                                                   ║${NC}"
echo -e "${GREEN}║     findmnt /                                               ║${NC}"
echo -e "${GREEN}║                                                             ║${NC}"
echo -e "${GREEN}║  KEEP THE microSD AS FALLBACK until verified!               ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════╝${NC}"
echo ""

# ── Optional: Auto-configure EEPROM ────────────────────────────────────────
read -rp "Configure EEPROM boot order for NVMe now? (y/N): " EEPROM_CONF
if [[ "$EEPROM_CONF" =~ ^[Yy]$ ]]; then
    if command -v rpi-eeprom-config &>/dev/null; then
        log "Updating EEPROM boot order..."
        # Get current config, update BOOT_ORDER
        CURRENT_CONFIG=$(rpi-eeprom-config 2>/dev/null || echo "")
        
        # Create temp config
        TMPCONF=$(mktemp)
        if echo "$CURRENT_CONFIG" | grep -q "BOOT_ORDER"; then
            echo "$CURRENT_CONFIG" | sed 's/BOOT_ORDER=.*/BOOT_ORDER=0xf416/' > "$TMPCONF"
        else
            echo "$CURRENT_CONFIG" > "$TMPCONF"
            echo "BOOT_ORDER=0xf416" >> "$TMPCONF"
        fi
        
        # Ensure NVMe is enabled
        if ! grep -q "PCIE_PROBE" "$TMPCONF"; then
            echo "PCIE_PROBE=1" >> "$TMPCONF"
        fi
        
        rpi-eeprom-config --apply "$TMPCONF"
        rm -f "$TMPCONF"
        
        log "EEPROM updated. Boot order: NVMe → SD → USB → Restart"
        warn "Reboot required to apply EEPROM changes"
    else
        warn "rpi-eeprom-config not found. Install with: apt install rpi-eeprom"
        warn "Then manually set BOOT_ORDER=0xf416"
    fi
fi

log "Done. Reboot when ready."
