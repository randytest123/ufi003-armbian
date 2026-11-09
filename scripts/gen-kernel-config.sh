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

# Round 12 fix: 记录启动时的 cwd, 并把 --fragment 转成绝对路径.
# 本脚本后面会 cd 到 mktemp 出来的内核源码树 (linux-src), 从 workflow 传进来的
# 相对路径 "config/sections/msm8916.config" 在那边根本不存在 —— 之前的版本
# 就是因此静默跳过 fragment, 导致所有钉住的 =y / VA_BITS=48 全部没生效.
SCRIPT_START_PWD="$PWD"
if [[ -n "$FRAGMENT" && "$FRAGMENT" != /* ]]; then
  FRAGMENT="$SCRIPT_START_PWD/$FRAGMENT"
fi

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
if [[ -n "$FRAGMENT" ]]; then
  if [[ ! -f "$FRAGMENT" ]]; then
    # 指定了 fragment 却找不到, 不能静默跳过 —— 否则等于用纯 defconfig 出包,
    # 所有钉住的选项 (USB 内建 / VA_BITS / -Os) 都不会生效, 而且下游看不出来.
    echo "  FATAL: --fragment 指定的文件不存在: $FRAGMENT"
    echo "         脚本启动 cwd = $SCRIPT_START_PWD"
    echo "         请确认 workflow 传的路径相对于仓库根目录真实存在."
    exit 2
  fi
  echo "  Fragment file: $FRAGMENT ($(grep -cE '^CONFIG_[A-Z0-9_]+=(y|m|n)' "$FRAGMENT") valid CONFIG_ lines)"
  # 只追加 CONFIG_ 开头的有效三态配置行 (y/m/n)
  grep -E '^CONFIG_[A-Z0-9_]+=(y|m|n)' "$FRAGMENT" >> .config
  echo "  Appended $(grep -cE '^CONFIG_[A-Z0-9_]+=(y|m|n)' "$FRAGMENT") fragment lines to .config"
else
  echo "  FATAL: 未指定 --fragment (本构建必须带 fragment)"
  exit 2
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

# ---- Round 12: 三态读取器 ----
# 区分 CONFIG_X=y / CONFIG_X=m / # CONFIG_X is not set (=n) / 符号根本不存在.
# 之前的 val=$(grep "^SYM=") 把 "is not set" 和 "不存在" 都当成空字符串,
# 报错时看不出到底是哪一种.
cfg_state() {
  local s="$1"
  if grep -qx "# ${s} is not set" .config 2>/dev/null; then echo "n"; return; fi
  local v
  v=$(grep "^${s}=" .config 2>/dev/null | head -1 | cut -d= -f2 || true)
  if [[ -n "$v" ]]; then echo "$v"; else echo "ABSENT"; fi
}

# 打印符号在 Kconfig 里的定义位置 (失败时附带)
kdef() {
  local s="${1#CONFIG_}"
  grep -rn --include='Kconfig*' -E "^[[:space:]]*config[[:space:]]+${s}$" \
      arch drivers mm security init kernel block net sound 2>/dev/null | head -3 || true
}

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
wcn36xx_val=$(cfg_state CONFIG_WCN36XX)
if [[ "$wcn36xx_val" == "m" || "$wcn36xx_val" == "y" ]]; then
  echo "  OK:   CONFIG_WCN36XX=${wcn36xx_val}  (WiFi driver — 命脉项!)"
else
  echo "  FATAL: CONFIG_WCN36XX 期望 y|m, 实际=${wcn36xx_val}"
  echo "        WCN3620 WiFi is the primary wireless interface — cannot be disabled!"
  kdef CONFIG_WCN36XX | sed 's/^/         defined: /'
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

# ---- 5f. Round 10: 瘦身后启动链硬校验 ----
# fragment 里写了 800+ 条 =n, 担心某个 select 把启动必需项连带关掉,
# 这里逐个确认 (y/m 都认, 缺失或 =n 直接 fail).
boot_critical=(
  "CONFIG_ARCH_QCOM"
  "CONFIG_BLK_DEV_INITRD"
  "CONFIG_EXT4_FS"
  "CONFIG_DEVTMPFS"
  "CONFIG_DEVTMPFS_MOUNT"
  "CONFIG_MMC_SDHCI_MSM"          # eMMC 控制器
  "CONFIG_SERIAL_MSM"             # earlycon / console
  "CONFIG_SERIAL_MSM_CONSOLE"
  "CONFIG_PINCTRL_MSM8916"
  "CONFIG_COMMON_CLK_QCOM"
  "CONFIG_MSM_GCC_8916"
  "CONFIG_QCOM_CLK_SMD_RPM"
  "CONFIG_QCOM_SMD_RPM"
  "CONFIG_QCOM_SMEM"
  "CONFIG_REGULATOR_QCOM_SMD_RPM"
  "CONFIG_REGULATOR_QCOM_SPMI"
  "CONFIG_MFD_SPMI_PMIC"
  "CONFIG_PINCTRL_QCOM_SPMI_PMIC"
  "CONFIG_USB_CHIPIDEA"           # msm8916 的 USB 是 ci-hdrc, 不是 dwc3
  "CONFIG_USB_GADGET"
  "CONFIG_USB_CONFIGFS"
  "CONFIG_USB_CONFIGFS_RNDIS"
  "CONFIG_USB_CONFIGFS_ACM"
  "CONFIG_QCOM_WCNSS_PIL"         # WiFi PIL
  "CONFIG_RPMSG_QCOM_SMD"
  "CONFIG_WCN36XX"                # WiFi driver
)
for sym in "${boot_critical[@]}"; do
  val=$(cfg_state "$sym")
  if [[ "$val" == "y" || "$val" == "m" ]]; then
    echo "  OK:   ${sym}=${val}"
  else
    echo "  FATAL: ${sym} 期望 y|m, 实际=${val} — 瘦身把启动必需项裁掉了!"
    kdef "$sym" | sed 's/^/         defined: /'
    final_fail=1
  fi
done
# ---- 5g. Round 11: USB 全内建 + arm64 位宽硬校验 (不允许静默降级) ----
# 目标: USB PHY / chipidea / gadget / configfs 全部 =y, 不依赖 initramfs 加载;
#       arm64 VA/PA 位宽对齐原厂 2.1 的 48/48.
# 上一版内核实测 PHY_QCOM_USB_HS=m / USB_CONFIGFS=m, 结果 UDC 与 RNDIS 全部
# 要等 userspace 加载模块, 开机早期网卡不存在. 这里把"必须 =y"钉死:
# olddefconfig 若把它们改回 =m/=n, 直接 fail, 不打印 WARN 放行.
usb_strict_y=(
  "CONFIG_PHY_QCOM_USB_HS"        # USB HS PHY (dtb: qcom,usb-hs-phy-msm8916)
  "CONFIG_USB_CHIPIDEA"           # ci-hdrc 控制器
  "CONFIG_USB_CHIPIDEA_UDC"       # gadget 侧的 UDC
  "CONFIG_USB_CHIPIDEA_MSM"       # msm8916 glue (devicetree 节点驱动)
  "CONFIG_USB_GADGET"             # gadget 框架
  "CONFIG_USB_CONFIGFS"           # configfs gadget (RNDIS/ACM 的挂载点)
  "CONFIG_USB_CONFIGFS_RNDIS"     # USB 网卡
  "CONFIG_USB_CONFIGFS_ACM"       # 串口
)
for sym in "${usb_strict_y[@]}"; do
  val=$(cfg_state "$sym")
  if [[ "$val" == "y" ]]; then
    echo "  OK:   ${sym}=y"
  else
    # 三种实际状态都要能区分: =m / =n(即 "# ... is not set") / ABSENT(该分支无此符号)
    case "$val" in
      m)       why="被 Kconfig 依赖或 select 降级成模块 (=m)" ;;
      n)       why="被 olddefconfig 反选成 =n (依赖未满足或被 select 限制)" ;;
      ABSENT)  why="该内核分支没有这个符号 (Kconfig 里不存在), 检查 kernel 版本/命名" ;;
      *)       why="非预期值" ;;
    esac
    echo "  FATAL: ${sym} 期望 y, 实际=${val} — ${why}"
    echo "        检查 fragment: 该符号在 msm8916.config 里是否 =y 且没有被后面的行覆盖."
    kdef "$sym" | sed 's/^/         defined: /'
    final_fail=1
  fi
done

# ---- 5h. Round 11: arm64 VA/PA 必须是 48 (对齐原厂 2.1) ----
va_val=$(cfg_state CONFIG_ARM64_VA_BITS)
if [[ "$va_val" == "48" ]]; then
  echo "  OK:   CONFIG_ARM64_VA_BITS=48"
else
  echo "  FATAL: CONFIG_ARM64_VA_BITS 期望 48, 实际=${va_val}"
  echo "        fragment 必须同时有 CONFIG_ARM64_VA_BITS_48=y 和 CONFIG_ARM64_VA_BITS_52=n."
  final_fail=1
fi
va52_val=$(cfg_state CONFIG_ARM64_VA_BITS_52)
if [[ "$va52_val" == "y" ]]; then
  echo "  FATAL: CONFIG_ARM64_VA_BITS_52=y (48 位没生效!)"
  final_fail=1
else
  echo "  OK:   CONFIG_ARM64_VA_BITS_52=${va52_val}"
fi
pa_val=$(cfg_state CONFIG_ARM64_PA_BITS)
if [[ "$pa_val" == "48" ]]; then
  echo "  OK:   CONFIG_ARM64_PA_BITS=48"
elif [[ "$pa_val" == "ABSENT" ]]; then
  echo "  WARN: CONFIG_ARM64_PA_BITS 不存在 (该内核分支无此符号)"
else
  echo "  FATAL: CONFIG_ARM64_PA_BITS 期望 48, 实际=${pa_val}"
  final_fail=1
fi

# ---- 5i. Round 11: BTF 在本阶段必须未开启 (最终以 workflow attest 为准) ----
btf_val=$(cfg_state CONFIG_DEBUG_INFO_BTF)
if [[ "$btf_val" == "y" ]]; then
  echo "  FATAL: CONFIG_DEBUG_INFO_BTF=y — .BTF 是 alloc 段, 会直接进 Image"
  final_fail=1
else
  echo "  OK:   CONFIG_DEBUG_INFO_BTF=${btf_val} (KERNEL_BTF=no 由 workflow 保证)"
fi
# 优化级别 (只告警: 若 Image 实测 <= 26 MiB 可以回到 -O2)
opt_val=$(cfg_state CONFIG_CC_OPTIMIZE_FOR_SIZE)
if [[ "$opt_val" == "y" ]]; then
  echo "  OK:   CONFIG_CC_OPTIMIZE_FOR_SIZE=y (-Os, Round 10 体积兜底)"
else
  echo "  WARN: CONFIG_CC_OPTIMIZE_FOR_SIZE=${opt_val} — Image 可能超过 28 MiB"
fi

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
  "CONFIG_USB_CHIPIDEA"                # msm8916 USB (ci-hdrc)
  "CONFIG_USB_CHIPIDEA_UDC"            # Round 11: gadget 侧 UDC 必须 =y
  "CONFIG_USB_CHIPIDEA_MSM"            # Round 11: msm8916 glue 必须 =y
  "CONFIG_PHY_QCOM_USB_HS"             # msm8916 USB HS PHY (Round 11: 必须 =y)
  "CONFIG_ARM64_VA_BITS"               # Round 11: 必须 48 (对齐原厂)
  "CONFIG_ARM64_PA_BITS"               # Round 11: 必须 48 (对齐原厂)
  "CONFIG_CC_OPTIMIZE_FOR_SIZE"        # Round 10: -Os 体积兜底
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
