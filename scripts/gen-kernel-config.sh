#!/usr/bin/env bash
# =============================================================================
# gen-kernel-config.sh — 生成完整的 Linux kernel .config
# 供 GitHub Actions 的 prepare 和 build 两个 job 调用
#
# 用法:
#   bash scripts/gen-kernel-config.sh \
#     --branch current \
#     --fragment config/sections/msm8916.config \
#     --output-dir armbian-build/userpatches/config/kernel \
#     [--also-output armbian-build/userpatches]
#
# 设计原则:
#   1. 主线 arm64 通用 defconfig (arch/arm64/configs/defconfig)
#      里的 qcom/WiFi/UART/eMMC/gpio/pinctrl 默认已开启足够多的选项.
#      我们的 fragment 只追加 少数 remoting/PIL/RPMSG/USB gadget 等
#      defconfig 没选的特定项.
#   2. make olddefconfig 统一填充默认值, 任何未知/过时的 CONFIG_=
#      选项会被自动改成 =n, 不会导致 .config 残缺.
#   3. 硬校验在 olddefconfig 之后:
#      - base 必选项 (defconfig 里直接有的, 如果没了说明内核版本变了)
#      - WiFi 关键项 (如果丢了, 设备开了也没用)
#      - CONFIG_ 总数下限 (空壳 config 直接 fail)
#   4. 任何校验失败都打印 FATAL: <符号名> 并 exit 1
#
# 符号名来源 (Linux v6.12 源码逐行确认):
#   arch/arm64/configs/defconfig    ← base defconfig 里已有的行号标注
#   drivers/remoteproc/Kconfig      ← QCOM_WCNSS_PIL, QCOM_Q6V5_ADSP, etc.
#   drivers/rpmsg/Kconfig           ← RPMSG_QCOM_SMD, RPMSG_QCOM_GLINK_SMEM
#   drivers/usb/gadget/Kconfig      ← USB_CONFIGFS, USB_CONFIGFS_RNDIS, USB_CONFIGFS_ACM
#
# 为什么不用 msm8916_defconfig?
#   主线 Linux arm64/configs/ 目录只有三个文件:
#     defconfig, hardening.config, virt.config
#   没有 msm8916_defconfig! Qualcomm msm8916 只是众多 qcom 板之一,
#   用通用 defconfig + fragment merge 是主线 arm64 的标准做法.
# =============================================================================
set -euo pipefail

# ---- 参数解析 ----
BRANCH=""
FRAGMENT=""
OUTPUT_DIRS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --branch)       BRANCH="$2"; shift 2 ;;
    --fragment)     FRAGMENT="$2"; shift 2 ;;
    --output-dir)   OUTPUT_DIRS+=("$2"); shift 2 ;;
    *)              echo "Unknown arg: $1"; exit 2 ;;
  esac
done

if [[ -z "$BRANCH" || ${#OUTPUT_DIRS[@]} -eq 0 ]]; then
  cat <<'USAGE'
Usage: gen-kernel-config.sh --branch <current|edge> --fragment <file> --output-dir <dir> [--output-dir <dir2> ...]
USAGE
  exit 2
fi

case "$BRANCH" in
  current) KVER="linux-6.12.y" ;;
  edge)    KVER="linux-7.2.y" ;;
  *)       echo "ERROR: unknown --branch: $BRANCH (expected current or edge)"; exit 2 ;;
esac

CONFIG_NAME="linux-msm8916-${BRANCH}.config"
WORK_DIR="$(mktemp -d /tmp/ufi003-kernel-config-XXXXXX)"

# Round 7: 宿主架构自适应.
#   ubuntu-24.04-arm (arm64) 上, HOSTARCH == ARCH == arm64, armbian 参考实现
#   (lib/functions/host/host-release.sh L15-16: amd64|arm64 都是 officially supported)
#   直接用原生 gcc, 不需要交叉工具链 — 也就没必要装 gcc-aarch64-linux-gnu.
#   x86_64 宿主仍按原样交叉编译.
CROSS=""
if [[ "$(uname -m)" != "aarch64" ]]; then
  CROSS="CROSS_COMPILE=aarch64-linux-gnu-"
fi
echo "  HOST_ARCH=$(uname -m)  CROSS=${CROSS:-native}"

echo "============================================================"
echo " gen-kernel-config.sh"
echo "   BRANCH=$BRANCH  KVER=$KVER  CONFIG_NAME=$CONFIG_NAME"
echo "   WORK_DIR=$WORK_DIR"
echo "   FRAGMENT=$FRAGMENT"
echo "============================================================"
echo ""

# =========================================================================
# Step 1: clone 主线内核
# =========================================================================
echo "=== Step 1/5: Clone kernel $KVER ==="
cd "$WORK_DIR"
rm -rf linux-src
if ! git clone --depth 1 --single-branch --branch "$KVER" \
    https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-src \
    2>&1 | tail -5; then
  echo "FATAL: kernel clone failed from git.kernel.org"
  exit 1
fi
cd linux-src
echo "  Clone OK: $(git rev-parse --short HEAD)  $(git log -1 --format='%ci')"
echo ""

# =========================================================================
# Step 2: make arm64 通用 defconfig (不是 msm8916_defconfig —— arm64 树里没有!)
# =========================================================================
echo "=== Step 2/5: make ARCH=arm64 defconfig ==="
if ! make ARCH=arm64 ${CROSS} defconfig > /tmp/make_defconfig.log 2>&1; then
  echo "FATAL: make defconfig FAILED!"
  echo "--- log (last 40 lines) ---"
  tail -40 /tmp/make_defconfig.log
  echo "--- end log ---"
  exit 1
fi
echo "  make defconfig OK"
echo ""

# =========================================================================
# Step 3: base defconfig 硬校验 (3 项, 全部在 v6.12 arm64 defconfig 里确认存在)
#   CONFIG_ARCH_QCOM=y     (L62, Qualcomm arch support — 一切的基础)
#   CONFIG_BLK_DEV_INITRD=y (L30, Armbian 需要 initrd)
#   CONFIG_EXT4_FS=y        (base defconfig 必有, rootfs 文件系统)
# =========================================================================
echo "=== Step 3/5: Base defconfig hard check (3 items) ==="
fail=0
for sym_val in \
    'CONFIG_ARCH_QCOM=y' \
    'CONFIG_BLK_DEV_INITRD=y' \
    'CONFIG_EXT4_FS=y'; do
  sym="${sym_val%=*}"
  val="${sym_val#*=}"
  if grep -q "^${sym}=${val}" .config; then
    echo "  OK:   ${sym}=${val}"
  else
    echo "  FATAL: ${sym}=${val} — NOT FOUND in base defconfig!"
    fail=1
  fi
done

if [[ $fail -ne 0 ]]; then
  echo ""
  echo "FATAL: Base arm64 defconfig is missing critical options!"
  echo "Check kernel version ($KVER) — base defconfig may have changed."
  echo "Current .config size: $(wc -l < .config) lines, $(grep -c '^CONFIG_' .config) CONFIG_ entries"
  exit 1
fi

echo "  Base config lines: $(wc -l < .config)"
echo "  CONFIG_ entries:    $(grep -c '^CONFIG_' .config)"
echo ""

# =========================================================================
# Step 4: merge fragment + make olddefconfig
# =========================================================================
echo "=== Step 4/5: Merge fragment + make olddefconfig ==="
if [[ -n "$FRAGMENT" && -f "$FRAGMENT" ]]; then
  echo "  Fragment file: $FRAGMENT ($(grep -cE '^CONFIG_[A-Z0-9_]+=(y|m|n)' "$FRAGMENT") valid CONFIG_ lines)"
  # 只追加 CONFIG_ 开头的有效三态配置行 (y/m/n)
  grep -E '^CONFIG_[A-Z0-9_]+=(y|m|n)' "$FRAGMENT" >> .config
else
  echo "  (No fragment provided or file not found)"
fi

# ---- Round 9: 强制关闭 EFI/EFI_STUB (Qualcomm aboot 只认裸 Image) ----
# base defconfig 里 CONFIG_EFI=y / CONFIG_EFI_STUB=y, 产出的 Image 是 PE/COFF
# 可执行文件 (首字节 'MZ'), aboot 搬到 0x80080000 直接非法指令复位.
# 这里先删掉 .config 里已有的同名行再追加 =n, 避免 Kconfig 的
# "override: reassigning to symbol" 重复赋值告警.
EFI_FORCE_OFF=(CONFIG_EFI CONFIG_EFI_STUB CONFIG_EFI_ARMSTUB CONFIG_EFI_ZBOOT)
for sym in "${EFI_FORCE_OFF[@]}"; do
  sed -i "/^${sym}=/d" .config 2>/dev/null || true
  echo "${sym}=n" >> .config
  echo "  Force-append: ${sym}=n"
done

echo "  Running make olddefconfig ..."
if ! make ARCH=arm64 ${CROSS} olddefconfig > /tmp/make_olddefconfig.log 2>&1; then
  echo "FATAL: make olddefconfig FAILED!"
  echo "--- log (last 40 lines) ---"
  tail -40 /tmp/make_olddefconfig.log
  echo "--- end log ---"
  exit 1
fi
echo "  olddefconfig OK"
echo ""

# =========================================================================
# Step 5: final hard check + print key option values
#
# 硬校验:
#   a) CONFIG_ARCH_QCOM=y       — QCOM arch (olddefconfig 后必须还在)
#   b) CONFIG_BLK_DEV_INITRD=y  — initrd (同上)
#   c) CONFIG_WCN36XX 必须 =m 或 =y — WiFi driver, 设备的命脉
#   d) CONFIG_ 总数 > 3000       — 空壳 config 直接 fail
#
# 打印 fragment 涉及的所有符号实际值 (人工核对用)
# =========================================================================
echo "=== Step 5/5: FINAL HARD CHECK + key option values ==="

final_lines=$(wc -l < .config)
final_count=$(grep -c '^CONFIG_' .config)
echo "  Final .config: ${final_lines} lines, ${final_count} CONFIG_ entries"

final_fail=0

# ---- 5a. CONFIG_ARCH_QCOM=y ----
if grep -q '^CONFIG_ARCH_QCOM=y' .config; then
  echo "  OK:   CONFIG_ARCH_QCOM=y"
else
  echo "  FATAL: CONFIG_ARCH_QCOM=y — LOST after olddefconfig!"
  final_fail=1
fi

# ---- 5b. CONFIG_BLK_DEV_INITRD=y ----
if grep -q '^CONFIG_BLK_DEV_INITRD=y' .config; then
  echo "  OK:   CONFIG_BLK_DEV_INITRD=y"
else
  echo "  FATAL: CONFIG_BLK_DEV_INITRD=y — LOST after olddefconfig!"
  final_fail=1
fi

# ---- 5c. CONFIG_WCN36XX 必须 =m 或 =y ----
wcn36xx_val=$(grep '^CONFIG_WCN36XX=' .config 2>/dev/null | cut -d= -f2 || echo "")
if [[ "$wcn36xx_val" == "m" || "$wcn36xx_val" == "y" ]]; then
  echo "  OK:   CONFIG_WCN36XX=${wcn36xx_val}  (WiFi driver — 命脉项!)"
else
  echo "  FATAL: CONFIG_WCN36XX is not enabled (val='${wcn36xx_val}')"
  echo "        WCN3620 WiFi is the primary wireless interface — cannot be disabled!"
  echo "        Check fragment: is CONFIG_WCN36XX=m present? Did olddefconfig reject it?"
  final_fail=1
fi

# ---- 5d. CONFIG_ 总数 > 3000 ----
if [[ $final_count -lt 3000 ]]; then
  echo "  FATAL: Only ${final_count} CONFIG_ entries (< 3000)!"
  echo "        This usually means make defconfig failed silently or wrong ARCH."
  echo "        Full .config (first 80 lines):"
  head -80 .config
  final_fail=1
else
  echo "  OK:   CONFIG_ count=${final_count} (> 3000)"
fi

# ---- 5e. Round 9: EFI 全部必须 =n (否则 Image 仍是 PE, aboot 必复位) ----
# Kconfig 对 =n 的输出形式是 "# CONFIG_X is not set", 也要认.
# 若符号在 .config 里彻底不存在 → 该内核分支没有这个符号 (例如 arm64 没有 EFI_ARMSTUB).
for sym in "${EFI_FORCE_OFF[@]}"; do
  if grep -qx "# ${sym} is not set" .config || grep -qx "${sym}=n" .config; then
    echo "  OK:   ${sym}=n"
    continue
  fi
  if grep -q "^${sym}=" .config; then
    val=$(grep "^${sym}=" .config | head -1 | cut -d= -f2)
    echo "  FATAL: ${sym}=${val} — 强制关闭失败!"
    # 找出谁 select 了它 (源码树就在当前 WORK_DIR 里)
    sel=$(grep -rn --include='Kconfig*' -E \
        "^[[:space:]]*select[[:space:]]+${sym#CONFIG_}([[:space:]]|$)" \
        arch drivers mm security init kernel 2>/dev/null | head -5 || true)
    if [[ -n "$sel" ]]; then
      echo "       被以下符号 select:"
      echo "$sel" | sed 's/^/         /'
    else
      echo "       未找到显式 select — 可能是 default y 或隐藏符号 (无 prompt)"
      grep -rn --include='Kconfig*' -E "^[[:space:]]*config[[:space:]]+${sym#CONFIG_}$" \
          arch drivers 2>/dev/null | head -5 | sed 's/^/         defined: /' || true
    fi
    final_fail=1
  else
    echo "  OK:   ${sym} absent (该内核分支没有这个符号)"
  fi
done

# ---- 打印 fragment 里提到的所有选项的实际值 ----
echo ""
echo "=== Key option actual values (human audit) ==="
audit_symbols=(
  "CONFIG_WCN36XX"                    # WiFi driver
  "CONFIG_REMOTEPROC"                 # PIL framework
  "CONFIG_QCOM_PIL_INFO"              # PIL info
  "CONFIG_QCOM_WCNSS_PIL"             # WCNSS PIL (load wcnss.b00~b11)
  "CONFIG_QCOM_Q6V5_ADSP"             # ADSP PIL
  "CONFIG_RPMSG_QCOM_SMD"             # SMD channel
  "CONFIG_RPMSG_QCOM_GLINK_SMEM"      # Glink SMEM channel
  "CONFIG_QCOM_SYSMON"                # sysmon (dependency of WCNSS_PIL)
  "CONFIG_QCOM_SMEM"                  # shared memory
  "CONFIG_USB_CONFIGFS"                # USB gadget configfs framework
  "CONFIG_USB_CONFIGFS_RNDIS"          # RNDIS gadget (Kconfig L248, no F_ prefix)
  "CONFIG_USB_CONFIGFS_ACM"            # ACM gadget (Kconfig L199, no F_ prefix)
  "CONFIG_REGULATOR_QCOM_SMD_RPM"     # SMD RPM regulators
  "CONFIG_SERIAL_MSM_CONSOLE"         # msm8916 UART console driver
  "CONFIG_SERIAL_QCOM_GENI_CONSOLE"   # GENI console (8996+)
  "CONFIG_PINCTRL_MSM8916"            # msm8916 pinctrl
  "CONFIG_MMC_SDHCI_PLTFM"            # eMMC controller
  "CONFIG_OVERLAY_FS"                 # overlayfs (Armbian needs)
  "CONFIG_EXTCON_GPIO"                # USB role detection
  "CONFIG_EFI"                         # Round 9: 必须 n (PE 头会导致 aboot 复位)
  "CONFIG_EFI_STUB"                    # Round 9: 必须 n
  "CONFIG_EFI_ARMSTUB"                 # Round 9: arm64 无此符号属正常
  "CONFIG_EFI_ZBOOT"                   # Round 9: 必须 n (否则 Image 是 EFI zboot 壳)
)
for sym in "${audit_symbols[@]}"; do
  if grep -q "^${sym}=" .config 2>/dev/null; then
    echo "  $(grep "^${sym}=" .config | head -1)"
  elif grep -qx "# ${sym} is not set" .config; then
    echo "  ${sym}=n"
  else
    echo "  ${sym}=(not set / not found)"
  fi
done

if [[ $final_fail -ne 0 ]]; then
  echo ""
  echo "FATAL: Final .config hard check FAILED! (exit code 1)"
  exit 1
fi

# =========================================================================
# Step 6: install 到所有目标目录
# =========================================================================
echo ""
echo "=== Step 6/6: Install .config ==="
for dir in "${OUTPUT_DIRS[@]}"; do
  mkdir -p "$dir"
  cp -v .config "${dir}/${CONFIG_NAME}"
  sz=$(stat -c%s "${dir}/${CONFIG_NAME}")
  echo "  Installed: ${dir}/${CONFIG_NAME}  (${sz} bytes)"
done

# 清理
cd /
rm -rf "$WORK_DIR"

echo ""
echo "============================================================"
echo " DONE: ${CONFIG_NAME}  (${final_count} CONFIG_ entries)"
echo "============================================================"
