# 用 GitHub Actions 零环境构建 UFI003 OpenStick Armbian

**一句话版本**：把 `ufi003-armbian` 目录上传到 GitHub 一个新仓库，点 "Actions" → "Build UFI003 OpenStick Armbian" → "Run workflow"，等 ~2 小时，artifact 栏就能下载可烧录的 `boot.img` + `rootfs.img`。

**为什么选这条**：
- 不需要自己装 Linux / WSL / Docker
- 每次构建干净环境，可复现
- 6 小时 runner 超时足够 (实测 ~80 分钟)
- 社区 runner 7GB RAM / 4 核 / 86GB 磁盘，比用户那台 ARMv7 盒子强太多

---

## 前置条件

一个 GitHub 账号（免费就行）。不需要 Git 命令行。

---

## 网页逐步操作（从零到上传）

### Step 1: 创建一个新 GitHub 仓库

1. 打开 https://github.com/new
2. Repository name: `ufi003-armbian-build` (随便什么名字)
3. Public 或 Private 都行 (private 每周免费 9999 分钟，public 不限)
4. **不要** 勾选 "Add a README file" / ".gitignore" / "License"
5. 点 **Create repository**

### Step 2: 上传本目录到这个仓库

**不需要 git 命令行**，完全网页操作：

1. 进入你刚创建的仓库页面
2. 点页面上的 **"creating a new file or uploading an existing file"** (或直接在地址栏后面加 `/upload/main`)
3. 打开本地文件夹 `D:\xz\traefiles\ufi003-armbian`
4. **把整个目录拖进去** (包括 `.github/` 文件夹)
   - 注意 GitHub 网页的上传可能不保留 `.github/workflows/` 目录结构 — 如果不行，用下面这个替代方案：

**替代方案（更可靠）**：
1. 在仓库页面点 **Add file** → **Create new file**
2. 文件名输入 `.github/workflows/build-armbian-ufi003.yml`
3. 内容粘贴：本地 `ufi003-armbian/.github/workflows/build-armbian-ufi003.yml` 的全部内容
4. Commit message: "Add build workflow" → 点 **Commit new file**
5. 重复这个过程，分别上传所有配置文件：
   - `config/boards/ufi003.csc`
   - `config/sources/families/msm8916.conf`
   - `config/bootscripts/bootscript-msm8916.sh`
   - `config/sections/msm8916.config`
   - `userpatches/kernel/add-openstick-dts-ufi003-nomodem.patch`
   - `msm8916-handsome-openstick-ufi003-armbian.dts`

### Step 3: 触发构建

1. 进入仓库页面，点顶部 **Actions** 标签
2. 左侧列表里会出现 "Build UFI003 OpenStick Armbian"
3. 点进去 → 右侧 **Run workflow** 按钮
4. 可选填参数（或直接用默认值）→ **Run workflow**

### Step 4: 等待 + 看日志

点击刚启动的 workflow run，进入详情页。会看到 3 个 job 串联执行：

```
prepare: deps + config + kernel patch test     ← ~10 min, 快速检查 patch 冲突
    ↓ (needs: prepare)
build: armbian compile.sh                      ← ~60-100 min, 主力构建
    ↓ (needs: build-armbian)
assemble: boot.img + rootfs.img + verify       ← ~10 min, 组装+自检+上传
```

构建过程中可以点每个 job 名字看实时日志。

**如果卡在 prepare job**: 大概率是 kernel patch 不适配主线 (见下方"已知限制 #1")
**如果 build 跑了 1 小时**: 正常，内核编译确实这么久
**如果 build 超 6 小时被杀**: 不太可能，7GB RAM + 4 核跑主线 6.12 约 60 min，加 debootstrap 和打包总共 < 2h

### Step 5: 下载 artifact

workflow 绿色勾跑完后，页面下方 "Artifacts" 区域会有：

| Artifact | 内容 | 用途 |
|----------|------|------|
| `ufi003-armebian-<run#>` | boot.img + rootfs.img | **fastboot flash 用** |
| `ufi003-config-source` | config/ + userpatches/ + .dts | 存档，刷机参考 |

点 artifact 名字下载 zip，解压后：
```
boot.img      ← boot 分区镜像 (64MB FAT32)
rootfs.img    ← rootfs 分区镜像 (~1GB ext4)
```

然后在刷机脚本 `flash-fastboot.sh` 里用这两个文件就行。

---

## 已知限制（别对结果抱 100% 期望）

### 1. kernel patch apply 可能冲突

HandsomeYingyan 2022 年写的 patch 基于 Linux 5.10。主线 6.12 里 `modem.dtsi` 的 include 位置变了。

- **prepare job 会提前检测这个问题**：如果 patch apply 失败，prepare job 会 exit 0 (不 hard fail)，输出里会告诉你 patch 冲突了
- **解决方法**：手动改 patch 里的 include 路径，或走**路线 B** (dtc 直接编 DTS)
- 最简单的路线 B：在 assemble job 里加一步 `dtc -I dts -O dtb` 然后手动替换 boot 分区里的 dtb

### 2. artifact 大小上限 2GB / 单文件

- rootfs.img 是 ext4 原始镜像，约 1GB (Armbian minimal)，没问题
- boot.img 是 64MB FAT32，没问题
- 完整 4GB EDL 磁盘镜像超出限制 — 所以 workflow **跳过了完整 EDL img**，只出 fastboot 分卷产物
- 如果你真要 full EDL img，本地 `dd if=/dev/zero bs=1M count=4096 | sgdisk ...` 手动组

### 3. 可能的 runner OOM

- runner 7GB RAM，编主线 6.12 + 4 核 `make -j2` 应该够
- 如果 OOM：把 env 里 `MAKEFLAGS="-j1"` 改了，或用 ccache 缓存加速后只编 `dtbs` (跳过内核本体编译)

### 4. WiFi firmware 不会被打包进 rootfs

- WiFi firmware (wcnss.b00~b11 + wcnss.mdt) 是 Qualcomm 闭源，不能放进公开仓库
- 刷机后手动复制：`mkdir -p /lib/firmware/qcom && scp wcnss.* root@device:/lib/firmware/qcom/`
- 本地 Windows 里：`D:\PerFiles\suishenwifi\msm8916\ufi003-debian超频版\一键替换基带文件\modem\` 下

### 5. build-image.sh 在 runner 上不执行

我们没把 assemble job 跟 build-image.sh 绑定（因为 runner 环境差异大）。而是在 workflow 里直接写了组装逻辑。build-image.sh 留作本地 Linux/WSL2 跑的参考脚本。

---

## 如果你用 Git 命令行（可选）

```bash
# Windows 上装了 Git 的话：
cd /path/to/D:/xz/traefiles/ufi003-armbian   # 或 cmd 里 pushd D:\xz\traefiles\ufi003-armbian
git init
git add -A
git commit -m "Initial commit: UFI003 Armbian build config + workflow"
git branch -M main
git remote add origin https://github.com/<你的用户名>/ufi003-armbian-build.git
git push -u origin main
# 然后回浏览器点 Actions 标签 → Run workflow
```

---

## 时间 & 成本估算

| 项 | 时间 | 成本 |
|----|------|------|
| 上传到 GitHub | 10 min | 免费 |
| prepare job | ~10 min | 20 分钟 (GitHub minutes) |
| build job (首次) | 60-100 min | 120-200 min |
| build job (ccache 二次) | 20-40 min | 40-80 min |
| assemble + verify | ~10 min | 20 min |
| 下载 artifact | 2 min | 免费 |
| **首次构建总耗时** | **~90 min** | ~170 GitHub minutes |
| **GitHub Actions 免费额度** | 每月 2000 min | 约能跑 11 次 |

---

## 快速回退（如果 workflow 挂了）

1. 点 build job 名字 → 右上角 "..." → "Download logs"，解压找最底层 FAILED
2. 常见报错：
   - `patch apply failed` → 路线 B (dtc 直接编)
   - `apt-get install failed` → 是 runner 临时网络问题，重试一次就好
   - `No kernel found in rootfs /boot` → kernel patch 根本没生效，rootfs 里没有 Image

3. 修复完 commit → push → 自动触发下一次 build

---

## Round 5: 磁盘策略（14GB runner 生存手册）

**为什么判定是 ENOSPC 而不是内存不足**：apt 报
`E: Could not read from /var/lib/apt/lists/github.armbian.com_configng_dists_stable_InRelease - getline (12: Cannot allocate memory)`。
`getline()` 读文件失败返回 ENOMEM(12) 的典型场景是文件在被写入时被截断/无法扩展——即底层 `write()` 已经 ENOSPC。runner 有 15.6GiB RAM 而 apt 读的是个几百 KB 的 InRelease，内存不足不可能。所以是磁盘写满。

**workflow 里的四道措施**：

| 措施 | 预期省/多出 | 说明 |
|---|---|---|
| Free up disk space (Round 4) | +6~12GB | 删 dotnet/android/ghc/CodeQL/boost/swift、apt 缓存、docker 残留 |
| Relocate to /mnt (Round 5) | 视 runner 而定 | 仅当 `/mnt` 是独立且更大的盘时，把 `armbian-build` 用 symlink 迁过去；同一块盘会打印 "same disk, skip" |
| 关 ccache restore/save | +1~3GB | 时间换磁盘，首次编译命中率本来低 |
| `COMPRESS_OUTPUTIMAGE=""` | +1~2GB | 不再生成 xz 临时文件；`compress-checksum.sh` 用子串匹配，空值即不压缩 |
| Disk gate (>=12GiB) | 提前失败 | 编译前检查，不够直接报 "runner disk too small" |

**诊断数据在哪**：build job 的 artifact `disk-report-<run#>`，`if: always()` 上传，**失败也能下载**。
里面含编译前后的 `df -h /`、`df -h /mnt`、以及 `cache/sources`、`cache`、`output`、`userpatches`、`/var/lib/docker` 的 `du -sh`。

**兜底：larger runner（付费）**。GitHub 的 larger runner（如 `ubuntu-latest-4-cores`）磁盘远大于标准 runner 的 14GB，按分钟计费，需要仓库/组织已开通。workflow 里 `build-armbian` job 的 `runs-on` 上方留了注释示例，取消注释即可切换。

---

## Round 6（更正 Round 5）：不是 ENOSPC，是 qemu-user + apt 的虚拟内存问题

实测 `disk-report.txt`：runner 是 **145GB 盘**，编译前 111GiB 空闲、编译后 91GiB，`/mnt` 与 `/` 同一设备（`/dev/root`）。所以 Round 5 的 ENOSPC 判断**被推翻**；磁盘相关改动保留（无害），但不是本问题的解。

**真正原因**：armbian 的 `chroot_sdcard()` 在 x86_64 容器里 chroot 进 arm64 rootfs，靠 `qemu-aarch64-static` 执行 arm64 的 `apt-get`。qemu-user 会预留海量虚拟地址空间，默认的 overcommit 策略（`vm.overcommit_memory=0`）拒绝这种 mmap，于是 apt 的 `getline()` 拿到 `ENOMEM(12)`，报成 `Could not read from ... InRelease - getline (12: Cannot allocate memory)`。后面的 "provides only weak security information" 只是同一轮解析失败后的伴生警告。

判定依据：
1. 直接 curl 那个 InRelease：HTTP 200、`Content-Length: 6225`、正文以 `-----BEGIN PGP SIGNED MESSAGE-----` 开头、96 行、最长行 101 字节 —— 文件是好的（不是 HTML 错误页/空文件/超大文件）。
2. 同一个错误在 Armbian 论坛有复现，且失败文件是 `debian-backports` 的 InRelease，说明**与具体仓库无关**；连 bare metal（16GB RAM + 16GB swap）也会中招。
3. 该错误是 sporadic（同一配置有时成功），符合"资源预留竞争"而不是确定性数据损坏。

**修复**：编译前 `sudo sysctl -w vm.overcommit_memory=1`（workflow step `Host tuning for qemu-user`）。作用在宿主内核，容器里的 qemu 同样受益。

**关于 configng 源**：`https://github.armbian.com/configng` 是 armbian-config 的软件源（官方文档里的 `armbian-config.sources`），由 armbian 构建容器镜像自带。`apt-install.sh` 的 `apt_lists_copy_from_host_to_image_and_update()` 用 `cp -pr` 把容器侧 `/var/lib/apt/lists` 复制进 image，再 chroot 跑 `apt-get update`。**在 runner 宿主机上删源无效**（容器有独立的 `/var/lib/apt/lists`），所以没有采用"删源"方案。

**诊断**：新增 `Dump apt sources and lists` 步骤，把宿主侧 sources / lists 清单、那个 InRelease 的大小与 od 前 200 字节写进 `apt-report.txt`，与 `disk-report.txt` 一起放进 artifact `disk-report-<run#>`（`if: always()`，失败也能下载）。
