#!/usr/bin/env bash
# =============================================================================
# flash-edl.sh — UFI003 EDL (Emergency Download Mode) 刷写
#
# EDL 是 Qualcomm 芯片级 bootloader, 在任何情况下都能进 (即使 aboot 坏了)
# 用法:
#   sudo ./flash-edl.sh                               # 标准刷写
#   sudo ./flash-edl.sh FULL_IMAGE=./output/edl/ufi003-full.img
#   sudo ./flash-edl.sh BACKUP=1                       # 备份当前设备
#
# 依赖: bkerler/edl (Python)
#   pip install edl
#   或: 从 https://github.com/bkerler/edl 安装
#
# 变砖了才用! 正常刷写用 flash-fastboot.sh
# =============================================================================
set -euo pipefail
IFS=$'\n\t'

FIRMWARE_DIR="${FIRMWARE_DIR:-$(dirname "${BASH_SOURCE[0]}")/output/fastboot}"
EDL_DIR="${EDL_DIR:-$(dirname "${BASH_SOURCE[0]}")/output/edl}"
BACKUP_DIR="${BACKUP_DIR:-./edl-backup-$(date +%Y%m%d-%H%M%S)}"
FULL_IMAGE="${FULL_IMAGE:-${EDL_DIR}/ufi003-full.img}"
BACKUP="${BACKUP:-0}"
SKIP_BOOTLOADER="${SKIP_BOOTLOADER:-0}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log()  { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC}  $*" >&2; }
err()  { echo -e "${RED}[FAIL]${NC}  $*" >&2; }
step() { echo -e "\n${GREEN}━━━ $* ━━━${NC}"; }

preflight() {
    step "EDL 环境检查"

    if ! command -v edl &>/dev/null; then
        err "找不到 edl 命令"
        err "安装:"
        err "  pip install edl"
        err "  或: git clone https://github.com/bkerler/edl && cd edl && pip install -e ."
        exit 1
    fi

    # EDL 设备自动检测 (USB VID=0x05c6, PID 变化)
    log "请让设备进入 EDL 模式:"
    echo "  1. 关机 (长按电源键 10 秒)"
    echo "  2. 按住音量下 (或短接 test point 到 GND)"
    echo "  3. 插入 USB 线"
    echo "  4. 松开音量下"
    echo ""
    echo "  或者用 adb reboot edl (如果系统还能起来)"
    echo ""
    read -rp "设备插好后回车"

    # 检测 EDL 设备
    if edl info 2>/dev/null; then
        log "EDL 设备已就绪"
    else
        warn "edl info 没检测到设备, 但继续尝试..."
    fi
}

do_backup() {
    step "EDL 备份 → ${BACKUP_DIR}"

    mkdir -p "$BACKUP_DIR"

    log "备份 GPT..."
    edl rl -o "${BACKUP_DIR}/gpt_both0.bin" gpt_both0.bin 2>/dev/null || {
        warn "edl rl 失败, 尝试备用命令"
        edl rl gpt_both0.bin -o "${BACKUP_DIR}/gpt_both0.bin" 2>/dev/null || true
    }

    # 备份关键分区
    for part in sbl1 rpm tz hyp cdt aboot boot modemst1 modemst2 fsc fsg rootfs; do
        log "  ${part}..."
        edl rl -o "${BACKUP_DIR}/${part}.img" "${part}" 2>/dev/null || {
            warn "    ${part} 备份失败 (可能不存在或太小)"
        }
    done

    log "备份完成 → ${BACKUP_DIR}/"
}

do_flash() {
    step "EDL 刷写"

    echo ""
    warn "═══════════════════════════════════════════"
    warn " EDL 刷写会直接覆盖 eMMC, 无法恢复!"
    warn " 请确认你要刷的文件是正确的"
    warn "═══════════════════════════════════════════"
    echo ""

    if [[ -f "${FULL_IMAGE}" ]]; then
        log "方案 A: 刷完整磁盘镜像 (ufi003-full.img)"
        log "  edl w ${FULL_IMAGE}"
        log "  刷完 reboot-bootloader"
        echo ""
        read -rp "确认刷完整磁盘镜像? [y/N] " ok
        [[ "$ok" != "y" ]] && { log "取消"; return; }

        edl w "${FULL_IMAGE}"
        log "完整镜像刷完, reboot bootloader..."
        edl reboot
        sleep 5
        log "应该已经进 bootloader 了"
        return
    fi

    # 方案 B: 按分区刷
    log "方案 B: 按分区刷"

    # 1. GPT
    if [[ -f "${FIRMWARE_DIR}/oem/gpt_both0.bin" ]]; then
        edl w "${FIRMWARE_DIR}/oem/gpt_both0.bin" gpt_both0.bin
    fi

    # 2. Qualcomm 固件
    for part in sbl1 rpm tz hyp cdt; do
        local file="${FIRMWARE_DIR}/oem/${part}.bin"
        [[ -f "$file" ]] && edl w "$file" "$part" || true
    done

    # 3. aboot (bootloader)
    if [[ "$SKIP_BOOTLOADER" != "1" ]]; then
        if [[ -n "${LK2ND_ABOOT:-}" && -f "${LK2ND_ABOOT}" ]]; then
            edl w "${LK2ND_ABOOT}" aboot
        elif [[ -f "${FIRMWARE_DIR}/oem/aboot_oem.bin" ]]; then
            edl w "${FIRMWARE_DIR}/oem/aboot_oem.bin" aboot
        else
            warn "跳过 aboot (没文件)"
        fi
    fi

    # 4. boot
    edl w "${FIRMWARE_DIR}/boot.img" boot

    # 5. rootfs
    edl w "${FIRMWARE_DIR}/rootfs.img" rootfs

    log "EDL 刷写完成, edl reboot..."
    edl reboot
}

main() {
    preflight

    if [[ "$BACKUP" == "1" ]]; then
        do_backup
        return
    fi

    do_flash
}

main "$@"
