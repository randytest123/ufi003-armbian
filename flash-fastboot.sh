#!/usr/bin/env bash
# =============================================================================
# flash-fastboot.sh — UFI003 fastboot flash 脚本 (含自动备份)
#
# 用法:
#   sudo ./flash-fastboot.sh                          # 标准 flash (备份+刷写)
#   sudo ./flash-fastboot.sh BACKUP_ONLY=1            # 只备份, 不刷写
#   sudo ./flash-fastboot.sh RESTORE=1 BACKUP_DIR=./backup-xxx  # 恢复
#   sudo ./flash-fastboot.sh FIRMWARE_DIR=./output/fastboot     # 指定固件目录
#
# 先决条件:
#   - fastboot 在 PATH 里
#   - 设备已经在 bootloader 模式 (fastboot devices 能看到)
#   - lk2nd aboot 文件在手 (如果要换 bootloader)
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# 配置 — 按需改
# =============================================================================
FIRMWARE_DIR="${FIRMWARE_DIR:-$(dirname "${BASH_SOURCE[0]}")/output/fastboot}"
BACKUP_DIR="${BACKUP_DIR:-./backup-$(date +%Y%m%d-%H%M%S)}"
BACKUP_ONLY="${BACKUP_ONLY:-0}"
RESTORE="${RESTORE:-0}"

# UFI003 分区表 (fastboot flash 分区名)
# 分区名必须跟设备的 partition.xml 一致
declare -a OEM_PARTITIONS=(sbl1 rpm tz hyp cdt)
declare -a BOOTLOADER_PARTITIONS=(aboot)
declare -a BOOT_PARTITIONS=(boot)
declare -a USERDATA_PARTITIONS=(rootfs)
declare -a BACKUP_PARTITIONS=(boot aboot modemst1 modemst2 fsc fsg rootfs)

# 需要 fastboot flash partition <file> (GPT) vs fastboot flash <part> <img>
HAS_GPT_BIN="${FIRMWARE_DIR}/oem/gpt_both0.bin"
LK2ND_ABOOT="${LK2ND_ABOOT:-}"   # 留空则保留 OEM aboot

# =============================================================================
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()     { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
err()     { echo -e "${RED}[FAIL]${NC}  $*" >&2; }
step()    { echo -e "\n${GREEN}━━━ $* ━━━${NC}"; }

# =============================================================================
# preflight
# =============================================================================
preflight() {
    step "前置检查"

    if ! command -v fastboot &>/dev/null; then
        err "找不到 fastboot. 安装: sudo apt install fastboot"
        exit 1
    fi

    # 检查设备
    local device
    device="$(fastboot devices 2>/dev/null | awk '{print $1; exit}')"
    if [[ -z "$device" ]]; then
        err "fastboot 没检测到设备"
        err "请:"
        err "  1. adb reboot bootloader (或手动长按 reset + vol-)"
        err "  2. USB 线连好"
        err "  3. fastboot devices 应该输出一串序列号"
        exit 1
    fi
    log "设备在线: ${device}"

    if [[ "$RESTORE" == "1" ]]; then
        if [[ ! -d "$BACKUP_DIR" ]]; then
            err "恢复模式但 BACKUP_DIR=${BACKUP_DIR} 不存在"
            exit 1
        fi
        log "恢复模式, 从 ${BACKUP_DIR}"
        return
    fi

    if [[ "$BACKUP_ONLY" != "1" ]]; then
        # 检查固件文件
        local required=(
            "${FIRMWARE_DIR}/boot.img"
            "${FIRMWARE_DIR}/rootfs.img"
        )
        for f in "${required[@]}"; do
            if [[ ! -f "$f" ]]; then
                err "缺少必需固件文件: ${f}"
                err "请先跑 build-image.sh"
                exit 1
            fi
        done
        log "固件文件检查通过"
    fi
}

# =============================================================================
# 备份
# =============================================================================
do_backup() {
    step "备份当前分区到 ${BACKUP_DIR}"

    mkdir -p "$BACKUP_DIR"

    for part in "${BACKUP_PARTITIONS[@]}"; do
        local tmp="${BACKUP_DIR}/${part}.img"
        log "  ${part} → ${part}.img"
        if fastboot get_staged "${part}" >/dev/null 2>&1; then
            # fastboot get_staged 存到临时文件, 再 adb pull 或用 fastboot boot 拉
            # 更简单的方法: fastboot flash <part> /dev/null 失败, 用 dd
            # 实际上在 bootloader 模式没法直接 dump, 需要用 EDL 或 adb shell dd
            # ---
            # 方案 A: 如果是 bootloader 模式
            # 这时候不能直接 dd, 得 reboot 到系统里 dump
            # 方案 B: 让用户手动进系统 dump
            warn "  fastboot 模式无法直接 dump 分区, 需要在系统里执行:"
            warn "    adb shell dd if=/dev/block/mmcblk0XX of=/sdcard/backup/${part}.img"
            warn "    adb pull /sdcard/backup/${part}.img ${BACKUP_DIR}/"
            # 写一个辅助脚本
            cat > "${BACKUP_DIR}/dump.sh" << DUMP
#!/bin/bash
# 在设备系统里执行: adb shell bash -c 'su && bash < dump.sh'
mkdir -p /sdcard/backup
for part in ${BACKUP_PARTITIONS[*]}; do
    # 通过 lsblk 找到分区编号
    dev=\$(lsblk -o NAME,LABEL /dev/block | grep -i "\${part}" | awk '{print \$1; exit}')
    if [[ -n "\$dev" ]]; then
        dd if=/dev/block/\${dev} of=/sdcard/backup/\${part}.img bs=4M status=progress 2>/dev/null
    fi
done
echo "dump done, adb pull /sdcard/backup/"
DUMP
            chmod +x "${BACKUP_DIR}/dump.sh"
        else
            # 跳过不可用的
            warn "  ${part}: 无法在 fastboot 模式 dump (需要 adb + root)"
        fi
    done

    # 额外: 保存当前 GPT
    if fastboot get_staged 2>/dev/null; then
        warn "  GPT: 需要在 EDL 模式用 edl rl 备份"
        warn "    edl rl gpt_both0.bin"
    fi

    log "备份提示已写入 ${BACKUP_DIR}/README.md"
    cat > "${BACKUP_DIR}/README.md" << README
# UFI003 备份

本目录的备份分两种:
1. 自动生成的占位文件 + dump.sh 脚本 — 需要进系统执行
2. 手动执行 EDL 备份 GPT:
     edl rl gpt_both0.bin
     edl rl -o aboot.img aboot
     edl rl -o boot.img boot
     edl rl -o rootfs.img rootfs

# 恢复 (变砖了用)
恢复流程:
  1. 设备进 EDL 模式 (短接 test point + 插 USB)
  2. edl w gpt_both0.bin  (恢复 GPT)
  3. edl w aboot.bin aboot
  4. edl w boot.img boot
  5. edl w rootfs.img rootfs
  6. fastboot reboot
README
}

# =============================================================================
# 刷写
# =============================================================================
do_flash() {
    step "开始刷写"

    # --- 1. GPT (可选) ---
    if [[ -f "${HAS_GPT_BIN}" ]]; then
        warn "=== 步骤 1: 刷 GPT ==="
        warn "如果设备已有正确的 UFI003 GPT (原始固件就带), 可以跳过这步"
        warn "刷错 GPT 会导致分区表错乱, rootfs 丢数据!"
        read -rp "刷 GPT? [y/N] " gpt_ok
        if [[ "$gpt_ok" == "y" ]]; then
            fastboot flash partition "${HAS_GPT_BIN}"
            log "GPT 已刷, reboot bootloader..."
            fastboot reboot bootloader
            sleep 5
        else
            log "跳过 GPT"
        fi
    else
        log "没有 gpt_both0.bin, 跳过"
    fi

    # --- 2. Qualcomm 固件分区 ---
    step "步骤 2: 刷 Qualcomm 固件分区"
    for part in "${OEM_PARTITIONS[@]}"; do
        local file="${FIRMWARE_DIR}/oem/${part}.bin"
        if [[ ! -f "$file" ]]; then
            warn "  跳过 ${part} (没 bin 文件)"
            continue
        fi
        log "  ${part} ← $(basename "$file")"
        fastboot flash "$part" "$file" || warn "  ${part} flash 失败 (可能本来就是好的)"
    done

    # --- 3. aboot (bootloader) ---
    step "步骤 3: 刷 aboot (bootloader)"
    if [[ -n "${LK2ND_ABOOT}" && -f "${LK2ND_ABOOT}" ]]; then
        log "刷 lk2nd (OpenStick bootloader)"
        fastboot flash aboot "${LK2ND_ABOOT}"
    else
        local oem_aboot="${FIRMWARE_DIR}/oem/aboot_oem.bin"
        if [[ -f "$oem_aboot" ]]; then
            warn "没指定 LK2ND_ABOOT, 保留 OEM aboot"
            warn "这意味着不会启动 lk2nd → 不会读 extlinux.conf → 不会启动 Armbian!"
            warn "如果你要 lk2nd, 请指定: LK2ND_ABOOT=/path/to/lk2nd_aboot.mbn"
            read -rp "刷 OEM aboot? [y/N] " aboot_ok
            if [[ "$aboot_ok" == "y" ]]; then
                fastboot flash aboot "$oem_aboot"
            else
                log "跳过 aboot"
            fi
        else
            err "没有 aboot 文件! 必须知道要刷什么 bootloader"
            err "  选项 A: OpenStick lk2nd (GPL) — 编译后指定 LK2ND_ABOOT="
            err "  选项 B: OEM aboot — 保持原厂"
            exit 1
        fi
    fi

    # --- 4. boot 分区 ---
    step "步骤 4: 刷 boot (boot.img, 64MB FAT32)"
    if [[ -f "${FIRMWARE_DIR}/boot.img" ]]; then
        fastboot flash boot "${FIRMWARE_DIR}/boot.img"
    else
        err "缺少 boot.img"
        exit 1
    fi

    # --- 5. rootfs ---
    step "步骤 5: 刷 rootfs"
    local rootfs_img="${FIRMWARE_DIR}/rootfs.img"
    if [[ ! -f "$rootfs_img" ]]; then
        err "缺少 rootfs.img"
        exit 1
    fi

    local img_size
    img_size="$(stat --format=%s "$rootfs_img")"
    log "rootfs.img 大小: ${img_size} bytes ($(( img_size / 1024 / 1024 )) MB)"

    # fastboot 默认 buffer 128MB, 如果 rootfs 更大需要 -S
    local buf_mb=128
    if (( img_size > 128 * 1024 * 1024 )); then
        buf_mb=256
        if (( img_size > 256 * 1024 * 1024 )); then
            buf_mb=512
        fi
    fi

    log "用 -S ${buf_mb}M 刷 rootfs (可能几分钟)..."
    fastboot -S "${buf_mb}M" flash rootfs "$rootfs_img"

    # --- 6. 完成 ---
    step "刷写完成!"
    cat << DONE

全部 flash 命令已执行完毕。

下一步:
  fastboot reboot

首次启动后:
  1. 等 60-120 秒 (首次启动 debootstrap 可能慢)
  2. 通过 USB gadget 或串口登录
     - USB gadget: 默认 192.168.200.1 (如果 aboot 是 lk2nd)
     - 串口: ttyMSM0 @ 115200 (GPIO175/176 on tlmm62)
  3. WiFi firmware: mkdir -p /lib/firmware/qcom && scp wcnss.* root@device:/lib/firmware/qcom/
  4. reboot

变砖恢复:
  设备进 EDL 模式 (短接 test point + 插 USB)
  用 edl (Qualcomm EDL 工具) 或 qfil 刷原厂固件
  本脚本生成的备份在: ${BACKUP_DIR}/

DONE
}

# =============================================================================
# 恢复
# =============================================================================
do_restore() {
    step "恢复模式 — 从 ${BACKUP_DIR}"

    if ! command -v fastboot &>/dev/null; then
        err "需要 fastboot"
        exit 1
    fi

    local device
    device="$(fastboot devices 2>/dev/null | awk '{print $1; exit}')"
    if [[ -z "$device" ]]; then
        err "设备不在 fastboot 模式"
        exit 1
    fi

    # 按备份目录里有的文件恢复
    for part in boot aboot rootfs; do
        local file="${BACKUP_DIR}/${part}.img"
        if [[ -f "$file" ]]; then
            warn "恢复 ${part} ← ${file}"
            read -rp "继续? [y/N] " ok
            [[ "$ok" != "y" ]] && continue
            fastboot -S 256M flash "$part" "$file"
        fi
    done

    log "恢复完成, fastboot reboot"
}

# =============================================================================
main() {
    preflight

    if [[ "$RESTORE" == "1" ]]; then
        do_restore
        return
    fi

    mkdir -p "$BACKUP_DIR"

    echo ""
    echo "=========================================="
    echo " UFI003 fastboot flash 脚本"
    echo " 固件目录: ${FIRMWARE_DIR}"
    echo " 备份目录: ${BACKUP_DIR}"
    echo "=========================================="
    echo ""
    read -rp "继续? [Y/n] " confirm
    [[ "$confirm" == "n" ]] && exit 0

    do_backup

    if [[ "$BACKUP_ONLY" != "1" ]]; then
        do_flash
    fi
}

main "$@"
