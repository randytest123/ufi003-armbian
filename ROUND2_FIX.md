# UFI003 Armbian Build — Round 2 修复说明

## 问题来源

GitHub Actions run 4 (10月27日) 的 compile.log 暴露了 **4 个硬伤**，导致内核根本没编译：

```
[💥] PROBLEM: don't run ./compile.sh as root or with sudo     ← 警告 (不阻止运行)
[🚸] BRANCH not found for board BRANCH='current' not valid   ← KERNEL_TARGET 只有 edge
[🌱] Using kernel config file config/kernel/linux-msm8916-current.config
sha256sum: config/kernel/linux-msm8916-current.config: No such file or directory  ← 致命
[💥] Error 1 occurred in SUBSHELL at hash-files.sh:86
```

---

## 修复 1: kernel .config 缺失 (致命)

### 根因

Armbian 的 `prepare_kernel_config_core_or_userpatches` 函数（`lib/functions/compilation/kernel-config.sh` line 8-21）查找 `.config` 的优先级链：

```bash
# 优先级 1: userpatches 根目录
if [[ -f $USERPATCHES_PATH/$LINUXCONFIG.config ]]; then
    kernel_config_source_filename="${USERPATCHES_PATH}/${LINUXCONFIG}.config"
# 优先级 2: userpatches/config/kernel/ 子目录  
elif [[ -f "${USERPATCHES_PATH}/config/kernel/${LINUXCONFIG}.config" ]]; then
    kernel_config_source_filename="${USERPATCHES_PATH}/config/kernel/${LINUXCONFIG}.config"
# 优先级 3: armbian-build 框架自带的 config/kernel/
else
    kernel_config_source_filename="${SRC}/config/kernel/${LINUXCONFIG}.config"
fi
```

compile.log line 85 显示它走了 **优先级 3 的 fallback**：
```
[🌱] Using kernel config file [ config/kernel/linux-msm8916-current.config ]
sha256sum: config/kernel/linux-msm8916-current.config: No such file or directory
```

说明 **前两个 userpatches 路径都不存在**。我们只提供了 `config/sections/msm8916.config` fragment，但没有生成完整的 `linux-msm8916-current.config`。

### 修复

**在 workflow 的 build job 里，compile.sh 之前，先生成完整 .config 并放到 userpatches 路径**：

```bash
# clone 主线内核 + make msm8916_defconfig + merge fragment + make olddefconfig
# 输出到两个位置 (双保险):
#   armbian-build/userpatches/linux-msm8916-current.config      ← 优先级 1
#   armbian-build/userpatches/config/kernel/linux-msm8916-current.config  ← 优先级 2
```

关键步骤（build job "Generate full kernel .config" step）：
1. `git clone --depth 1 linux-6.12.y` 到 `/tmp/ufi003-kernel`
2. `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- msm8916_defconfig`
3. merge `config/sections/msm8916.config` fragment (只追加非 CONFIG_ 注释行)
4. `make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig`
5. 复制到两个 userpatches 位置

**源码参考**:
- `kernel-config.sh L8-21` — prepare_kernel_config_core_or_userpatches 优先级链
- `artifact-kernel.sh L102-104` — 调用 prepare_kernel_config_core_or_userpatches 后用返回路径 sha256sum

---

## 修复 2: KERNEL_TARGET BRANCH 不匹配

### 根因

`ufi003.csc` 原来只声明了 `KERNEL_TARGET="edge"`，但 workflow 请求 `BRANCH=current`。

compile.log line 16:
```
[🚸] BRANCH not found for board BRANCH='current' not valid for BOARD='ufi003' - listed KERNEL_TARGET='edge'
```

### 修复

`ufi003.csc` line 50:
```bash
declare -g KERNEL_TARGET="current,edge"    # 原来是 "edge" 只
declare -g KERNEL_TEST_TARGET="current"
```

`msm8916.conf` line 27-38 根据 BRANCH 正确映射 KERNEL_MAJOR_MINOR:
```bash
case $BRANCH in
    current)  KERNEL_MAJOR_MINOR="6.12"; KERNELBRANCH='branch:linux-6.12.y' ;;
    edge)     KERNEL_MAJOR_MINOR="7.2";  KERNELBRANCH='branch:linux-7.2.y'  ;;
esac
```

LINUXCONFIG 自动生成为 `linux-msm8916-current`（BRANCH=current 时）。

---

## 修复 3: 不用 sudo 套 compile.sh + pipefail

### sudo/root 问题

compile.log line 9 显示：
```
[💥] PROBLEM: don't run ./compile.sh as root or with sudo
```

这只是 **PROBLEM 级别警告**，不阻止运行。证据：compile.log line 10 之后继续了配置流程。

- `compile.sh` (vmain 最新版) 只在 macOS 上拒绝 root（`single.sh` line 17-22）
- Linux 上 runner 默认用户就是 root（`whoami` → `root`），无法避免
- Armbian 内部自己也需要 mount/sudo 特权来编译内核、创建 rootfs、losetup 等
- **修复**：不套 sudo，直接 `./compile.sh`

### pipefail 问题

原来用 `sudo ./compile.sh ... 2>&1 | tee compile.log` 的 `$?` 是 tee 的退出码（永远是 0），compile.sh 即使失败也会"成功"。

### 修复

```bash
set -o pipefail
{
  ./compile.sh BOARD=... BRANCH=... ...
} 2>&1 | tee compile.log
RC=${PIPESTATUS[0]}
set +o pipefail

if [[ $RC -ne 0 ]]; then
  tail -150 compile.log; exit 1
fi
```

---

## 修复 4: 硬校验 img 产出

### 问题

即使 compile.sh 退出码是 0，也可能因为各种原因没生成 rootfs img。assemble job 如果空手进入会挂在"找 rootfs 镜像"。

### 修复

compile.sh 跑完后**双重硬校验**：

```bash
# 校验 1: exit code 必须 0
if [[ $RC -ne 0 ]]; then exit 1; fi

# 校验 2: 必须有 .img 文件
IMG_COUNT=$(find output -type f \( -name "*.img" -o -name "*.img.xz" \) | wc -l)
if [[ $IMG_COUNT -eq 0 ]]; then
  echo "FATAL: No .img files found!"
  tail -80 compile.log; exit 1
fi
```

assemble job 也有独立校验：
```bash
XZ_OR_IMG=$(find armbian-output -type f \( -name "*.img.xz" -o -name "*.img" \) | head -1)
if [[ -z "$XZ_OR_IMG" ]]; then
  echo "NO ROOTFS IMG FOUND"; exit 1
fi
```

---

## 修改文件清单

| 文件 | 改动 |
|------|------|
| `.github/workflows/build-armbian-ufi003.yml` | 彻底重写 Round 2 版 (4 处硬修 + inline .config 生成 + pipefail + 双重 img 校验) |
| `config/boards/ufi003.csc` | L50: `KERNEL_TARGET="edge"` → `KERNEL_TARGET="current,edge"` |

**无需新增文件** — 完整 .config 由 workflow 在运行时动态生成（clone 主线内核 + defconfig + fragment merge + olddefconfig）。

---

## GitHub Actions 上的操作步骤

用户需要在网页编辑器里：

1. 打开仓库 → `.github/workflows/build-armbian-ufi003.yml`
2. 全选 → 粘贴新版内容
3. Commit changes
4. Actions tab → Run workflow → 选 current → Run

ufi003.csc 如果还是旧版（只有 KERNEL_TARGET="edge"），同样需要编辑 line 50 改成 `"current,edge"`。

---

## 源码参考索引 (armbian/build @ 815a50b6, 2026-07-11)

| 函数/文件 | 行号 | 说明 |
|-----------|------|------|
| `kernel-config.sh` → `prepare_kernel_config_core_or_userpatches` | 8-21 | .config 查找优先级链 |
| `kernel-config.sh` → `kernel_config_initialize` | ~50-80 | 复制 .config → make olddefconfig |
| `artifact-kernel.sh` → `artifact_kernel_prepare_version` | 100-104 | 调用 prepare 后用返回路径哈希 |
| `hash-files.sh` → `calculate_hash_for_files` | ~70-86 | cd SRC && sha256sum 相对路径 |
| `compile.sh` | 全文 | macOS 拒绝 root，Linux 不拒绝 |
| `single.sh` | 17-22 | macOS root check |

---

## 风险与不确定项

| 项 | 风险 | 缓解 |
|----|------|------|
| kernel clone 速度 | git.kernel.org 可能慢/超时 | 已用 --depth 1 --single-branch，超时 180s |
| msm8916_defconfig 存在性 | 主线内核 6.12+ 必须有此 defconfig | 确认主线 linux-6.12.y 有 arch/arm64/configs/msm8916_defconfig |
| fragment 与主线冲突 | CONFIG_ 选项在新内核里可能改名/移除 | make olddefconfig 会自动处理未知选项为默认值 |
| kernel patch 适配 | add-openstick-dts-ufi003-nomodem.patch 是 5.10 时代的 | prepare job 会生成 .config，patch 由 Armbian 的 patching.py 在编译阶段应用，不影响 config 生成 |
| WiFi firmware | 闭源 blobs，用户需手动复制到 /lib/firmware/qcom/ | 已在 ufi003.csc post_family_tweaks_bsp 里写 README |
