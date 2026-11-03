#!/bin/bash
# ------------------------------------------------------------------------------
# UFI003 Armbian Image Build Script
# ------------------------------------------------------------------------------
# PREREQUISITES (run on Ubuntu 24.04 or Debian Trixie, natively or in WSL2):
#
#   sudo apt-get update
#   sudo apt-get install -y git build-essential crossbuild-essential-arm64 \
#       bison flex libssl-dev libelf-dev u-boot-tools bc kmod cpio \
#       python3-pip python3-setuptools python3-wheel ninja-build \
#       debootstrap qemu-user-static
#
# USAGE:
#   1. Copy this whole directory into your target Linux system
#   2. Run: sudo bash build.sh
#   3. Output will be in armbian/build/output/images/
#
# NOTE: This script builds rootfs + kernel. Bootloader (lk2nd/aboot) must
#       be flashed separately using fastboot.
# ------------------------------------------------------------------------------

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARMBIAN_DIR="${SCRIPT_DIR}/armbian"
OUTPUT_DIR="${SCRIPT_DIR}/output"

echo "========================================================================"
echo "  UFI003 (MSM8916) Armbian Image Builder"
echo "========================================================================"

# 1. Clone Armbian build framework
if [ ! -d "${ARMBIAN_DIR}" ]; then
    echo "[1/5] Cloning Armbian build framework..."
    git clone --depth 1 https://github.com/armbian/build.git "${ARMBIAN_DIR}"
else
    echo "[1/5] Armbian build framework already exists, updating..."
    cd "${ARMBIAN_DIR}"
    git pull --ff-only || true
fi

# 2. Copy our board/family configs into Armbian
echo "[2/5] Installing UFI003 board configuration..."

cp -v "${SCRIPT_DIR}/config/sources/families/msm8916.conf" \
    "${ARMBIAN_DIR}/config/sources/families/msm8916.conf"

cp -v "${SCRIPT_DIR}/config/boards/ufi003.csc" \
    "${ARMBIAN_DIR}/config/boards/ufi003.csc"

# 3. Start Armbian build
echo "[3/5] Starting Armbian build..."
echo ""
echo "Build configuration:"
echo "  BOARD=ufi003"
echo "  BOARDFAMILY=msm8916"
echo "  BRANCH=edge (kernel 7.x mainline)"
echo "  RELEASE=trixie (Debian 13)"
echo ""

cd "${ARMBIAN_DIR}"

# First run does dependency installation (requires sudo)
./compile.sh BOARD=ufi003 \
    BRANCH=edge \
    RELEASE=trixie \
    BUILD_MINIMAL=yes \
    KERNEL_CONFIGURE=no \
    BOARD_FIRMWARE_INSTALL="-full" \
    EXPERT=no

BUILD_RESULT=$?

if [ ${BUILD_RESULT} -ne 0 ]; then
    echo ""
    echo "⚠️  Build failed with exit code ${BUILD_RESULT}"
    echo ""
    echo "Common issues:"
    echo "  - Missing build dependencies: run ./compile.sh once as root"
    echo "  - Kernel download failures: check network connectivity"
    echo "  - Disk space: need ~50GB free"
    echo ""
    exit ${BUILD_RESULT}
fi

# 4. Copy output
echo "[4/5] Collecting build artifacts..."
mkdir -p "${OUTPUT_DIR}"
find "${ARMBIAN_DIR}/output" -name "*.img" -o -name "*.xz" | while read -r f; do
    echo "  -> ${f}"
done

echo ""
echo "[5/5] Build complete!"
echo ""
echo "========================================================================"
echo "  NEXT STEPS"
echo "========================================================================"
echo ""
echo "1. The build produces a rootfs.img suitable for fastboot flashing."
echo "   You also need to prepare boot.img (kernel + DTB + initrd):"
echo ""
echo "   # boot.img creation (requires mkbootimg):"
echo "   mkbootimg \\"
echo "     --kernel arch/arm64/boot/Image \\"
echo "     --dtb arch/arm64/boot/dts/qcom/msm8916-thwc-ufi001c.dtb \\"
echo "     --ramdisk initrd.img \\"
echo "     --cmdline 'console=ttyMSM0,115200 root=/dev/disk/by-partlabel/rootfs rootwait' \\"
echo "     --base 0x80000000 \\"
echo "     --kernel_offset 0x8000 \\"
echo "     -o boot.img"
echo ""
echo "2. Flash to device (on Windows, use fastboot from Android SDK):"
echo ""
echo "   adb reboot bootloader"
echo "   fastboot flash boot boot.img"
echo "   fastboot flash rootfs rootfs.img"
echo "   fastboot reboot"
echo ""
echo "3. IMPORTANT: Install modem firmware from original device dump!"
echo "   See /root/MODEM_FIRMWARE_README.txt on the booted system."
echo ""
echo "4. SSH in via USB RNDIS (IP: 192.168.200.1 typically) or WiFi AP."
echo ""
echo "========================================================================"

exit 0
