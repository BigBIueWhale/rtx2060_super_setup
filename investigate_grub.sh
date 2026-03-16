#!/bin/bash
set -euo pipefail

# Investigate GRUB installation on HP Pavilion Gaming Desktop TG01-1xxx
# Run as root: sudo bash ~/setup/investigate_grub.sh
# This script is READ-ONLY. It does not modify anything.

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
NC='\033[0m'

pass_count=0
total_count=0

assert_true() {
    local description="$1"
    local condition="$2"
    total_count=$((total_count + 1))
    if eval "$condition"; then
        echo -e "  ${GREEN}PASS${NC}: $description"
        pass_count=$((pass_count + 1))
    else
        echo -e "  ${RED}FAIL${NC}: $description"
        echo -e "  ${RED}FATAL: Expectation not met. Aborting to prevent misdiagnosis.${NC}"
        exit 1
    fi
}

assert_file_exists() {
    assert_true "File exists: $1" "[ -f '$1' ]"
}

assert_dir_exists() {
    assert_true "Directory exists: $1" "[ -d '$1' ]"
}

assert_command_exists() {
    assert_true "Command available: $1" "command -v '$1' &>/dev/null"
}

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: This script must be run as root (sudo)"
    exit 1
fi

# ============================================================
echo -e "\n${CYAN}=== 1. Boot Mode ===${NC}"
echo "Expectation: System boots via UEFI, not legacy BIOS."
# ============================================================

assert_dir_exists "/sys/firmware/efi"
assert_dir_exists "/sys/firmware/efi/efivars"

PLATFORM_SIZE=$(cat /sys/firmware/efi/fw_platform_size)
assert_true "UEFI platform is 64-bit (fw_platform_size=${PLATFORM_SIZE})" "[ '$PLATFORM_SIZE' = '64' ]"

# ============================================================
echo -e "\n${CYAN}=== 2. Disk Layout ===${NC}"
echo "Expectation: Single NVMe drive with GPT partition table."
echo "  Partition 1: EFI System Partition (FAT32, mounted at /boot/efi)"
echo "  Partition 2: Root filesystem (ext4, mounted at /)"
# ============================================================

assert_true "Block device /dev/nvme0n1 exists" "[ -b /dev/nvme0n1 ]"
assert_true "Block device /dev/nvme0n1p1 exists (EFI partition)" "[ -b /dev/nvme0n1p1 ]"
assert_true "Block device /dev/nvme0n1p2 exists (root partition)" "[ -b /dev/nvme0n1p2 ]"
assert_true "No third partition /dev/nvme0n1p3 (only 2 expected)" "[ ! -b /dev/nvme0n1p3 ]"

PART_TABLE=$(blkid -o value -s PTTYPE /dev/nvme0n1)
assert_true "Partition table is GPT (got: ${PART_TABLE})" "[ '$PART_TABLE' = 'gpt' ]"

ESP_FSTYPE=$(blkid -o value -s TYPE /dev/nvme0n1p1)
assert_true "EFI partition is FAT (vfat) filesystem (got: ${ESP_FSTYPE})" "[ '$ESP_FSTYPE' = 'vfat' ]"

ROOT_FSTYPE=$(blkid -o value -s TYPE /dev/nvme0n1p2)
assert_true "Root partition is ext4 filesystem (got: ${ROOT_FSTYPE})" "[ '$ROOT_FSTYPE' = 'ext4' ]"

ESP_MOUNT=$(findmnt -n -o TARGET /dev/nvme0n1p1 2>/dev/null || echo "NOT_MOUNTED")
assert_true "EFI partition is mounted at /boot/efi (got: ${ESP_MOUNT})" "[ '$ESP_MOUNT' = '/boot/efi' ]"

ROOT_MOUNT=$(findmnt -n -o TARGET /dev/nvme0n1p2 2>/dev/null || echo "NOT_MOUNTED")
assert_true "Root partition is mounted at / (got: ${ROOT_MOUNT})" "[ '$ROOT_MOUNT' = '/' ]"

# ============================================================
echo -e "\n${CYAN}=== 3. GRUB Packages ===${NC}"
echo "Expectation: GRUB 2.12 EFI packages for amd64 are installed."
# ============================================================

for pkg in grub-common grub2-common grub-efi-amd64 grub-efi-amd64-bin grub-efi-amd64-signed; do
    STATUS=$(dpkg-query -W -f='${Status}' "$pkg" 2>/dev/null || echo "not-installed")
    assert_true "Package '$pkg' is installed (status: ${STATUS})" "echo '$STATUS' | grep -q 'install ok installed'"
done

GRUB_VERSION=$(grub-install --version 2>/dev/null | grep -oP '[\d.]+' | head -1)
assert_true "GRUB version is 2.12 (got: ${GRUB_VERSION})" "[ '$GRUB_VERSION' = '2.12' ]"

# ============================================================
echo -e "\n${CYAN}=== 4. EFI Boot Entries ===${NC}"
echo "Expectation: Ubuntu is the current boot entry (Boot0000),"
echo "  booting via Secure Boot shim (shimx64.efi)."
# ============================================================

assert_command_exists "efibootmgr"

BOOT_CURRENT=$(efibootmgr | grep '^BootCurrent:' | awk '{print $2}')
assert_true "Current boot entry is 0000 (got: ${BOOT_CURRENT})" "[ '$BOOT_CURRENT' = '0000' ]"

BOOT_ORDER=$(efibootmgr | grep '^BootOrder:' | awk '{print $2}')
FIRST_BOOT=$(echo "$BOOT_ORDER" | cut -d',' -f1)
assert_true "First entry in boot order is 0000/Ubuntu (got: ${FIRST_BOOT})" "[ '$FIRST_BOOT' = '0000' ]"

UBUNTU_ENTRY=$(efibootmgr -v | grep '^Boot0000')
assert_true "Boot0000 is labeled 'Ubuntu'" "echo '$UBUNTU_ENTRY' | grep -qi 'ubuntu'"
assert_true "Boot0000 loads shimx64.efi (Secure Boot shim)" "echo '$UBUNTU_ENTRY' | grep -qi 'shimx64.efi'"

# ============================================================
echo -e "\n${CYAN}=== 5. EFI System Partition Contents ===${NC}"
echo "Expectation: The EFI System Partition contains the Ubuntu"
echo "  GRUB EFI binaries (shimx64.efi, grubx64.efi)."
# ============================================================

assert_dir_exists "/boot/efi/EFI"
assert_dir_exists "/boot/efi/EFI/ubuntu"
assert_file_exists "/boot/efi/EFI/ubuntu/shimx64.efi"
assert_file_exists "/boot/efi/EFI/ubuntu/grubx64.efi"
assert_file_exists "/boot/efi/EFI/ubuntu/grub.cfg"

echo ""
echo "  EFI partition contents:"
find /boot/efi/EFI -type f | sort | while read -r f; do
    SIZE=$(stat -c%s "$f")
    echo "    $f  (${SIZE} bytes)"
done

# ============================================================
echo -e "\n${CYAN}=== 6. GRUB Configuration Files ===${NC}"
echo "Expectation: /etc/default/grub exists (source config)."
echo "  /boot/grub/grub.cfg exists (generated config)."
# ============================================================

assert_file_exists "/etc/default/grub"
assert_file_exists "/boot/grub/grub.cfg"

echo ""
echo "  /etc/default/grub active settings:"
grep -v '^\s*#' /etc/default/grub | grep -v '^\s*$' | while read -r line; do
    echo "    $line"
done

# ============================================================
echo -e "\n${CYAN}=== 7. GRUB Menu Entries ===${NC}"
echo "Listing all menuentry titles from /boot/grub/grub.cfg."
# ============================================================

echo ""
grep -P '^\s*menuentry\s' /boot/grub/grub.cfg | sed "s/menuentry '\\([^']*\\)'.*/  \\1/" | while read -r entry; do
    echo "    $entry"
done

# ============================================================
echo -e "\n${CYAN}=== 8. Kernel Images ===${NC}"
echo "Expectation: At least one kernel image exists in /boot."
# ============================================================

KERNEL_COUNT=$(ls /boot/vmlinuz-* 2>/dev/null | wc -l)
assert_true "At least one kernel image in /boot (found: ${KERNEL_COUNT})" "[ '$KERNEL_COUNT' -ge 1 ]"

RUNNING_KERNEL=$(uname -r)
assert_file_exists "/boot/vmlinuz-${RUNNING_KERNEL}"
assert_file_exists "/boot/initrd.img-${RUNNING_KERNEL}"

echo ""
echo "  Running kernel: ${RUNNING_KERNEL}"
echo "  Installed kernel images:"
ls -lh /boot/vmlinuz-* | while read -r line; do
    echo "    $line"
done

# ============================================================
echo -e "\n${CYAN}=== 9. Secure Boot Status ===${NC}"
echo "Checking whether UEFI Secure Boot is enabled or disabled."
# ============================================================

if command -v mokutil &>/dev/null; then
    SB_STATE=$(mokutil --sb-state 2>/dev/null || echo "unknown")
    echo "  Secure Boot state: ${SB_STATE}"
else
    echo "  mokutil not available, checking via EFI variable..."
    if [ -f /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c ]; then
        SB_BYTE=$(od -An -t u1 -j4 -N1 /sys/firmware/efi/efivars/SecureBoot-8be4df61-93ca-11d2-aa0d-00e098032b8c | tr -d ' ')
        if [ "$SB_BYTE" = "1" ]; then
            echo "  Secure Boot: ENABLED"
        else
            echo "  Secure Boot: DISABLED"
        fi
    else
        echo "  Secure Boot: unable to determine"
    fi
fi

# ============================================================
echo -e "\n${CYAN}=== 10. Other Boot Entries (informational) ===${NC}"
# ============================================================

echo "  All UEFI boot entries:"
efibootmgr | grep '^Boot[0-9]' | while read -r line; do
    echo "    $line"
done

# ============================================================
echo -e "\n${CYAN}=== Summary ===${NC}"
# ============================================================

echo -e "  ${GREEN}All ${pass_count}/${total_count} assertions passed.${NC}"
echo "  GRUB is installed and configured for UEFI boot on /dev/nvme0n1."
echo "  Boot chain: UEFI firmware -> shimx64.efi -> grubx64.efi -> Linux kernel ${RUNNING_KERNEL}"
