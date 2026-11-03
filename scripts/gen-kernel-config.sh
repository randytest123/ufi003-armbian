#!/usr/bin/env bash
# =============================================================================
# gen-kernel-config.sh — 生成完整的 Linux kernel .config
# 供 GitHub Actions 的 prepare 和 build 两个 job 调用
#
# 用法:
#   ./scripts/gen-kernel-config.sh \
#     --branch current \
#     --fragment config/sections/msm8916.config \
#     --output-dir armbian-build/userpatches/config/kernel \
#     [--also-output armbian-build/userpatches]
#
# 关键设计:
#   - 用 arm64 通用 defconfig (主线 arm64/configs/ 只有 defconfig, 没有 SoC-specific 的)
#   - defconfig 本身已包含 CONFIG_ARCH_QCOM=y 和大量 qcom 驱动
#   - 我们的 fragment 只追加 msm8916 需要的额外选项 (WiFi 等)
#   - make olddefconfig 统一填充默认值
#   - 严格硬校验: 任何关键 CONFIG_ 缺失或总数 < 3000 直接 exit 1
#
# 为什么不用 msm8916_defconfig?
#   主线 Linux arm64 目录 (arch/arm64/configs/) 只有三个文件:
#     defconfig, hardening.config, virt.config
#   没有 msm8916_defconfig! Qualcomm msm8916 只是众多 qcom 板之一,
#   用通用 defconfig + fragment merge 是主线 arm64 的标准做法.
#
# 参考: torvalds/linux v6.12 arch/arm64/configs/
#   https://github.com/torvalds/linux/tree/v6.12/arch/arm64/configs
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
echo "=== gen-kernel-config.sh START ==="
echo "  BRANCH=$BRANCH  KVER=$KVER  CONFIG_NAME=$CONFIG_NAME"
echo "  WORK_DIR=$WORK_DIR"
echo "  OUTPUT_DIRS=${OUTPUT_DIRS[*]}"
echo ""

# ---- Step 1: clone 内核 ----
echo "=== Step 1/5: Clone kernel $KVER ==="
cd "$WORK_DIR"
rm -rf linux-src
git clone --depth 1 --single-branch --branch "$KVER" \
    https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git linux-src \
    2>&1 | tail -5 || { echo "FATAL: kernel clone failed"; exit 1; }
cd linux-src
echo "  Clone OK: $(git rev-parse --short HEAD)"
echo ""

# ---- Step 2: make arm64 通用 defconfig ----
echo "=== Step 2/5: make ARCH=arm64 defconfig ==="
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig > /tmp/make_defconfig.log 2>&1 || {
  echo "FATAL: make defconfig failed!"
  tail -40 /tmp/make_defconfig.log
  exit 1
}
echo "  make defconfig OK"
echo ""

# ---- Step 3: 硬校验 1 — 通用 defconfig 里必须有关键选项 ----
echo "=== Step 3/5: Sanity check — base defconfig has core options ==="
fail=0
require_cfg() {
  local key="$1"; local desc="$2"
  if grep -q "^${key}=y" .config; then
    echo "  OK:   ${key}=y  (${desc})"
  else
    echo "  FAIL: ${key}  (${desc}) — not found in base defconfig!"
    fail=1
  fi
}

require_cfg "CONFIG_ARCH_QCOM"      "Qualcomm arch support (base of everything)"
require_cfg "CONFIG_BLK_DEV_INITRD"  "Initial RAM disk support"
require_cfg "CONFIG_EXT4_FS"        "ext4 rootfs"
require_cfg "CONFIG_SERIAL_MSM_GENI_CONSOLE" "Qualcomm UART console"

if [[ $fail -ne 0 ]]; then
  echo ""
  echo "FATAL: Base arm64 defconfig is missing critical QCOM options!"
  echo "Check kernel version and defconfig contents."
  exit 1
fi

echo "  Base config lines: $(wc -l < .config)"
echo "  CONFIG_ entries:    $(grep -c '^CONFIG_' .config)"
echo ""

# ---- Step 4: merge fragment + olddefconfig ----
echo "=== Step 4/5: Merge fragment + make olddefconfig ==="
if [[ -n "$FRAGMENT" && -f "$FRAGMENT" ]]; then
  echo "  Appending fragment: $FRAGMENT"
  # 只追加 CONFIG_ 开头的有效配置行，跳过注释和空行
  grep -E '^CONFIG_[A-Z0-9_]+=(y|m|n)' "$FRAGMENT" >> .config || true
else
  echo "  (No fragment provided or file not found — skipping)"
fi

# olddefconfig: 自动补全/修正所有 CONFIG_ 选项的默认值
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig > /tmp/make_olddefconfig.log 2>&1 || {
  echo "FATAL: make olddefconfig failed!"
  tail -40 /tmp/make_olddefconfig.log
  exit 1
}
echo "  olddefconfig OK"
echo ""

# ---- Step 5: 硬校验 2 — 最终 config 必须满足 ----
echo "=== Step 5/5: HARD CHECK — final .config ==="
final_lines=$(wc -l < .config)
final_cfg_count=$(grep -c '^CONFIG_' .config)

echo "  Final config lines: $final_lines"
echo "  CONFIG_ entries:    $final_cfg_count"

if [[ $final_cfg_count -lt 3000 ]]; then
  echo ""
  echo "FATAL: Too few CONFIG_ entries ($final_cfg_count < 3000)!"
  echo "This usually means defconfig failed silently (wrong ARCH, wrong branch, etc.)"
  echo "Full .config contents (first 100 lines):"
  head -100 .config
  exit 1
fi

# 必选项再次验证 (olddefconfig 后可能被改)
echo ""
echo "=== Re-check after olddefconfig ==="
final_fail=0

# 核心架构
if grep -q '^CONFIG_ARCH_QCOM=y' .config; then
  echo "  OK: CONFIG_ARCH_QCOM=y"
else
  echo "  FAIL: CONFIG_ARCH_QCOM missing!"; final_fail=1
fi

# 文件系统
if grep -q '^CONFIG_EXT4_FS=y' .config; then
  echo "  OK: CONFIG_EXT4_FS=y"
else
  echo "  FAIL: CONFIG_EXT4_FS missing!"; final_fail=1
fi

# initrd (编译 Armbian rootfs 需要)
if grep -q '^CONFIG_BLK_DEV_INITRD=y' .config; then
  echo "  OK: CONFIG_BLK_DEV_INITRD=y"
else
  echo "  FAIL: CONFIG_BLK_DEV_INITRD missing!"; final_fail=1
fi

# ---- 打印 fragment 里涉及的关键项实际值 (人工核对用) ----
echo ""
echo "=== Fragment-related options (actual values) ==="
show_cfg() {
  local key="$1"
  local val
  val=$(grep "^${key}=" .config 2>/dev/null || echo "(not set)")
  echo "  $val"
}

show_cfg "CONFIG_WCN36XX"             # WCN3620 WiFi driver
show_cfg "CONFIG_QCOM_PRONTO"          # PIL loader for WCNSS
show_cfg "CONFIG_QCOM_SMD"             # SMD channel driver
show_cfg "CONFIG_QCOM_SMEM"            # Shared memory
show_cfg "CONFIG_QCOM_SMD_REGULATOR"   # SMD RPM regulator
show_cfg "CONFIG_QCOM_PIL"             # PIL subsystem
show_cfg "CONFIG_USB_DWC3_GADGET"      # USB gadget
show_cfg "CONFIG_USB_CONFIGFS_RNDIS"   # RNDIS gadget
show_cfg "CONFIG_MMC_SDHCI_PLTFM"      # eMMC controller
show_cfg "CONFIG_SERIAL_MSM_GENI_CONSOLE" # UART console

if [[ $final_fail -ne 0 ]]; then
  echo ""
  echo "FATAL: Final .config is missing critical options after olddefconfig!"
  exit 1
fi

# ---- 拷贝到所有目标目录 ----
echo ""
echo "=== Installing .config to output dirs ==="
for dir in "${OUTPUT_DIRS[@]}"; do
  mkdir -p "$dir"
  cp -v .config "${dir}/${CONFIG_NAME}"
  echo "  Installed: ${dir}/${CONFIG_NAME} ($(stat -c%s "${dir}/${CONFIG_NAME}") bytes)"
done

# ---- 清理 ----
cd /
rm -rf "$WORK_DIR"

echo ""
echo "=== gen-kernel-config.sh DONE ==="
echo "  Generated: $CONFIG_NAME"
echo "  Size: $(stat -c%s "${OUTPUT_DIRS[0]}/${CONFIG_NAME}") bytes"
echo "  CONFIG_ entries: $final_cfg_count"
