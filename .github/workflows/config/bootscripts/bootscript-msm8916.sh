#!/bin/bash
# ------------------------------------------------------------------------------
# Armbian bootscript for MSM8916 / OpenStick family — 无 modem 版
# 生成 lk2nd 使用的 /boot/extlinux/extlinux.conf
# ------------------------------------------------------------------------------
#
# 实测来源 (boot.img header):
#   cmdline = "earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e
#              console=ttyMSM0,115200 no_framebuffer=true rw"
#
# 我们用 PARTLABEL=rootfs 代替 PARTUUID (更稳, 因为新构建的 rootfs UUID 会变)
# 实测 DTB: qcom/msm8916-handsome-openstick-ufi003.dtb
#

# 读 Armbian 环境
if [ -f /boot/armbianEnv.txt ]; then
    . /boot/armbianEnv.txt
fi

# 默认 DTB — 可被 armbianEnv.txt 里的 fdtfile 覆盖
DTB_FILE="${fdtfile:-msm8916-handsome-openstick-ufi003.dtb}"
DTB_PATH="/boot/dtb/qcom/${DTB_FILE}"

# 如果用户指定了其他机型 (ufi001b/ufi001c/sp970/uz801), 改 armbianEnv.txt 的 fdtfile
ALL_OPENSTICK_DTBS=(
    "msm8916-handsome-openstick-ufi001b.dtb"
    "msm8916-handsome-openstick-ufi001c.dtb"
    "msm8916-handsome-openstick-ufi003.dtb"
    "msm8916-handsome-openstick-sp970.dtb"
    "msm8916-handsome-openstick-uz801.dtb"
)

# 内核命令行 — 无 modem 版基线
BASE_CMDLINE="earlycon root=/dev/disk/by-partlabel/rootfs console=ttyMSM0,115200 rootwait no_framebuffer=true rw"

# 如果 armbianEnv.txt 里有 extraargs, 追加上
if [ -n "${extraargs}" ]; then
    CMDLINE="${CMDLINE:-} ${extraargs}"
else
    CMDLINE="${BASE_CMDLINE}"
fi

# 如果 armbianEnv.txt 里有 bootparam, 追加上 (initramfs 用)
if [ -n "${bootparam}" ]; then
    CMDLINE="${CMDLINE} ${bootparam}"
fi

cat << EOF
# ============================================================================
# extlinux.conf — lk2nd bootloader (OpenStick)
# 自动生成: config/bootscripts/bootscript-msm8916.sh
# DTB:     ${DTB_FILE}
# ============================================================================

label Armbian
    kernel /boot/Image
    append ${CMDLINE}
    fdt ${DTB_PATH}
    initrd /boot/initrd.img

label Armbian (single user)
    kernel /boot/Image
    append ${CMDLINE} single
    fdt ${DTB_PATH}
    initrd /boot/initrd.img

# ============================================================================
# 如果设备上没有 extlinux.conf, lk2nd 会 fallback 到:
#   1. 读 boot header 里的 cmdline (如果 boot.img 是 Android boot 格式)
#   2. 从 dtb 的 chosen node 取 stdout-path
#   3. 如果是 fastboot boot / boot flash, fastboot 自己会传 cmdline
# ============================================================================
EOF
