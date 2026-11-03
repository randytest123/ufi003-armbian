# UFI003 (MSM8916) Armbian 板级适配可行性报告

## 结论先行

| 维度 | 判断 |
|------|------|
| **主线内核支持** | ✅ **成熟** — Linux 6.x/7.x 主线完整支持 msm8916，含 eMMC/USB/Modem/WiFi/BT |
| **UFI003 设备树** | ⚠️ **无独立主线 DTS** — 主线有 `msm8916-thwc-ufi001c.dtb` 和 `msm8916-thwc-uf896.dtb`，UFI003 大概率与 UFI001C 硬件相同可共用 |
| **Armbian 框架内适配难度** | 🔴 **较高** — Armbian 现有 Qualcomm 支持走 ABL+EDK2/GRUB 路线，lk2nd 链式加载 + extlinux.conf 需新写 boot script |
| **实际可落地路径** | 🟡 **可以做，但推荐混合方案** — 用 OpenStick-Builder 的内核/bootloader + Armbian rootfs 打包能力 |
| **当前 Windows 环境可构建** | ❌ **不能** — WSL2 内核未安装，Docker 未安装，无法实际构建 |
| **最快可用路径** | ✅ **OpenStick-Builder (kinsamanka) + Debian 13** — 社区最成熟方案，已验证多机型 |

---

## 一、已验证事实 vs 推测

### 已验证事实（有源码/文档佐证）

| # | 事实 | 来源 |
|---|------|------|
| 1 | MSM8916 (Snapdragon 410) 是 4× ARM Cortex-A53 @1.2GHz, ARM64 | OpenStick 参考页 |
| 2 | 主线 Linux 6.x/7.x 在 `arch/arm64/boot/dts/qcom/` 下有完整 msm8916 DTS 家族 | torvalds/linux 主线 |
| 3 | 主线有 `msm8916-ufi.dtsi`（UFI 系列共享基础）和 `msm8916-thwc-ufi001c.dts` | torvalds/linux 主线 |
| 4 | UFI001C/UFI001B/UFI003 都基于 msm8916，硬件高度相似 | postmarketOS wiki, OpenStick 社区 |
| 5 | 启动链是 `lk1st → lk2nd (支持 extlinux.conf) → kernel+dtb → rootfs` | OpenStick-Builder, HandsomeYingyan |
| 6 | 刷机方式是 `fastboot flash boot boot.img` 和 `fastboot flash rootfs rootfs.img` | OpenStick 文档 |
| 7 | EDL 9008 模式可救砖，用 bkerler/edl 工具 | OpenStick 文档 |
| 8 | postmarketOS 有 community/linux-postmarketos-qcom-msm8916 主线内核包 | pmaports 仓库 |
| 9 | Crychic-Band/msm8916-armbian **没有用 Armbian 框架**，而是从 Amlogic 平台 Armbian 镜像 hack | 其 `armbian-rebuild` 脚本 |
| 10 | OpenStick-Builder 是目前最成熟的多机型构建方案 | kinsamanka/OpenStick-Builder |
| 11 | UFI 系列共用 `msm8916-ufi.dtsi`，该文件定义了 eMMC/USB/Modem/WiFi/BT 基础节点 | torvalds/linux 主线 |
| 12 | Armbian 框架已有 `qcom-abl.conf` 家族配置（基础 ABL 支持）和 `qcs6490.conf`（Radxa Dragon Q6A/Q6B） | armbian/build 仓库 |

### 推测（需真机验证）

| # | 推测 | 置信度 | 验证命令/方法 |
|---|------|--------|---------------|
| 1 | UFI003 硬件与 UFI001C 相同，可直接用 `msm8916-thwc-ufi001c.dtb` | 中 | `cat /proc/device-tree/compatible` |
| 2 | UFI003 的 modem firmware 分区布局与 UFI001C 相同 | 中 | `ls /dev/block/by-name/`, `fdisk -l` |
| 3 | UFI003 的 RAM 大小（382MB 可用？）和 eMMC 容量 | 中 | `cat /proc/meminfo`, `df -h` |
| 4 | 原厂 bootloader 是否可以通过 ADB 解锁并进入 fastboot | 需测试 | `adb reboot bootloader` |
| 5 | 原厂 modem firmware 版本和与主线内核的兼容性 | 需测试 | dump modem 分区后测试 LTE 连接 |

---

## 二、主线内核 msm8916 设备树清单

以下是 torvalds/linux 主线（2025 年）中所有 msm8916 设备树，位于 `arch/arm64/boot/dts/qcom/`：

| DTB 文件名 | 设备 | 与 UFI003 关联度 |
|-----------|------|----------------|
| **msm8916-thwc-ufi001c.dtb** | UFI001B/UFI001C 4G Modem Stick | ⭐⭐⭐ **最相似，大概率可直接用** |
| **msm8916-thwc-uf896.dtb** | UF896 4G Modem Stick | ⭐⭐ 同系列 |
| **msm8916-yiming-uz801v3.dtb** | UZ801 v3 4G Modem Stick | ⭐⭐ 同系列 |
| msm8916-asus-z00l.dtb | ASUS Zenfone GO ZB551KL | ❌ 手机，不适用 |
| msm8916-samsung-*.dtb | 多款三星手机 | ❌ 手机，不适用 |
| msm8916-motorola-*.dtb | 多款 Moto 手机 | ❌ 手机，不适用 |
| msm8916-wingtech-wt*.dtb | 多款 Wingtech 手机 | ❌ 手机，不适用 |

**关键共享基础**：`msm8916-ufi.dtsi` 被 `thwc-ufi001c.dts`、`thwc-uf896.dts` 等包含，定义了：
- eMMC (sdhc_1)
- USB Role Switch (pm8916_usbin)
- Modem (mpss, mba_mem, mpss_mem)
- WiFi/BT (wcnss, wcn3620)
- GPIO 按钮和 LED（在子 DTS 里具体指定 GPIO 引脚号）

---

## 三、启动链分析

### UFI 系列标准启动链

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   lk1st     │ ──▶ │   lk2nd     │ ──▶ │   kernel    │ ──▶ │   rootfs    │
│  (原厂)     │     │ (OpenStick) │     │ + DTB + ram │     │  (Debian)   │
│             │     │ extlinux.conf│    │             │     │             │
└─────────────┘     └─────────────┘     └─────────────┘     └─────────────┘
     │                    │                    │                    │
  原厂 aboot           链式加载            boot.img             rootfs 分区
                       支持 EFI/extlinux   (fastboot flash)     (fastboot flash)
```

### 刷机命令

```bash
# 1. 进入 fastboot
adb reboot bootloader
fastboot devices

# 2. 刷入 OpenStick 定制 bootloader（首次）
fastboot flash aboot aboot.mbn        # 替换原厂 aboot 为支持 extlinux 的版本
fastboot flash xbl hyp.mbn           # 可选：刷 hypervisor stub

# 3. 刷入内核（后续迭代只需这步）
fastboot flash boot boot.img         # boot.img 包含 kernel + DTB + 可选 initramfs

# 4. 刷入 rootfs
fastboot flash rootfs rootfs.img      # 直接写入 rootfs 分区的 raw 镜像
```

---

## 四、Armbian 框架适配难度分析

### 为什么难

| Armbian 标准流程 | UFI003 需求 | 差异点 |
|------------------|-------------|--------|
| U-Boot → boot.scr → armbianEnv.txt → extlinux.conf | lk2nd → extlinux.conf → kernel+DTB | **无需 U-Boot，boot.scr 体系需要绕过或重写** |
| ABL (Android BootLoader) + EDK2 + GRUB | lk2nd 链式加载 | **启动机制完全不同** |
| GPT 分区表 + FAT boot 分区 + ext4 rootfs | 原生分区：aboot/xbl/boot/modem/rootfs/... | **分区表非标准 GPT** |
| boot.img 通过 Android mkbootimg 打包 | 同样用 mkbootimg | ✅ 一致 |
| 内核用 family 级 patch 堆叠（vendor 分支优先） | msm8916 主线内核即可 | **可跳过 vendor patch，直接主线** |
| DTB 通过 armbianEnv.txt 或 U-Boot 指定 | extlinux.conf 的 FDT 字段 | **位置和加载方式不同** |
| 模组（WiFi/BT）内核模块 Armbian 自动处理 | wcnss 已主线化，无需额外 blob | ✅ 一致 |
| Modem firmware 通过 linux-firmware 包提供 | 需要从原机 modem 分区 dump | **闭源，不可再分发** |

### 可以做什么

1. **家族配置 `config/sources/families/msm8916.conf`** — 声明内核版本、主线源码、extlinux 启动脚本
2. **板子配置 `config/boards/ufi003.csc`** — 指定 DTB、分区表、firmware 处理
3. **定制 boot script** — 生成 extlinux.conf 而不是 boot.scr
4. **定制分区脚本** — 适配 msm8916 原生分区布局
5. **固件安装钩子** — 提示用户手动 dump modem 分区

### 最实际的路径：混合方案

```
Armbian rootfs 打包能力（debootstrap + 软件包 + armbian-config）
          +
OpenStick-Builder 内核构建（msm8916 主线 + DTB）
          +
手动/脚本化 rootfs → 分区刷入 + modem firmware 安装
```

这条路径的核心思路：
- 用 Armbian 提供的 Debian rootfs 基础 + armbian-config + armbian-hardware-optimization 等工具
- 用 OpenStick-Builder 或直接主线内核编译得到 boot.img
- 跳过 Armbian 的内核构建和 bootloader 步骤，直接刷入

---

## 五、固件处理说明

### 必须从原机 dump 的闭源 blob

| 固件 | 来源分区 | 用途 | 可否再分发 |
|------|---------|------|-----------|
| modem firmware | `/dev/block/by-name/modem` | LTE 通信必需 | ❌ **绝对不能** — 含 IMEI 校准、运营商配置 |
| modem_dtbo | `/dev/block/by-name/mdtp` 或类似 | Modem 设备树 | ❌ 同上 |
| WCNSS firmware | `/dev/block/by-name/modem` 或 vendor 分区 | WiFi/BT | ⚠️ Qualcomm 许可证，谨慎 |

### Dump 方法（需原机先解锁）

```bash
# 方法 A：ADB shell 中直接 dd
adb shell "dd if=/dev/block/by-name/modem of=/data/local/tmp/modem.img bs=4M"
adb pull /data/local/tmp/modem.img ./modem.img

# 方法 B：EDL 模式备份（推荐！完整备份所有分区）
adb reboot edl
edl rl backup_ufi003 --genxml
# 然后从 backup 中提取 modem 分区镜像

# 方法 C：从 rootfs 分区直接读
# 某些型号的 modem firmware 可在 /firmware 或 /vendor/firmware 下找到
adb shell "ls -la /firmware/"
adb shell "ls -la /vendor/firmware/"
```

### Modem firmware 安装位置

主线内核 msm8916 的 modem 驱动会在 `/lib/firmware/postmarketos/` 下查找固件。安装方式：

```bash
# 从 dump 中提取 modem firmware 目录
# OpenStick 社区已有提取工具，或手动用 binwalk
# 安装到系统：
cp -r modem_firmware/* /lib/firmware/postmarketos/
# 建议加软链接：
ln -sf /lib/firmware/postmarketos/ /lib/firmware/qcom
```

---

## 六、刷机与回滚指南

### 进入各种模式

| 模式 | 方法 | 检测工具 |
|------|------|---------|
| 正常 USB 模式 | 插上即进入，RNDIS 或 ACM | `adb devices` |
| Fastboot | `adb reboot bootloader` | `fastboot devices` |
| EDL 9008 | `adb reboot edl` 或 `fastboot oem reboot-edl`，或测试点短接 | `edl printgpt` |

### EDL 完整备份（首次刷机前必须做！）

```bash
# Windows 侧：先安装 Python 和 edl 工具
pip install edl

# 确认设备进入 EDL
edl printgpt

# 备份所有分区
edl rl backup_ufi003 --genxml
```

### 首次刷入 OpenStick bootloader + Linux

```bash
# 1. 下载 OpenStick v1 镜像 或 OpenStick-Builder 产物
#    https://github.com/OpenStick/OpenStick/releases

# 2. 解压得到 bootloader 和 boot.img/rootfs.img
#    典型文件：aboot.mbn, boot.bin, rootfs.bin

# 3. 进入 fastboot
adb reboot bootloader
fastboot devices

# 4. 刷入 bootloader（首次，之后跳过）
fastboot flash aboot aboot.mbn

# 5. 刷入 boot 和 rootfs
fastboot flash boot boot.bin
fastboot flash rootfs rootfs.bin

# 6. 重启
fastboot reboot
```

### 变砖救砖

1. 保持 Reset 键按下的同时插入 USB — 进入 EDL 9008
2. 用 EDL 写回备份：
   ```bash
   edl wb backup_ufi003.xml
   ```
3. 或者只刷回原厂固件（UFI 系列原厂固件可在网上找到）

---

## 七、最小可用镜像验收清单

| # | 功能 | 状态 | 调试成本 | 依赖 |
|---|------|------|---------|------|
| 1 | **内核启动** | 核心指标 | 🟢 低 | 主线内核 + 正确 DTB |
| 2 | **串口输出** | 核心指标 | 🟢 低 | UART TX 测试点，接 USB-TTL |
| 3 | **SSH 登录** | 核心指标 | 🟢 低 | USB RNDIS 或 WiFi AP |
| 4 | **文件持久化** | 核心指标 | 🟢 低 | rootfs 分区挂载正确 |
| 5 | **eMMC 可用** | 基础功能 | 🟢 低 | DTB sdhc_1 节点 |
| 6 | **USB Gadget/RNDIS** | 基础功能 | 🟡 中 | 需要配置 USB gadget |
| 7 | **WiFi AP** | 常用功能 | 🟡 中 | wcnss firmware + hostapd |
| 8 | **LTE Modem** | 常用功能 | 🔴 高 | **modem firmware 必须从原机 dump** |
| 9 | **多核 SMP** | 稳定要求 | 🟡 中 | 某些板型需降频率/核数防止过热 |
| 10 | **电池/充电** | 便携功能 | 🟡 中 | PM8916 驱动需验证 |
| 11 | **LED 控制** | 状态指示 | 🟢 低 | GPIO 操作 |
| 12 | **USB Host/OTG** | 扩展 | 🔴 高 | Role-switch 需要 sysfs 操作 |

---

## 八、当前环境限制与下一步

### 当前 Windows 主机状态

| 项目 | 状态 | 影响 |
|------|------|------|
| WSL2 | ❌ 内核未安装 | 无法在 WSL 里构建 |
| Docker | ❌ 未安装 | 无法容器化构建 |
| fastboot | ✅ 可用 | 可刷入设备 |
| adb | ✅ 可用 | 可连接设备 |
| git | ❌ 未安装 | 需要安装 |

### 在 Windows 上启用 WSL2（推荐）

```powershell
# 管理员 PowerShell
wsl --update                    # 更新 WSL2 内核
wsl --install -d Ubuntu         # 安装 Ubuntu
wsl --set-default-version 2     # 设为默认 WSL2
# 重启后首次启动 Ubuntu，设置用户名密码
```

### 在 Linux/WSL2 上构建 Armbian

```bash
# 1. 克隆 Armbian build
git clone https://github.com/armbian/build.git
cd build

# 2. 放置板级配置（见配置骨架目录）
#    config/sources/families/msm8916.conf
#    config/boards/ufi003.csc

# 3. 开始构建
./compile.sh BOARD=ufi003 BRANCH=edge RELEASE=trixie \
    BUILD_MINIMAL=yes KERNEL_CONFIGURE=no \
    BOARD_FIRMWARE_INSTALL="-full"
```

### 更推荐的构建路径：OpenStick-Builder

```bash
git clone --recurse-submodules https://github.com/kinsamanka/OpenStick-Builder.git
cd OpenStick-Builder
# 安装依赖后运行 build.sh，按提示选择设备型号和 rootfs 类型
# 产出 boot.bin, rootfs.bin, aboot.mbn
```

---

## 九、给真机用户的确认步骤

请在 UFI003 原厂固件上执行以下命令，帮助确认硬件细节：

```bash
# 1. 连接后确认 adb 可用
adb devices

# 2. 进入 shell 获取 SoC 信息
adb shell "cat /proc/cpuinfo"
adb shell "cat /proc/meminfo | head -5"
adb shell "cat /proc/device-tree/model"
adb shell "cat /proc/device-tree/compatible"

# 3. 查看分区布局
adb shell "ls -la /dev/block/by-name/"
adb shell "fdisk -l" 2>/dev/null || adb shell "cat /proc/partitions"

# 4. 查看 eMMC 容量
adb shell "df -h /data 2>/dev/null || df -h /"

# 5. 检查 modem firmware 位置
adb shell "ls -la /firmware/ 2>/dev/null"
adb shell "ls -la /vendor/firmware/ 2>/dev/null"
adb shell "ls -la /etc/firmware/ 2>/dev/null"

# 6. 确认 ADB 调试和 fastboot 是否可用
adb shell "getprop sys.usb.config"
adb reboot bootloader   # 如果成功，fastboot devices 应能识别

# 7. 完整备份（最重要！）
adb reboot edl          # 进入 EDL 9008
# 在 Windows 侧：
# pip install edl
# edl printgpt
# edl rl backup_ufi003 --genxml
```

---

## 十、风险与预期管理

| 风险 | 可能性 | 影响 | 缓解措施 |
|------|--------|------|---------|
| Modem firmware 缺失/不匹配 | 🔴 高 | LTE 不可用 | 首次刷机前必须 dump modem 分区 |
| 刷错 bootloader 导致无法启动 | 🟡 中 | 变砖 | EDL 备份后可救砖 |
| 多核供电不足死机 | 🟡 中 | 长时间运行崩溃 | 降频或禁用部分核心 |
| USB Role Switch 不稳定 | 🟡 中 | RNDIS 掉线 | 用 Y 型供电线，保持稳定供电 |
| 电池/充电驱动未就绪 | 🟡 中 | 便携场景受限 | 作为 USB 供电设备使用 |
| WiFi firmware 不匹配 | 🟢 低 | WiFi 不可用 | 主线内核自带 wcnss 固件 |
| Rootfs 空间不足 | 🟢 低 | 后期无法装包 | rootfs 分区约 3.2-3.8GB |

**建议的调试顺序**：
1. 先刷 OpenStick v1 测试内核能否启动 → 需要串口或 SSH
2. 确认 eMMC/USB/SSH 正常后再折腾 WiFi 和 LTE
3. Modem 最后搞，先把 modem 分区 dump 出来再研究
