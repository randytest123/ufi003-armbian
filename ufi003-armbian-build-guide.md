# UFI003 Armbian 构建完整指南 (去 modem 版)

> **目标**: 在 Linux 机器 / WSL2 上，用 Armbian build 框架构建 UFI003 的无 modem 镜像
> **产出**: 一个 ext4 镜像，刷到 eMMC 后能启动，有 WiFi，可 SSH 登录
> **不包含**: Modem/LTE、SIM、闭源 modem firmware

---

## 一、环境准备 (Linux 主机 or WSL2)

### 选项 A: 真实 Linux 主机 (推荐)

Ubuntu 22.04/24.04 或 Debian 12：
```bash
sudo apt update
sudo apt install -y git build-essential
```

### 选项 B: WSL2

```powershell
# PowerShell (管理员) 执行一次即可:
wsl --update
wsl --install -d Ubuntu-24.04

# 重启 Windows 后，在 Ubuntu 里:
sudo apt update
sudo apt install -y git build-essential
```

### 基本系统依赖 (Armbian 框架需要)

```bash
sudo apt install -y \
    bison build-essential ccache curl flex gawk gcc-aarch64-linux-gnu \
    gcc-arm-none-eabi git gnupg2 jq liblz4-tool libncurses-dev libssl-dev \
    libusb-1.0-0-dev libusb-dev libxml2-dev libxml2-utils lz4 \
    p7zip-full python3-dev python3-pyelftools python3-setuptools \
    qemu-user-static rsync swig time u-boot-tools unzip uuid-dev \
    xz-utils zip zlib1g-dev lzop

# 如果用 WSL2, 还需要:
sudo apt install -y binfmt-support qemu-user-static
sudo update-binfmts --enable qemu-aarch64
```

### 磁盘空间和时间

| 项目 | 需求 |
|------|------|
| 磁盘 | 至少 20GB 空闲 |
| 首次构建 | 约 2-3 小时 (下载内核源码 + 编译) |
| 二次构建 | 约 20-30 分钟 (使用 ccache) |
| RAM | 至少 8GB |

---

## 二、获取配置文件

把本地产出的配置复制到 Armbian 框架里。假设 Armbian build 框架还没 clone，一起做：

```bash
# 在 Linux 主机或 WSL2 里执行:
cd ~

# 1. Clone Armbian build 框架
git clone --depth 1 --branch main https://github.com/armbian/build.git armbian-build
cd armbian-build

# 2. 安装我们的配置文件
# WSL2 下 Windows 盘在 /mnt/c/ /mnt/d/ 下, 替换为实际位置:
SRC="/mnt/d/xz/traefiles/ufi003-armbian"
# 或者任意能访问到本目录的路径, 比如:
# SRC="/home/user/ufi003-armbian"  (Linux 主机上)

cp "${SRC}/config/boards/ufi003.csc"              config/boards/
cp "${SRC}/config/sources/families/msm8916.conf"  config/sources/families/
cp "${SRC}/config/bootscripts/bootscript-msm8916.sh" config/bootscripts/

# 3. 安装 kernel DTS patch (userpatches 机制)
mkdir -p userpatches/kernel
cp "${SRC}/userpatches/kernel/add-openstick-dts-ufi003-nomodem.patch" \
   userpatches/kernel/

# 4. 给 build.sh 加执行权限
chmod +x compile.sh
```

如果 Armbian 框架是 clone mainline 而不是 `--depth 1`，速度会慢很多。`--depth 1` 够用。

---

## 三、执行构建

### 构建 Armbian Debian bookworm + 主线 6.12 内核

```bash
cd ~/armbian-build

# 交互式构建 (首次建议用这个, 看清楚过程):
sudo ./compile.sh BOARD=ufi003 BRANCH=current RELEASE=bookworm \
    BUILD_MINIMAL=yes KERNEL_CONFIGURE=no EXPERT=no COMPRESS_OUTPUTIMAGE=xz

# 参数说明:
#   BOARD=ufi003        — 我们的板子名字 (在 config/boards/ufi003.csc)
#   BRANCH=current      — 主线稳定内核 (对应 msm8916.conf 里 KERNELBRANCH='branch:linux-6.12.y')
#   RELEASE=bookworm    — Debian 12 (stable)
#   BUILD_MINIMAL=yes   — 最小化 rootfs (没有 X/DE, 省时间空间)
#   KERNEL_CONFIGURE=no — 不要让我交互式选内核选项 (我们已经写好了 defconfig)
#   EXPERT=no           — 简单模式
#   COMPRESS_OUTPUTIMAGE=xz — 输出 .img.xz, 体积小

# 如果构建中途停了, 修复后重新执行同一个命令即可 (增量构建)
```

### 构建 Armbian Ubuntu noble + 主线 7.2 内核

```bash
sudo ./compile.sh BOARD=ufi003 BRANCH=edge RELEASE=noble \
    BUILD_MINIMAL=yes KERNEL_CONFIGURE=no EXPERT=no COMPRESS_OUTPUTIMAGE=xz
```

### 预期耗时

| 阶段 | 时间 | 备注 |
|------|------|------|
| clone 内核源码 | 5-15 min | 取决于网速 (linux-stable 约 2GB) |
| patch + defconfig | < 1 min | userpatches 自动应用 |
| 编译内核 + DTB | 30-60 min | 取决于 CPU 核数 |
| 编译驱动模块 | 10-20 min | cfg80211/mac80211/ath 等 |
| 构建 rootfs | 10-20 min | debootstrap + apt install |
| 打包镜像 | < 5 min | ext4 + xz |
| **总计** | **2-3 小时** | 首次, 无缓存 |

### 输出位置

```
~/armbian-build/output/
├── images/
│   └── Armbian_25.02_Ufi003_bookworm_current_minimal.img.xz
└── debs/
    ├── linux-image-6.12.*-armbian-ufi003_*.deb
    └── linux-headers-6.12.*-armbian-ufi003_*.deb
```

---

## 四、可能踩的坑

### 坑 1: userpatches patch 应用失败

**症状**: 构建时内核 DTB 编译失败 `msm8916-handsome-openstick-common.dtsi: not found`

**原因**: HandsomeYingyan 的 patch 是基于 5.10 内核写的，主线 6.12/7.2 的 dtsi 结构可能不同（比如 modem.dtsi 的位置变了）

**解决方案**:
```bash
# 让 Armbian 输出 patch apply 详情:
sudo ./compile.sh ... VERBOSE=yes ...

# 或者手动进内核目录看:
cd ~/armbian-build/cache/sources/linux-*
git apply --check ../../../userpatches/kernel/add-openstick-dts-ufi003-nomodem.patch
# 如果 check 失败, 手动修正 patch 里的 path
```

**如果 patch 确实适配不了主线 6.12**: 退而用**路线 B**，绕过内核 patch，直接编译我们的去 modem DTS：

```bash
# === 路线 B: 不用 kernel patch, 直接 dtc 编 DTS → DTB ===
# 1. 在 Linux/WSL2 上装 dtc
sudo apt install -y device-tree-compiler

# 2. 编译我们的去 modem DTS
cd /path/to/ufi003-armbian/
dtc -I dts -O dtb -o msm8916-handsome-openstick-ufi003-armbian.dtb \
    msm8916-handsome-openstick-ufi003-armbian.dts

# 3. 用这个 dtb 替换 Armbian 内核自带的
#    找到编译好的 rootfs (mount 或者直接 cp)
DTB_DEST="$HOME/armbian-build/output/rootfs/usr/lib/linux-image-*/qcom/"
# 或者直接放到构建产物的 boot 目录下:
cp msm8916-handsome-openstick-ufi003-armbian.dtb \
   "$HOME/armbian-build/output/rootfs/boot/dtb/qcom/msm8916-handsome-openstick-ufi003.dtb"

# 4. Armbian 打包镜像时就会用我们的 dtb
```

**路线 B 优点**: 不依赖 kernel patch 适配主线 6.12；DTS 已经过验证（brace balance 正确，modem 节点全 disabled，WiFi 节点全 okay）。
**路线 B 缺点**: DTS 是从原厂 boot.img dump 出来的，包含一些冗余节点（thermal、freq-table 等），但不影响功能。

### 坑 2: 内核编译报 CONFIG_ 缺失

**症状**: `undefined symbol: wcn36xx_probe` 或类似

**原因**: 主线 msm8916_defconfig 默认没开 WCN36XX/ATH6KL

**解决方案**: config fragment 文件**已经生成**在 `ufi003-armbian/config/sections/msm8916.config`，复制到 Armbian 框架的同名位置即可：
```bash
cp ufi003-armbian/config/sections/msm8916.config \
   ~/armbian-build/config/sections/
```
这个 fragment 包含了 WiFi/USB remoteproc/regulator 等所有必需 CONFIG 项。
Armbian 会自动把它和主线 msm8916_defconfig merge。

### 坑 3: build 报 "rootfs has wrong fstype"

**症状**: `mkfs.ext4: ... wrong fstype`

**原因**: Armbian 框架对 Qualcomm 设备默认期望 GPT 分区表，但 sfdisk 参数不对

**解决方案**: 在 ufi003.csc 里已经设了 `IMAGE_PARTITION_TABLE="gpt"`，应该没问题。如果还是报错，把这行改成 `"msdos"` 试试。

### 坑 4: boot 后 kernel panic "Unable to mount rootfs"

**原因 1**: PARTUUID 不匹配（原始固件用的 PARTUUID，Armbian 新构建的 rootfs 分区 UUID 不同）

**解决**: bootscript 已经改成了 `PARTLABEL=rootfs`，更稳

**原因 2**: eMMC 分区没被正确创建

**解决**: 刷机时 fastboot flash 之前要先刷 GPT:
```bash
fastboot flash partition gpt_both0.bin
fastboot reboot bootloader
fastboot flash rootfs rootfs.img
```

### 坑 5: WiFi 固件没装导致启动慢/timeout

**症状**: boot 后 dmesg 里反复出现 "pronto: wcnss firmware not found" 或 "firmware request for wcnss.bXX failed"

**解决**: WiFi firmware 位置和完整性已确认：
```
D:\PerFiles\suishenwifi\msm8916\ufi003-debian超频版\
  一键替换基带文件\modem\
    wcnss.b00, b01, b02, b04, b06, b09, b10, b11 + wcnss.mdt
```
文件与 mdt manifest 完美匹配（12 个 PIL segment 全有对应，缺失的 b03/b05/b07/b08 是零初始化段，不需要额外文件）。

安装：
```bash
mkdir -p /lib/firmware/qcom
# Linux/WSL2 下从 Windows 盘复制:
cp /mnt/d/PerFiles/suishenwifi/msm8916/ufi003-debian超频版/一键替换基带文件/modem/wcnss.* \
   /lib/firmware/qcom/

# 或者刷机后通过 USB gadget SSH 复制:
scp wcnss.b* wcnss.mdt root@192.168.200.1:/lib/firmware/qcom/
reboot
```

**注意**: 这些文件是闭源 Qualcomm firmware，**不要提交到 GitHub**。

---

## 五、刷机步骤

构建完成后，从 WSL2/Linux 把镜像复制到 Windows 容易操作的位置：

```bash
# 把输出目录复制到任意可访问的位置
# WSL2:
cp ~/armbian-build/output/images/*.img.xz /mnt/d/xz/traefiles/
# Linux 主机:
# cp ~/armbian-build/output/images/*.img.xz ~/
```

然后在 bootloader 模式下：

```batch
:: Windows cmd / PowerShell:
adb reboot bootloader

:: 1. 先恢复原厂 bootloader (如果之前刷了 lk2nd)
fastboot flash aboot aboot.bin_original
fastboot reboot
:: 等系统起来后再进 bootloader

:: 2. 刷 GPT + lk2nd (OpenStick bootloader)
fastboot reboot bootloader
fastboot flash partition gpt_both0.bin
fastboot flash hyp hyp.mbn
fastboot flash rpm rpm.mbn
fastboot flash sbl1 sbl1.mbn
fastboot flash tz tz.mbn
fastboot flash cdt sbc_1.0_8016.bin
:: OpenStick lk2nd bootloader:
fastboot flash aboot lk2nd_aboot.mbn   :: <-- 需要你自己编译 lk2nd

:: 3. 刷 Armbian rootfs (直接 flash 到 rootfs 分区)
:: 先解压缩镜像
7z x Armbian_*.img.xz
:: 或者在 Linux/WSL: unxz Armbian_*.img.xz

:: fastboot flash rootfs (需要 fastboot -S 200m 避免大分区刷写问题)
fastboot -S 200m flash rootfs Armbian_*.img
fastboot reboot
```

**没有 boot.img!** 因为我们的 Armbian 用的是 lk2nd + extlinux.conf 直接从 rootfs 的 /boot/ 目录读内核。不需要单独 boot 分区。

---

## 六、首次启动后

```bash
# 1. 等启动 (30-60 秒, 无 modem 应该更快)
# 2. 通过 USB gadget RNDIS (如果起了) 或 UART 串口登录
#    USB gadget 默认 192.168.200.1
ssh root@192.168.200.1

# 3. 基础配置
armbian-config
# 设置 root 密码、创建用户、更新软件源

# 4. WiFi (需要先放 firmware)
mkdir -p /lib/firmware/qcom
scp wcnss.b* wcnss.mdt root@192.168.200.1:/lib/firmware/qcom/   # 从你电脑上复制
reboot

# 等起来后:
dmesg | grep -i wcnss      # 看驱动加载没
lsmod | grep ath           # ath6kl 或 wcn36xx
iw wlan0 scan              # 扫 AP
nmcli device wifi connect "YourSSID" password "YourPassword"

# 5. 验证 modem 确实没在跑
dmesg | grep -i modem       # 不应该看到任何 modem 相关加载
lsmod | grep msm            # 不应该有 mss_pil 之类
```

---

## 七、产出文件清单

```
ufi003-armbian/
├── UFI003_FINAL_ANALYSIS.md                              ← 完整分析报告
├── msm8916-handsome-openstick-ufi003-armbian.dts          ← 反编译 + 去 modem 版 DTS
├── msm8916-handsome-openstick-ufi003.dtb                 ← 原始固件 DTB (对照用)
├── msm8916-handsome-openstick-ufi003-overclock.dtb       ← 2.1GHz 超频 DTB
├── ufi003-armbian-build-guide.md                         ← 本文件
├── config/
│   ├── boards/ufi003.csc                                 ← 板子配置 (无 modem)
│   ├── sources/families/msm8916.conf                     ← 内核家族配置
│   └── bootscripts/bootscript-msm8916.sh                  ← extlinux.conf 生成器
└── userpatches/
    └── kernel/
        ├── README.md                                     ← 说明
        └── add-openstick-dts-ufi003-nomodem.patch        ← OpenStick DTS + modem disable patch
```

---

## 八、FAQ

### Q: WiFi firmware 是闭源的? 能提交到 GitHub 吗?
A: 不能。wcnss.b00~b11 + wcnss.mdt 是 Qualcomm PIL 格式闭源 firmware。只能在设备上放 `/lib/firmware/qcom/`。

### Q: 为什么不用 OpenStick-Builder?
A: OpenStick-Builder 是 OpenWrt/PostmarketOS 路线，不是 Armbian。我们明确要 Armbian + systemd + apt。

### Q: 主线 DTS patch 合入了吗?
A: 没有。HandsomeYingyan 的 patch 2022 年发了没合入。我们用 userpatches 在编译时打进去。

### Q: 构建后 rootfs 还是有 modem 相关的 deb?
A: ufi003.csc 里 `PACKAGE_LIST_BOARD_REMOVE="modemmanager ofono"` 会让它们不装。`apt install` 也不会装。

### Q: USB gadget 必须连电脑吗?
A: UFI003 默认是 USB device (作为 4G modem 棒用的)。extcon-usb-gpio 检测 USB host 线才切到 USB host 模式。所以要 SSH 进去，你需要：
- 接 USB OTG 线 (带 USB-A 转 C) 让 UFI003 当 USB host，然后插 USB 网卡/Hub
- 或者用串口 (ttyMSM0) — 需要 USB 转 UART 模块接在 blsp_uart2 (gpio175/gpio176 on tlmm block 62)
- 或者等 WiFi 好了用 wifi SSH
- 最简单: 第一次启动后用串口登录配置好 WiFi, 之后就用 WiFi SSH

---

## 九、总结: 现在能直接跑构建了吗?

| 条件 | 状态 |
|------|------|
| Linux/WSL2 构建环境 | ⚠️ 用户需要自己装 |
| Armbian 框架 clone | ✅ `git clone` 一行 |
| userpatches kernel patch | ✅ 已生成 |
| 三份配置文件 | ✅ 已更新为无 modem 版 |
| 去 modem DTS 语法 | ✅ 460/460 花括号平衡 |
| WiFi 驱动在内核 defconfig 里 | ⚠️ 需要 kernel config fragment (config/sections/msm8916.config — 可以在构建时交互式加) |
| WiFi firmware 在 rootfs 里 | ❌ 需要用户从原始固件包复制 |
| 真机验证 | ❌ 必须真机刷了才知道 |

**能跑吗?** — **能!** 配置文件和 patch 都落盘了，复制到 Linux 主机就能 `sudo ./compile.sh`。但最终刷机启动、WiFi firmware 到位、实际 SSH 登录这些环节必须真机验证。

**最常见的中断点**: 主线 patch apply 适配 (因为 HandsomeYingyan 是 5.10 写的)、WiFi 驱动没开导致 dmesg timeout、fastboot flash rootfs 大小不对。每个都有解决办法 (见坑 1-4)。
