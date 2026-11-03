# Userpatches for Armbian UFI003 (去modem版)
# 放在 Armbian build 框架的 userpatches/kernel/ 目录下
# 主线内核的 DTS patch — 把 OpenStick 设备树加进去并默认禁用modem

KERNELPATCH:name="add-openstick-dts-ufi003-nomodem"
KERNELPATCH:desc="Adds all OpenStick device trees + UFI003 variant + disables modem by default (WiFi kept)"
KERNELPATCH:url="local"
KERNELPATCH:path="patches/kernel/add-openstick-dts-ufi003-nomodem.patch"
KERNELPATCH:branch="6.12"

# 下面是 patch 正文（可以直接用 git apply 或放在 userpatches/kernel/ 下）
# Patch 基于 HandsomeYingyan 2022-05-16 的主线 patch，做了以下改动：
#   1. 新增 ufi003.dts（从 ufi001c 复制，改 model + disable SIM LEDs）
#   2. common.dtsi 加 modem PIL disable + 保留 WiFi pronto
#   3. Makefile 加 ufi003 dtb 条目
#   4. 所有 SIM LED 设为 default-state = "off"（物理上可以不亮，但保留GPIO定义）
