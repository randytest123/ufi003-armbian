#!/usr/bin/env bash
# =============================================================================
# build-image.sh — 一键构建 UFI003 OpenStick (Armbian, 去 modem) 可烧录固件
#
# 运行环境: Ubuntu 22.04/24.04 或 Debian 12 (x86_64), 需要 root/sudo
# 首次运行: ~2-3 小时, 约 20GB 磁盘, 8GB+ RAM
#
# 用法:
#   sudo ./build-image.sh                        # 标准构建 (bookworm + 6.12)
#   sudo ./build-image.sh EDGE=1                 # edge 内核 (noble + 7.2)
#   sudo ./build-image.sh SKIP_ARMBIAN=1         # 跳过 Armbian, 直接镜像组装 (假设已有 rootfs.img)
#
# 输出:
#   output/
#     ├── fastboot/    ← fastboot flash 各分区 (boot.img + rootfs.img)
#     ├── edl/         ← EDL/QFIL 整盘镜像 (ufi003-full.img)
#     └── logs/        ← 构建日志
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# SECTION 0: 设备常量 — 从 UFI003 真实 GPT 解析 + 硬件实测 (不要改, 除非你验证过)
# =============================================================================

# eMMC 实际容量. 在真机上 cat /sys/block/mmcblk0/size 得到 sectors
# UFI003 批次不同容量不同. 这里用 4GB 作为默认, 真机验证后更新.
# 4GB = 8,388,608 sectors @ 512 bytes/sector
EMMC_SECTORS="${EMMC_SECTORS:-8388608}"

# UFI003 GPT 分区表 (从 gpt_both0.bin 解析). Qualcomm 固件分区是固定的, 不要改.
# 字段: name start_lba end_lba description
# end_lba = start + size_sectors - 1
declare -A PART_START PART_END PART_SIZE
set_gpt_partitions() {
    local -a info=(
        "cdt       131072    4"
        "sbl1      262144    1024"
        "rpm       263168    1024"
        "tz        264192    2048"
        "hyp       266240    1024"
        "sec       267264    32"
        "modemst1  267296    4096"
        "modemst2  271392    4096"
        "fsc       275488    2"
        "fsg       393216    4096"
        "aboot     524288    2048"
        "boot      526336    131072"
        "devinfo   657408    2048"
    )
    for entry in "${info[@]}"; do
        local name start size end
        read -r name start size <<<"$entry"
        end=$((start + size - 1))
        PART_START[$name]=$start
        PART_SIZE[$name]=$size
        PART_END[$name]=$end
    done
    # rootfs 分区: 从 devinfo 结束后 (657408+2048=659456) 到 eMMC 末尾
    local LAST_SECTOR=$((EMMC_SECTORS - 1))
    local GPT_RESERVE=33   # 尾部 GPT backup + protective MBR
    PART_START[rootfs]=659456
    PART_SIZE[rootfs]=$((LAST_SECTOR - 659456 - GPT_RESERVE))
    PART_END[rootfs]=$((659456 + PART_SIZE[rootfs] - 1))
}
set_gpt_partitions

# boot 分区大小 (64MB, Armbian boot.img 必须 < 64MB)
BOOT_SECTORS="${PART_SIZE[boot]}"        # 131072 sectors
BOOT_BYTES=$((BOOT_SECTORS * 512))       # 67,108,864 bytes

# =============================================================================
# SECTION 1: 构建参数 — 按需覆盖
# =============================================================================

SKIP_ARMBIAN="${SKIP_ARMBIAN:-0}"
EDGE="${EDGE:-0}"

# 构建目录 (相对本脚本所在目录)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ARMHIAN_BUILD_DIR="${ARMHIAN_BUILD_DIR:-${SCRIPT_DIR}/armbian-build}"
OUTPUT_DIR="${OUTPUT_DIR:-${SCRIPT_DIR}/output}"
LOG_DIR="${OUTPUT_DIR}/logs"

# Armbian 参数
BOARD="ufi003"
if [[ "$EDGE" == "1" ]]; then
    BRANCH="edge"
    RELEASE="noble"
else
    BRANCH="current"
    RELEASE="bookworm"
fi
BUILD_MINIMAL="yes"
COMPRESS_OUTPUTIMAGE="xz"

# 原始固件包路径 (可选, 用于提取 bootloader + WiFi firmware)
FIRMWARE_DIR="${FIRMWARE_DIR:-}"
if [[ -z "$FIRMWARE_DIR" ]]; then
    FIRMWARE_DIR="${SCRIPT_DIR}/firmware-source"
fi

# lk2nd bootloader 路径 — 如果不指定, 用 OpenStick community 的预编译版
# 也可以让用户指定自己编译的
LK2ND_ABOOT="${LK2ND_ABOOT:-}"

# 原始 Qualcomm 固件分区文件 (从固件包的 bin/ 目录)
# 这些是刷机时要保留的原厂文件
declare -A OEM_PART_FILES
OEM_PART_FILES=(
    [sbl1]="${FIRMWARE_DIR}/bin/sbl1.mbn"
    [rpm]="${FIRMWARE_DIR}/bin/rpm.mbn"
    [tz]="${FIRMWARE_DIR}/bin/tz.mbn"
    [hyp]="${FIRMWARE_DIR}/bin/hyp.mbn"
    [cdt]="${FIRMWARE_DIR}/bin/sbc_1.0_8016.bin"
)

# =============================================================================
# SECTION 2: 颜色和日志
# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()     { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
err()     { echo -e "${RED}[FAIL]${NC}  $*" >&2; }
step()    { echo -e "\n${GREEN}━━━ $* ━━━${NC}"; }

# =============================================================================
# SECTION 3: 依赖检查 (只检查, 不自动装)
# =============================================================================
check_env() {
    step "环境检查"

    if [[ "$EUID" -ne 0 ]]; then
        err "此脚本需要 root 权限 (Armbian build 需要挂载 loopback / debootstrap)"
        err "请用: sudo $0"
        exit 1
    fi

    local distro
    distro="$(. /etc/os-release && echo "${ID} ${VERSION_ID}")"
    log "检测到: ${distro}"

    local missing=()
    local -A dep_map=(
        [git]="git"
        [bc]="bc"
        [jq]="jq"
        [curl]="curl"
        [xz]="xz-utils"
        [rsync]="rsync"
        [lz4]="lz4"
        [python3]="python3"
        [python3_pyelftools]="python3-pyelftools"
        [device_tree_compiler]="device-tree-compiler"
        [kpartx]="kpartx"
        [sgdisk]="gdisk"
        [mkfs_ext4]="e2fsprogs"
        [ddrescue]="ddrescue"
    )

    for cmd in git bc jq curl xz rsync lz4 python3 kpartx sgdisk; do
        if ! command -v "$cmd" &>/dev/null; then
            local pkg="${dep_map[$cmd]}"
            missing+=("$pkg")
            warn "缺失: $cmd (pkg: $pkg)"
        fi
    done

    if ! python3 -c "import elftools" 2>/dev/null; then
        missing+=("python3-pyelftools")
        warn "缺失: python3-pyelftools"
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        err "缺失依赖, 请先执行:"
        echo ""
        echo "    sudo apt update && sudo apt install -y ${missing[*]}"
        echo ""
        err "上面命令装完后再跑本脚本."
        exit 1
    fi

    # 检查磁盘空间
    local avail
    avail="$(df -BG "${SCRIPT_DIR}" | tail -1 | awk '{print $4}' | tr -d 'G')"
    if [[ "$avail" -lt 20 ]]; then
        err "当前磁盘仅剩 ${avail}GB, 至少需要 20GB"
        exit 1
    fi
    log "磁盘空间: ${avail}GB available (OK)"

    # 检查 RAM
    local mem
    mem="$(grep MemTotal /proc/meminfo | awk '{print $2}')"
    mem=$((mem / 1024))  # MB
    if [[ "$mem" -lt 4096 ]]; then
        warn "RAM 仅 ${mem}MB, 编译内核可能 OOM. 建议 8GB+"
    fi

    log "环境检查通过"
}

# =============================================================================
# SECTION 4: 准备 Armbian build 框架
# =============================================================================
prepare_armbian() {
    step "准备 Armbian build 框架"

    if [[ -d "${ARMHIAN_BUILD_DIR}/cache" ]]; then
        log "Armbian build 框架已存在, 增量构建"
    else
        log "浅克隆 Armbian build..."
        git clone --depth 1 --branch main https://github.com/armbian/build.git \
            "${ARMHIAN_BUILD_DIR}"
    fi

    # 复制板子配置
    local -a copy_jobs=(
        "config/boards/ufi003.csc"
        "config/sources/families/msm8916.conf"
        "config/bootscripts/bootscript-msm8916.sh"
        "config/sections/msm8916.config"
        "userpatches/kernel/add-openstick-dts-ufi003-nomodem.patch"
    )

    for job in "${copy_jobs[@]}"; do
        local src="${SCRIPT_DIR}/${job}"
        local dst="${ARMHIAN_BUILD_DIR}/${job}"
        local dst_dir
        dst_dir="$(dirname "$dst")"
        if [[ -f "$src" ]]; then
            mkdir -p "$dst_dir"
            cp -v "$src" "$dst"
        else
            warn "源文件不存在, 跳过: ${src}"
        fi
    done

    # 检查 DTS 文件 (去 modem DTS 用于路线 B 备用)
    if [[ -f "${SCRIPT_DIR}/msm8916-handsome-openstick-ufi003-armbian.dts" ]]; then
        cp -v "${SCRIPT_DIR}/msm8916-handsome-openstick-ufi003-armbian.dts" \
            "${ARMHIAN_BUILD_DIR}/userpatches/"
    fi

    # 确保 userpatches/kernel 目录存在
    mkdir -p "${ARMHIAN_BUILD_DIR}/userpatches/kernel"

    log "Armbian 框架就绪"
}

# =============================================================================
# SECTION 5: 执行 Armbian compile.sh
# =============================================================================
run_armbian_build() {
    step "执行 Armbian compile.sh (BOARD=${BOARD} BRANCH=${BRANCH} RELEASE=${RELEASE})"

    mkdir -p "$LOG_DIR"
    local logfile="${LOG_DIR}/armbian-build-$(date +%Y%m%d-%H%M%S).log"

    cd "${ARMHIAN_BUILD_DIR}"

    # 打印命令但不自动开始 — 让用户确认
    cat << EOF
即将执行:
  sudo ./compile.sh \\
      BOARD=${BOARD} \\
      BRANCH=${BRANCH} \\
      RELEASE=${RELEASE} \\
      BUILD_MINIMAL=${BUILD_MINIMAL} \\
      KERNEL_CONFIGURE=no \\
      EXPERT=no \\
      COMPRESS_OUTPUTIMAGE=${COMPRESS_OUTPUTIMAGE} \\
      VERBOSE=yes

日志输出到: ${logfile}
EOF
    echo ""
    read -rp "继续? [Y/n] " confirm
    if [[ "$confirm" == "n" || "$confirm" == "N" ]]; then
        warn "用户取消. 可以手动 cd ${ARMHIAN_BUILD_DIR} && sudo ./compile.sh ..."
        return 1
    fi

    local start_time
    start_time="$(date +%s)"

    # 运行 compile.sh
    sudo ./compile.sh \
        BOARD="${BOARD}" \
        BRANCH="${BRANCH}" \
        RELEASE="${RELEASE}" \
        BUILD_MINIMAL="${BUILD_MINIMAL}" \
        KERNEL_CONFIGURE=no \
        EXPERT=no \
        COMPRESS_OUTPUTIMAGE="${COMPRESS_OUTPUTIMAGE}" \
        VERBOSE=yes 2>&1 | tee "$logfile"

    local rc=$?
    local elapsed=$(( $(date +%s) - start_time ))
    local minutes=$(( elapsed / 60 ))

    if [[ $rc -ne 0 ]]; then
        err "Armbian build 失败 (退出码 $rc), 耗时 ${minutes} 分钟"
        err "日志: ${logfile}"
        echo ""
        echo "常见原因和解决方法:"
        echo "  1. kernel patch apply 失败"
        echo "     cd ${ARMHIAN_BUILD_DIR}/cache/sources/linux-*"
        echo "     git apply --check ../../../userpatches/kernel/*.patch"
        echo "  2. 缺 CONFIG_ 导致模块编译失败"
        echo "     查看上面生成的 msm8916.config 是否在 config/sections/ 里"
        echo "  3. rootfs 打包失败 (debootstrap 网络问题)"
        echo "     apt update && apt upgrade -y 然后重跑"
        echo ""
        exit $rc
    fi

    log "Armbian build 完成, 耗时 ${minutes} 分钟"
    return 0
}

# =============================================================================
# SECTION 6: 找到 Armbian 输出的 rootfs img
# =============================================================================
find_armbian_output() {
    log "定位 Armbian 输出..."

    local img
    img="$(find "${ARMHIAN_BUILD_DIR}/output/images" -name "Armbian_*Ufi003*.img" ! -name "*.xz" 2>/dev/null | head -1)"

    if [[ -z "$img" ]]; then
        # 可能是 .img.xz, 需要解压
        local xz_img
        xz_img="$(find "${ARMHIAN_BUILD_DIR}/output/images" -name "Armbian_*Ufi003*.img.xz" 2>/dev/null | head -1)"
        if [[ -n "$xz_img" ]]; then
            log "找到 .img.xz, 解压..."
            img="${xz_img%.xz}"
            sudo unxz -k "$xz_img"
        fi
    fi

    if [[ -z "$img" || ! -f "$img" ]]; then
        err "找不到 Armbian 输出的 rootfs .img"
        err "检查: ls ${ARMHIAN_BUILD_DIR}/output/images/"
        exit 1
    fi

    log "Armbian rootfs img: ${img} ($(du -h "$img" | cut -f1))"
    ARMBIAN_ROOTFS_IMG="$img"
}

# =============================================================================
# SECTION 7: 组装可烧录固件 (核心步骤)
# =============================================================================
assemble_firmware() {
    step "组装可烧录固件"

    local armbian_img="${ARMBIAN_ROOTFS_IMG:?ERROR: ARMBIAN_ROOTFS_IMG not set}"

    # 输出目录
    rm -rf "${OUTPUT_DIR}/fastboot" "${OUTPUT_DIR}/edl"
    mkdir -p "${OUTPUT_DIR}/fastboot" "${OUTPUT_DIR}/edl" "${OUTPUT_DIR}/boot"

    # --- 7a. 生成 boot.img (boot 分区内容) ---
    assemble_boot_img

    # --- 7b. rootfs 直接用 Armbian 输出 ---
    cp -v "$armbian_img" "${OUTPUT_DIR}/fastboot/rootfs.img"
    cp -v "$armbian_img" "${OUTPUT_DIR}/boot/rootfs.img"

    # --- 7c. 完整 EDL 磁盘镜像 ---
    build_full_disk_image

    # --- 7d. 复制 Qualcomm 固件分区文件 ---
    copy_oem_firmware

    log "固件组装完成, 输出在: ${OUTPUT_DIR}/"
}

assemble_boot_img() {
    log "构建 boot.img (FAT32, 装 extlinux.conf + kernel + dtb + initrd)"

    # boot.img 是一个 FAT32 镜像, 大小必须 == BOOT_BYTES (64MB)
    # lk2nd 从 boot 分区读这个 FAT, 找 extlinux.conf
    local boot_img="${OUTPUT_DIR}/fastboot/boot.img"
    local boot_tmp
    boot_tmp="$(mktemp -d /tmp/ufi003-boot-XXXXXX)"

    # 创建 64MB FAT32 镜像
    dd if=/dev/zero of="$boot_img" bs=1M count=64 status=none
    mkfs.fat -F 32 -n UFI003_BOOT "$boot_img" >/dev/null 2>&1

    # 挂载
    local boot_mount="/mnt/ufi003-boot"
    mkdir -p "$boot_mount"
    mount -o loop "$boot_img" "$boot_mount"

    # 从 Armbian rootfs 里提取 kernel/dtb/initrd
    local rootfs_loop
    rootfs_loop="$(losetup -fP --show "${OUTPUT_DIR}/boot/rootfs.img")" || {
        err "losetup rootfs 失败"
        umount "$boot_mount"
        losetup -d "$rootfs_loop" 2>/dev/null || true
        rmdir "$boot_mount" || true
        return 1
    }
    local rootfs_part="${rootfs_loop}p1"
    mkdir -p /mnt/ufi003-root
    mount "${rootfs_loop}p1" /mnt/ufi003-root 2>/dev/null || mount "${rootfs_loop}" /mnt/ufi003-root

    # 复制 kernel (lk2nd 找 /boot/Image)
    local version
    version="$(ls /mnt/ufi003-root/boot/ | grep -E "^vmlinuz-" | head -1 | sed 's/^vmlinuz-//')"
    if [[ -n "$version" ]]; then
        cp -v "/mnt/ufi003-root/boot/vmlinuz-${version}" "${boot_mount}/Image"
        cp -v "/mnt/ufi003-root/boot/initrd.img-${version}" "${boot_mount}/initrd.img"
    else
        # Armbian 用 /boot/Image (不是 vmlinuz-*)
        if [[ -f /mnt/ufi003-root/boot/Image ]]; then
            cp -v /mnt/ufi003-root/boot/Image "${boot_mount}/Image"
            cp -v /mnt/ufi003-root/boot/initrd.img "${boot_mount}/initrd.img" 2>/dev/null || true
        else
            err "在 rootfs /boot 里找不到 kernel Image!"
            ls -la /mnt/ufi003-root/boot/
            umount /mnt/ufi003-root
            umount "$boot_mount"
            losetup -d "$rootfs_loop" 2>/dev/null || true
            return 1
        fi
    fi

    # 复制 DTB
    mkdir -p "${boot_mount}/dtb/qcom"
    local dtb_file
    dtb_file="$(find /mnt/ufi003-root -name "msm8916-handsome-openstick-ufi003*.dtb" 2>/dev/null | head -1)"
    if [[ -n "$dtb_file" ]]; then
        cp -v "$dtb_file" "${boot_mount}/dtb/qcom/"
    else
        # 找其他 msm8916 dtb 先顶上
        dtb_file="$(find /mnt/ufi003-root -path "*/dtb/qcom/*.dtb" -name "msm8916*.dtb" 2>/dev/null | head -1)"
        if [[ -n "$dtb_file" ]]; then
            cp -v "$dtb_file" "${boot_mount}/dtb/qcom/"
            warn "找到 ${dtb_file}, 确认是不是 openstick 版"
        else
            warn "rootfs 里找不到 msm8916 dtb, 稍后手动补"
        fi
    fi

    # 生成 extlinux.conf
    local dtb_basename
    dtb_basename="$(basename "${dtb_file:-msm8916-handsome-openstick-ufi003.dtb}")"
    mkdir -p "${boot_mount}/extlinux"
    cat > "${boot_mount}/extlinux/extlinux.conf" << EOF
# extlinux.conf — UFI003 OpenStick (无 modem Armbian)
# lk2nd bootloader 会直接读取此文件

label Armbian
    kernel /Image
    initrd /initrd.img
    fdt /dtb/qcom/${dtb_basename}
    append earlycon root=/dev/disk/by-partlabel/rootfs console=ttyMSM0,115200 rootwait no_framebuffer=true rw

label Armbian (rescue)
    kernel /Image
    initrd /initrd.img
    fdt /dtb/qcom/${dtb_basename}
    append earlycon root=/dev/disk/by-partlabel/rootfs console=ttyMSM0,115200 rootwait no_framebuffer=true rw single
EOF

    # WiFi firmware 检查 (提醒用户手动复制)
    if [[ ! -f /mnt/ufi003-root/lib/firmware/qcom/wcnss.mdt ]]; then
        warn "rootfs 里没有 WiFi firmware (/lib/firmware/qcom/wcnss.mdt)"
        warn "刷机后需要手动复制 wcnss.b* + wcnss.mdt 到 /lib/firmware/qcom/"
    fi

    sync
    umount "${rootfs_loop}p1" 2>/dev/null || umount "$rootfs_loop"
    umount "$boot_mount"
    losetup -d "$rootfs_loop" 2>/dev/null || true
    rmdir "$boot_tmp" "$boot_mount" /mnt/ufi003-root 2>/dev/null || true

    log "boot.img 大小: $(du -h "$boot_img" | cut -f1)"
}

build_full_disk_image() {
    log "构建完整 EDL 磁盘镜像 (含 GPT + 所有分区)"

    local edl_img="${OUTPUT_DIR}/edl/ufi003-full.img"
    local total_bytes=$((EMMC_SECTORS * 512))
    local start_sec
    local offset_bytes

    # 创建与 eMMC 同大小的空镜像
    log "创建 ${total_bytes} bytes (=$((total_bytes/1024/1024/1024)) GiB) 磁盘镜像..."
    dd if=/dev/zero of="$edl_img" bs=1M count=$((EMMC_SECTORS * 512 / 1024 / 1024)) status=none

    # 写入 GPT (sgdisk)
    log "写入 GPT 分区表..."
    local -a sgdisk_args=(
        -Z            # 清空重建
        -n 1:131072:131075     -c 1:cdt
        -n 2:262144:263167     -c 2:sbl1
        -n 3:263168:264191     -c 3:rpm
        -n 4:264192:266239     -c 4:tz
        -n 5:266240:267263     -c 5:hyp
        -n 6:267264:267295     -c 6:sec
        -n 7:267296:271391     -c 7:modemst1
        -n 8:271392:275487     -c 8:modemst2
        -n 9:275488:275489     -c 9:fsc
        -n 10:393216:397311    -c 10:fsg
        -n 11:524288:526335    -c 11:aboot
        -n 12:526336:657407    -c 12:boot
        -n 13:657408:659455    -c 13:devinfo
        -n 14:659456:-34       -c 14:rootfs   # -34 = 末尾留 33 sectors 给 GPT backup + MBR
    )
    sgdisk "${sgdisk_args[@]}" "$edl_img" >/dev/null

    # 挂载并格式化 rootfs 分区, 然后写入内容
    local loop_dev
    loop_dev="$(losetup -fP --show "$edl_img")"
    log "磁盘镜像挂载为: ${loop_dev}"

    local rootfs_part="${loop_dev}p14"
    if [[ ! -b "$rootfs_part" ]]; then
        # 有时候 partition 编号不对, 找一下
        rootfs_part="$(ls -1 "${loop_dev}"* | grep -E 'p[0-9]+$' | tail -1)"
        warn "rootfs 分区猜测为: ${rootfs_part}"
    fi

    # 拷贝 bootloader 到对应分区 (如果有原始固件文件)
    flash_oem_to_loop "$loop_dev"

    # 格式化 rootfs 分区
    mkfs.ext4 -F -L rootfs "$rootfs_part" >/dev/null 2>&1
    log "rootfs 分区格式化完成"

    # 挂载 rootfs 并从 Armbian rootfs img 拷贝
    local rootfs_img_loop
    rootfs_img_loop="$(losetup -fP --show "${OUTPUT_DIR}/boot/rootfs.img")"
    local img_part="${rootfs_img_loop}p1"
    mkdir -p /mnt/ufi003-src /mnt/ufi003-dst
    mount "$img_part" /mnt/ufi003-src 2>/dev/null || mount "$rootfs_img_loop" /mnt/ufi003-src
    mount "$rootfs_part" /mnt/ufi003-dst

    log "拷贝 rootfs 文件 (rsync, 可能几分钟)..."
    sudo rsync -aAXH --info=progress2 /mnt/ufi003-src/ /mnt/ufi003-dst/
    log "rootfs 拷贝完成"

    # WiFi firmware 检查
    if [[ ! -f /mnt/ufi003-dst/lib/firmware/qcom/wcnss.mdt ]]; then
        warn "rootfs 里没有 WiFi firmware!"
        warn "刷机后需要: mkdir -p /lib/firmware/qcom && scp wcnss.* root@device:/lib/firmware/qcom/"
    fi

    # 写 fstab (确保 PARTLABEL=rootfs)
    cat > /mnt/ufi003-dst/etc/fstab << 'FSTAB'
# UFI003 Armbian /etc/fstab
PARTLABEL=rootfs / ext4 defaults,noatime,errors=remount-ro 0 1
proc /proc proc defaults 0 0
tmpfs /tmp tmpfs defaults,nosuid,nodev,size=512m 0 0
devtmpfs /dev devtmpfs defaults,mode=0755,nosuid 0 0
FSTAB

    sync
    umount /mnt/ufi003-dst
    umount /mnt/ufi003-src
    losetup -d "$rootfs_img_loop" 2>/dev/null || true

    # boot 分区: 直接把之前做好的 boot.img dd 进去
    local boot_part="${loop_dev}p12"
    log "boot 分区 ← boot.img (直接 dd, 跳过 mkfs — boot.img 自带 FAT32)"
    dd if="${OUTPUT_DIR}/fastboot/boot.img" of="$boot_part" bs=512 conv=notrunc status=none
    sync

    losetup -d "$loop_dev" 2>/dev/null || true
    rmdir /mnt/ufi003-src /mnt/ufi003-dst 2>/dev/null || true

    log "完整磁盘镜像: ${edl_img} ($(du -h "$edl_img" | cut -f1))"
}

flash_oem_to_loop() {
    local loop="$1"
    log "写入 Qualcomm 固件分区 (如果有原始文件)..."

    for part_name in sbl1 rpm tz hyp; do
        local file="${OEM_PART_FILES[$part_name]:-}"
        if [[ -n "$file" && -f "$file" ]]; then
            local part_dev
            part_dev="$(echo "${loop}" | sed 's/$//')"
            # 找到 partition 编号
            local part_num
            case "$part_name" in
                sbl1)   part_num=2 ;;
                rpm)    part_num=3 ;;
                tz)     part_num=4 ;;
                hyp)    part_num=5 ;;
            esac
            local part="${loop}p${part_num}"
            if [[ -b "$part" ]]; then
                log "  ${part_name} ← $(basename "$file")"
                dd if="$file" of="$part" bs=512 conv=notrunc status=none
            fi
        fi
    done

    # aboot 分区: 如果指定了 lk2nd 就刷 lk2nd, 否则保留 OEM
    local aboot_part="${loop}p11"
    if [[ -n "${LK2ND_ABOOT:-}" && -f "${LK2ND_ABOOT}" ]]; then
        log "  aboot ← lk2nd (OpenStick bootloader)"
        dd if="${LK2ND_ABOOT}" of="$aboot_part" bs=512 conv=notrunc status=none
    elif [[ -n "${OEM_PART_FILES[aboot]:-}" && -f "${OEM_PART_FILES[aboot]}" ]]; then
        log "  aboot ← OEM aboot.bin"
        dd if="${OEM_PART_FILES[aboot]}" of="$aboot_part" bs=512 conv=notrunc status=none
    else
        warn "  aboot 跳过 (没指定 LK2ND_ABOOT 也没 OEM aboot)"
    fi
}

copy_oem_firmware() {
    log "复制 OEM 固件分区文件到输出目录"

    mkdir -p "${OUTPUT_DIR}/fastboot/oem"
    for name in sbl1 rpm tz hyp cdt; do
        local file="${OEM_PART_FILES[$name]:-}"
        if [[ -n "$file" && -f "$file" ]]; then
            cp -v "$file" "${OUTPUT_DIR}/fastboot/oem/${name}.bin"
        else
            warn "缺少 OEM 文件 ${name} (期望在 ${FIRMWARE_DIR}/bin/)"
        fi
    done

    # 也放 OEM aboot
    local oem_aboot="${FIRMWARE_DIR}/bin/aboot.bin"
    if [[ -f "$oem_aboot" ]]; then
        cp -v "$oem_aboot" "${OUTPUT_DIR}/fastboot/oem/aboot_oem.bin"
    fi

    # 生成 fastboot flash 命令清单
    cat > "${OUTPUT_DIR}/fastboot/flash-firmware.sh" << 'FLASH'
#!/bin/bash
# fastboot flash 命令清单
# 刷前先在设备上: adb reboot bootloader
set -e

cd "$(dirname "$0")"

echo "=== Step 1: 刷 Qualcomm 固件分区 ==="
# GPT (可选, 如果设备已有正确 GPT 可跳过)
# fastboot flash partition oem/gpt_both0.bin

fastboot flash sbl1   oem/sbl1.bin
fastboot flash rpm    oem/rpm.bin
fastboot flash tz     oem/tz.bin
fastboot flash hyp    oem/hyp.bin
fastboot flash cdt    oem/cdt.bin

echo ""
echo "=== Step 2: 刷 bootloader ==="
# 用 lk2nd (OpenStick):
# fastboot flash aboot lk2nd_aboot.mbn
# 或用 OEM:
# fastboot flash aboot oem/aboot_oem.bin
echo "    请手动指定要刷的 aboot!"
echo "    fastboot flash aboot <your_aboot>.mbn"

echo ""
echo "=== Step 3: 刷 boot (boot.img, 64MB FAT32, 含 kernel+dtb+extlinux.conf) ==="
fastboot flash boot boot.img

echo ""
echo "=== Step 4: 刷 rootfs ==="
# rootfs 很大, 需要 -S 参数避免 fastboot buffer overflow
fastboot -S 256M flash rootfs rootfs.img

echo ""
echo "=== Step 5: 重启 ==="
echo "    fastboot reboot"
echo ""
echo "首次启动后记得:"
echo "  1. ssh 进去 (USB gadget 192.168.200.1 或串口)"
echo "  2. 复制 WiFi firmware: mkdir -p /lib/firmware/qcom && scp wcnss.* root@device:/lib/firmware/qcom/"
echo "  3. reboot"
FLASH
    chmod +x "${OUTPUT_DIR}/fastboot/flash-firmware.sh"
}

# =============================================================================
# SECTION 8: 打印使用说明
# =============================================================================
print_summary() {
    step "构建完成"

    cat << EOF
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
UFI003 Armbian (去 modem) 可烧录固件已生成
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

输出目录: ${OUTPUT_DIR}/

  fastboot/
    boot.img              ← boot 分区镜像 (64MB FAT32, lk2nd 读)
    rootfs.img            ← rootfs 分区镜像 (Armbian ext4)
    oem/                  ← Qualcomm 固件分区文件 (sbl1/rpm/tz/hyp/cdt)
    flash-firmware.sh     ← 一键 flash 脚本 (需手动指定 aboot)

  edl/
    ufi003-full.img       ← 完整磁盘镜像 (GPT + 所有分区, EDL 可刷)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

刷写步骤 (fastboot):
  1. 设备进 bootloader (adb reboot bootloader)
  2. cd ${OUTPUT_DIR}/fastboot/
  3. ./flash-firmware.sh
     (注意: 需要先拿到 lk2nd aboot, 替换 flash-firmware.sh 里那行)

WiFi firmware (必须手动补):
  原始固件包的一键替换基带文件/modem/ 里:
    wcnss.b00 b01 b02 b04 b06 b09 b10 b11 wcnss.mdt
  刷机后: mkdir -p /lib/firmware/qcom && scp wcnss.* root@device:/lib/firmware/qcom/

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

第一次跑 100% 会遇到的问题和排查:
  1. kernel patch apply 冲突
     cd armbian-build/cache/sources/linux-*
     git apply --check ../../../userpatches/kernel/*.patch
     如果是 modem.dtsi 位置变了 (主线 6.12 vs 5.10), 改 patch 里的 include 路径
  2. DTS 编不过
     路线 B 备选: dtc -I dts -O dtb -o dtb armbian-build/userpatches/*.dts
  3. fastboot flash rootfs 报 partition too small
     真机 eMMC 可能只有 4GB, 改 EMMC_SECTORS=8388608
     如果是 32GB, 设 EMMC_SECTORS=67108864
  4. 启动后 dmesg 里 modem PIL 还在跑
     DTS 里 status="disabled" 还不够, 在 kernel cmdline 加 qcom_pil.disable_modem=1
  5. WiFi 不起来
     确认 /lib/firmware/qcom/wcnss.mdt 存在
     dmesg | grep -i pronto, 看 firmware 是啥格式需求
     换驱动: modprobe -r wcn36xx && modprobe ath6kl_sdio

EOF
}

# =============================================================================
# SECTION 9: MAIN
# =============================================================================
main() {
    check_env

    if [[ "$SKIP_ARMBIAN" != "1" ]]; then
        prepare_armbian
        run_armbian_build || true   # 失败了也可以 SKIP_ARMBIAN=1 重跑组装
    fi

    find_armbian_output
    assemble_firmware
    print_summary
}

main "$@"
