#
# SPDX-License-Identifier: GPL-2.0
#
# UFI003 (OpenStick jsbsbxjxh66-bianyi) — Armbian 无 modem 版
# Qualcomm MSM8916 (Snapdragon 410) USB LTE  modem 棒 — 纯计算节点
#
# 实测硬件 (来源: boot.img 内嵌 DTB, 固件包逆向):
#   SoC:      Qualcomm MSM8916, ARM Cortex-A53 x4
#   RAM:      512MB (bootloader 探测, DTB reg size=0)
#   Storage:  4GB eMMC (sdhc1@7824000, 8-bit, non-removable, status=okay)
#   WiFi:     WCN3620 (pronto-v2-pil remoteproc@a21b000, iris compatible)
#   BT:       wcnss-bt (同上，同一块芯片)
#   SIM:      双卡 GPIO (tlmm block 62 pin 0/1/2/3) — 已禁用
#   Modem:    Qualcomm MDM mpss@4080000 — 已禁用 (无固件)
#   USB:      linux,extcon-usb-gpio (gpio110 active-high, role switch)
#   Reset:    gpio37 (tlmm block 62 pin 37, active-low)
#   LEDs:     blue:wifi(gpio20), green:internet(gpio21), red:os(gpio22)
#   UART:     blsp1_uart2 @ 0x78b0000 (serial console, 115200)
#   Audio:    disabled (dtb sound@7702000 status=disabled)
#   Display:  disabled (no video output, boot cmdline has no_framebuffer=true)
#
# 目标: 跑 Armbian 纯计算节点
#   ✓ WiFi/BT 可用 (WCN3620, 需要 firmware 放到 /lib/firmware/qcom/)
#   ✓ USB 2.0 OTG 可用 (extcon-usb-gpio, 可接网卡/U 盘)
#   ✓ USB gadget RNDIS/ACM 可让主机 SSH 进来
#   ✓ Reset 键可用
#   ✗ Modem/LTE — 禁用 (无闭源 firmware)
#   ✗ SIM 卡 — 禁用
#   ✗ 音频 — 禁用
#
# DTB (内核编译后):
#   arch/arm64/boot/dts/qcom/msm8916-handsome-openstick-ufi003.dtb
#   → 放到 /boot/dtb/qcom/
#
# 闭源 blob 需求评估 (无 modem 版):
#   需要保留在固件里但**不进公开仓库**的:
#     ✗ modem firmware — 不需要 (modem disabled)
#     ✗ fsc/fsg/modemst1/modemst2 — 不需要
#     ✓ WiFi firmware (wcnss.b00~b11 + wcnss.mdt) — **需要！** WCN3620 启动用
#       位置: 原始固件包 → 一键替换基带文件/modem/ (跟 modem 固件混在一起)
#   bootloader 侧 (刷机时 flash):
#     sbl1.mbn, hyp.mbn, rpm.mbn, tz.mbn — Qualcomm 闭源, 不进 rootfs
#     aboot.bin — 替换为 OpenStick lk2nd (GPL, 可进 rootfs 仓库)
#
declare -g BOARD_NAME="UFI003 OpenStick (no-modem)"
declare -g BOARD_VENDOR="handsome"
declare -g BOARD_MAINTAINER="community"
declare -g INTRODUCED="2024"
declare -g BOARDFAMILY="msm8916"
declare -g KERNEL_TARGET="edge"

# DTB 名称 (由 add-openstick-dts-ufi003-nomodem.patch 加入主线内核)
declare -g BOOT_FDT_FILE="qcom/msm8916-handsome-openstick-ufi003.dtb"

# 分区表: GPT (bin/gpt_both0.bin)
declare -g IMAGE_PARTITION_TABLE="gpt"

# bootscript.sh 生成 extlinux.conf (lk2nd bootloader 直接读)
declare -g BOOTCONFIG="none"
declare -g BOOTSIZE="512"
declare -g BOOTFS_TYPE="none"

# 实测 console: blsp1_uart2 → ttyMSM0 @ 0x78b0000
declare -g SERIALCON="ttyMSM0:115200"
declare -g DEFAULT_CONSOLE="serial"

# 内核命令行 (从 boot.img header 实测提取, 1.2GHz 和 2.1GHz 版完全一致)
# 我们用 PARTLABEL=rootfs 代替 PARTUUID (Armbian 新构建的 rootfs 分区 UUID 会变)
declare -g KERNEL_CMDLINE="earlycon root=/dev/disk/by-partlabel/rootfs console=ttyMSM0,115200 rootwait no_framebuffer=true rw"

# 视频输出: 无 (DTB mdss disabled + boot cmdline no_framebuffer=true)
declare -g HAS_VIDEO_OUTPUT="no"

# modem firmware: 完全不需要
declare -g BOARD_FIRMWARE_INSTALL="-none"

# 必须装 WiFi 驱动 + USB gadget 工具
declare -g PACKAGE_LIST_BOARD="wireless-tools iw hostapd wpa-supplicant usbutils"
declare -g PACKAGE_LIST_BOARD_REMOVE="avahi-daemon modemmanager ofono"

# CPU 频率 (基线, 不用超频 opp 表——超频增加电压后可能不稳定)
declare -g CPUMIN="400000"
declare -g CPUMAX="1200000"
declare -g GOVERNOR="schedutil"

# suspend 在 msm8916 上不稳定
declare -g POWER_MANAGEMENT_FEATURES="no"

# USB gadget — 让主机通过 USB 网线访问设备
function post_family_tweaks_bsp__ufi003_usb_gadget() {
	display_alert "UFI003" "Setting up USB gadget RNDIS+ACM" "info"

	mkdir -p "${SDCARD}/usr/local/bin" "${SDCARD}/etc/systemd/system"

	cat > "${SDCARD}/usr/local/bin/setup-usb-gadget.sh" <<- SETUP
		#!/bin/bash
		# UFI003 USB gadget — RNDIS (网络) + ACM (串口登录)
		# 依赖: gadget configfs, usb_f_rndis, usb_f_acm
		setup_gadget() {
			[ -d /sys/kernel/config/usb_gadget/msm8916 ] && exit 0
			modprobe configfs 2>/dev/null; modprobe usb_f_rndis 2>/dev/null; modprobe usb_f_acm 2>/dev/null
			mkdir -p /sys/kernel/config/usb_gadget/msm8916
			cd /sys/kernel/config/usb_gadget/msm8916
			echo 0x1d6b > idVendor; echo 0x0103 > idProduct; echo 0x0200 > bcdUSB
			mkdir -p strings/0x409
			echo "0123456789" > strings/0x409/serialnumber
			echo "Armbian"     > strings/0x409/manufacturer
			echo "UFI003"      > strings/0x409/product
			mkdir -p functions/rndis.usb0 functions/acm.usb1
			mkdir -p configs/c.1
			echo 0x80 > configs/c.1/bmAttributes; echo 150 > configs/c.1/MaxPower
			ln -sf functions/rndis.usb0 configs/c.1/
			ln -sf functions/acm.usb1 configs/c.1/
			UDC=$(ls /sys/class/udc/ 2>/dev/null | head -1)
			[ -n "${UDC}" ] && echo "${UDC}" > UDC
			sleep 1
			ip link set usb0 address 42:23:1f:1b:45:50 up 2>/dev/null
			# 给 USB 网卡分配 IP
			ip addr add 192.168.200.1/24 dev usb0 2>/dev/null
		}
		sleep 2; setup_gadget
	SETUP
	chmod +x "${SDCARD}/usr/local/bin/setup-usb-gadget.sh"

	cat > "${SDCARD}/etc/systemd/system/usb-gadget.service" <<- UNIT
		[Unit]
		Description=Setup USB RNDIS+ACM Gadget
		After=multi-user.target

		[Service]
		Type=oneshot
		ExecStart=/usr/local/bin/setup-usb-gadget.sh
		RemainAfterExit=yes

		[Install]
		WantedBy=multi-user.target
	UNIT

	run_host_command_logged chroot "${SDCARD}" systemctl enable usb-gadget.service
	display_alert "UFI003" "USB gadget enabled (host: 192.168.200.1)" "ok"
}

# WiFi firmware 安装说明 — 用户必须从原固件包复制
function post_family_tweaks_bsp__ufi003_wifi_firmware_readme() {
	display_alert "UFI003" "Writing WiFi firmware README" "info"

	cat > "${SDCARD}/root/WIFI_FIRMWARE_README.txt" <<- README
		=========================================
		UFI003 WiFi Firmware (WCN3620) Setup Guide
		=========================================

		UFI003 uses a WCN3620 WiFi/BT chip loaded by the pronto-v2-pil
		remoteproc. The firmware blobs are Qualcomm PIL format files
		(b00~b11 + .mdt) and must be present for WiFi to work.

		Step 1: Find the firmware in your original package
		------------------------------------------------
		位置: D:\PerFiles\suishenwifi\msm8916\ufi003-debian超频版\
		      一键替换基带文件\modem\
		里面有:
		  wcnss.b00 wcnss.b01 wcnss.b02 wcnss.b04 wcnss.b06
		  wcnss.b09 wcnss.b10 wcnss.b11 wcnss.mdt

		Step 2: Copy to running system
		------------------------------
		After flashing Armbian and booting:
		  mkdir -p /lib/firmware/qcom
		  # From the firmware package:
		  scp wcnss.b00 wcnss.b01 wcnss.b02 wcnss.b04 wcnss.b06 \
		      wcnss.b09 wcnss.b10 wcnss.b11 wcnss.mdt \
		      root@192.168.200.1:/lib/firmware/qcom/

		Step 3: Verify
		--------------
		  dmesg | grep -i wcnss      # should see "WCNSS firmware loaded"
		  lsmod | grep ath           # ath6kl or ath10k should load
		  ifconfig -a | grep wlan    # wlan0 should appear
		  iw dev wlan0 scan          # scan for APs

		Which driver?
		  - ath6kl_sdio: older, may need CONFIG_ATH6KL_SDIO
		  - wcn36xx:     newer, mainline 6.x uses this (CONFIG_WCN36XX)
		  Check dmesg to see which one your kernel loads.

		=========================================
		RED LINE: Do NOT commit these files to public repos.
		They are closed-source Qualcomm firmware.
		=========================================
	README

	display_alert "UFI003" "WiFi firmware README written to /root/" "ok"
}

# 基础网络配置 (第一次启动后 WiFi 固件到位才能用)
function post_family_tweaks_bsp__ufi003_network_defaults() {
	display_alert "UFI003" "Writing default network config" "info"

	cat > "${SDCARD}/etc/network/interfaces.d/wlan0" <<- WLAN
		auto wlan0
		iface wlan0 inet dhcp
		    wpa-conf /etc/wpa_supplicant/wpa_supplicant.conf
	WLAN

	display_alert "UFI003" "Default wlan0 dhcp config added" "ok"
}
