#!/usr/bin/env bash
# =============================================================================
# verify-image.sh — UFI003 固件产物静态自检
#
# 构建完后跑这个脚本, 在不连真机的情况下尽可能多的静态检查:
#   ✓ boot.img: FAT32? 大小正确? 有 kernel/dtb/extlinux.conf?
#   ✓ rootfs.img: ext4? 有 /boot/Image? 有 dtb? extlinux.conf 正确?
#   ✓ 完整 disk img (如果有): GPT 分区布局正确?
#   ✓ fastboot flash 文件清单完整?
#   ✓ WiFi firmware 检查 (提醒)
#
# 用法: sudo ./verify-image.sh [FIRMWARE_DIR=...]
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

FIRMWARE_DIR="${FIRMWARE_DIR:-$(dirname "${BASH_SOURCE[0]}")/output/fastboot}"
EDL_DIR="${EDL_DIR:-$(dirname "${BASH_SOURCE[0]}")/output/edl}"
LOG_FILE="${LOG_FILE:-./verify-$(date +%Y%m%d-%H%M%S).log}"

# eMMC 大小, 必须与 build-image.sh 一致
EMMC_SECTORS="${EMMC_SECTORS:-8388608}"

# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
pass=0; fail=0; warn=0
check() {
    local desc="$1" cmd="$2"
    local msg
    if msg=$(eval "$cmd" 2>&1); then
        echo -e "  ${GREEN}✓${NC} ${desc}"
        pass=$((pass+1))
    else
        echo -e "  ${RED}✗${NC} ${desc}"
        [[ -n "$msg" ]] && echo -e "      ${RED}${msg}${NC}" | head -3
        fail=$((fail+1))
    fi
}
warn_msg() { echo -e "  ${YELLOW}!${NC} $*"; warn=$((warn+1)); }
section()  { echo -e "\n${GREEN}━━━ $* ━━━${NC}"; }

# =============================================================================
echo "UFI003 固件静态自检"
echo "Firmware dir: ${FIRMWARE_DIR}"
echo "EDL dir:      ${EDL_DIR}"
echo ""

# =============================================================================
section "0. 工具链检查 (用于挂载分析)"
check "kpartx 存在"        "command -v kpartx"
check "mount 存在"         "command -v mount"
check "file 存在"          "command -v file"
check "sgdisk 存在"        "command -v sgdisk"

# =============================================================================
section "1. 文件清单检查"

declare -a required=(
    "${FIRMWARE_DIR}/boot.img"
    "${FIRMWARE_DIR}/rootfs.img"
)
for f in "${required[@]}"; do
    if [[ -f "$f" ]]; then
        sz=$(stat --format=%s "$f")
        echo -e "  ${GREEN}✓${NC} $(basename "$f") ($(( sz/1024/1024 )) MB)"
        pass=$((pass+1))
    else
        echo -e "  ${RED}✗${NC} 缺失: $f"
        fail=$((fail+1))
    fi
done

# =============================================================================
section "2. boot.img 结构检查"

boot_img="${FIRMWARE_DIR}/boot.img"
if [[ -f "$boot_img" ]]; then
    # 大小必须 <= 64MB (boot 分区大小)
    sz=$(stat --format=%s "$boot_img")
    check "boot.img 大小 ≤ 64MB ($sz bytes)" "[ $sz -le 67108864 ]"
    check "boot.img 是 FAT32" "file \"$boot_img\" | grep -qi 'FAT'"

    # 挂载检查内部结构
    boot_tmp=$(mktemp -d /tmp/ufi003-boot-check-XXXXXX)
    boot_loop=$(losetup -fP --show "$boot_img" 2>/dev/null || true)
    if [[ -n "$boot_loop" ]]; then
        mount "$boot_loop" "$boot_tmp" 2>/dev/null && {
            check "boot.img 有 kernel (/Image)" "[ -f ${boot_tmp}/Image ]"
            check "boot.img 有 extlinux.conf" "[ -f ${boot_tmp}/extlinux/extlinux.conf ]"
            check "boot.img 有 dtb" "find ${boot_tmp} -name '*.dtb' -o -name '*.dtbo' | head -1 | grep -q dtb"

            # 检查 extlinux.conf 里的关键字段
            if [[ -f "${boot_tmp}/extlinux/extlinux.conf" ]]; then
                extlinux="${boot_tmp}/extlinux/extlinux.conf"
                check "extlinux.conf 有 PARTLABEL=rootfs" "grep -q 'PARTLABEL=rootfs' $extlinux"
                check "extlinux.conf 有 console=ttyMSM0" "grep -q 'console=ttyMSM0' $extlinux"
                check "extlinux.conf 有 no_framebuffer" "grep -q 'no_framebuffer' $extlinux"
            fi
            sync
            umount "$boot_tmp" 2>/dev/null || true
        }
        losetup -d "$boot_loop" 2>/dev/null || true
    else
        warn_msg "无法 losetup boot.img (可能没权限), 跳过内部结构检查"
    fi
    rmdir "$boot_tmp" 2>/dev/null || true
fi

# =============================================================================
section "3. rootfs.img 结构检查"

rootfs_img="${FIRMWARE_DIR}/rootfs.img"
if [[ -f "$rootfs_img" ]]; then
    check "rootfs.img 是 ext4" "file \"$rootfs_img\" | grep -qi 'ext4'"

    # 挂载 rootfs 检查
    rootfs_tmp=$(mktemp -d /tmp/ufi003-rootfs-check-XXXXXX)
    rootfs_loop=$(losetup -fP --show "$rootfs_img" 2>/dev/null || true)
    if [[ -n "$rootfs_loop" ]]; then
        rootfs_part="${rootfs_loop}p1"
        mount "$rootfs_part" "$rootfs_tmp" 2>/dev/null || mount "$rootfs_loop" "$rootfs_tmp" 2>/dev/null
        if mountpoint -q "$rootfs_tmp"; then
            check "rootfs 有 /sbin/init (systemd)" "[ -f ${rootfs_tmp}/sbin/init ]"
            check "rootfs 有 /etc/fstab"          "[ -f ${rootfs_tmp}/etc/fstab ]"
            check "rootfs 有 /boot 目录"           "[ -d ${rootfs_tmp}/boot ]"

            # 检查 /boot 里有 kernel image
            if [[ -d "${rootfs_tmp}/boot" ]]; then
                if find "${rootfs_tmp}/boot" -maxdepth 1 -name "Image" -o -name "vmlinuz*" 2>/dev/null | grep -q .; then
                    echo -e "  ${GREEN}✓${NC} /boot 里有 kernel"
                    pass=$((pass+1))
                else
                    echo -e "  ${RED}✗${NC} /boot 里没 kernel image!"
                    echo "      $(ls -la "${rootfs_tmp}/boot/" | head -10)"
                    fail=$((fail+1))
                fi
            fi

            # WiFi firmware 检查
            if [[ -f "${rootfs_tmp}/lib/firmware/qcom/wcnss.mdt" ]]; then
                echo -e "  ${GREEN}✓${NC} WiFi firmware 已在 /lib/firmware/qcom/"
                pass=$((pass+1))
            else
                warn_msg "rootfs 里没有 WiFi firmware (/lib/firmware/qcom/wcnss.mdt)"
                warn_msg "刷机后需要手动复制 wcnss.* 到设备"
            fi

            # systemd 默认 target
            check "rootfs 有 systemd default target (multi-user.target)" \
                  "[ -L ${rootfs_tmp}/etc/systemd/system/default.target ]"

            sync
            umount "$rootfs_tmp"
        fi
        losetup -d "$rootfs_loop" 2>/dev/null || true
    else
        warn_msg "无法 losetup rootfs.img"
    fi
    rmdir "$rootfs_tmp" 2>/dev/null || true
fi

# =============================================================================
section "4. EDL 完整磁盘镜像检查 (如果有)"

edl_img="${EDL_DIR}/ufi003-full.img"
if [[ -f "$edl_img" ]]; then
    sz=$(stat --format=%s "$edl_img")
    expected=$((EMMC_SECTORS * 512))
    check "ufi003-full.img 大小 == eMMC 大小 (${expected} bytes)" "[ $sz -eq $expected ]"

    check "磁盘镜像有 GPT (sgdisk verify)" "sgdisk -v \"$edl_img\" 2>&1 | grep -qi 'ok\|no problem'"

    # sgdisk -p 看分区表
    echo ""
    echo "  分区表:"
    sgdisk -p "$edl_img" 2>/dev/null | sed 's/^/    /' || true
    echo ""

    # 检查关键分区
    local_info=$(sgdisk -i 14 "$edl_img" 2>/dev/null | head -3 || true)
    check "rootfs 分区 (partition 14) 存在" "echo '$local_info' | grep -qi 'rootfs'"

    boot_info=$(sgdisk -i 12 "$edl_img" 2>/dev/null | head -3 || true)
    check "boot 分区 (partition 12) 存在" "echo '$boot_info' | grep -qi 'boot'"

    aboot_info=$(sgdisk -i 11 "$edl_img" 2>/dev/null | head -3 || true)
    check "aboot 分区 (partition 11) 存在" "echo '$aboot_info' | grep -qi 'aboot'"
else
    warn_msg "没有完整磁盘镜像, 跳过 GPT 检查"
fi

# =============================================================================
section "5. OEM 固件分区文件"

declare -a oem_required=(sbl1 rpm tz hyp cdt)
for name in "${oem_required[@]}"; do
    f="${FIRMWARE_DIR}/oem/${name}.bin"
    if [[ -f "$f" ]]; then
        echo -e "  ${GREEN}✓${NC} oem/${name}.bin ($(stat --format=%s "$f") bytes)"
        pass=$((pass+1))
    else
        warn_msg "缺少 oem/${name}.bin (如果用原始固件包就能补)"
    fi
done

# =============================================================================
section "6. WiFi firmware 位置 (必须手动复制)"

echo ""
warn_msg "WiFi firmware 是 Qualcomm 闭源, 需要手动从原始固件包复制"
warn_msg "位置: D:\\PerFiles\\suishenwifi\\msm8916\\ufi003-debian超频版\\一键替换基带文件\\modem\\"
warn_msg "文件: wcnss.b00 b01 b02 b04 b06 b09 b10 b11 wcnss.mdt"
warn_msg "刷机后: mkdir -p /lib/firmware/qcom && scp wcnss.* root@device:/lib/firmware/qcom/"
echo ""

# =============================================================================
# 总结
# =============================================================================
echo ""
echo "══════════════════════════════════════════════════"
echo "  自检完成: ${GREEN}✓ ${pass} pass${NC}, ${RED}✗ ${fail} fail${NC}, ${YELLOW}! ${warn} warn${NC}"
echo "══════════════════════════════════════════════════"

if (( fail > 0 )); then
    echo ""
    err "有 ${fail} 项检查失败, 请先解决再刷机!"
    exit 1
elif (( warn > 0 )); then
    echo ""
    warn "有 ${warn} 项警告, 刷前确认是否可接受 (WiFi firmware 是必补项)"
fi

echo ""
echo "如果全绿, 下一步: sudo ./flash-fastboot.sh 或 sudo ./flash-edl.sh"
