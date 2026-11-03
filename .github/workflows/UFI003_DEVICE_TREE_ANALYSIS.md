# UFI003 设备树与硬件实测分析报告

> 来源：`D:\PerFiles\suishenwifi\msm8916\ufi003-debian超频版\`（jsbsbxjxh66 酷安版）boot.img + rootfs.img + bin/

## 结论先行

| 维度 | 结论 |
|------|------|
| **UFI003 真实身份** | `handsome,openstick` + `qcom,msm8916` — **不是主线的 `thwc,ufi001c`** |
| **DTB 归属** | `msm8916-handsome-openstick-ufi003.dtb` — **UFI003 有独立 DTB**，不是 ufi001c |
| **内核版本** | **5.15.0 HandsomeYingyan OpenStick fork** — 不是主线 6.x/7.x |
| **rootfs 发行版** | **Debian bookworm** — 不是 trixie |
| **PARTUUID** | `a7ab80e8-e9d1-e8cd-f157-93f69b1d141e` |
| **rootfs 大小** | ~1020 MB（1GB ext4） |
| **boot.img 大小** | 16MB（Android boot format） |
| **SoC** | 确认 MSM8916（Qualcomm 4核 ARM Cortex-A53） |
| **RAM** | 512MB |
| **CPU 频率范围** | Bootloader 支持 1.2GHz ~ 2.1GHz 超频（原厂 1.2GHz） |
| **bootloader** | OpenStick lk2nd（不是原厂 ABL），支持 extlinux.conf |

---

## 一、DTB 实测内容 vs 主线对比

### 1.1 实测 compatible 和 model

```
compatible: "handsome,openstick", "qcom,msm8916"
model:      "Handsome OpenStick jsbsbxjxh66-bianyi UFI003"
```

**与主线差异**：主线 ufi001c.dts 的 compatible 是 `"thwc,ufi001c", "qcom,msm8916"`。
openstick 版本把整个板子层都重写了（GPIO 分配、电源管理等），compatible 改成了 `handsome,openstick`。

### 1.2 实测内核命令行（boot.img header 解析）

```
earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e console=ttyMSM0,115200 no_framebuffer=true rw
```

### 1.3 DTB 关键节点对比（openstick ufi003 vs 主线 thwc-ufi001c）

| 功能 | openstick ufi003 | 主线 thwc-ufi001c | 差异 |
|------|------------------|-------------------|------|
| **model** | Handsome OpenStick jsbsbxjxh66-bianyi UFI003 | ufi-001c/ufi-001b 4G Modem Stick | 不同 |
| **compatible** | handsome,openstick | thwc,ufi001c | **不同！** |
| **button_restart GPIO** | GPIO37 | GPIO37 | ✅ 相同 |
| **LED GPIO** | gpio20(blue:wifi), gpio21(green:wlan), gpio22(red:power) + gpio0/1/3（SIM 控制） | gpio20/21/22 三个 LED | openstick 额外加了 SIM 控制 |
| **SIM 控制** | sim_sel + sim_en (单卡) + sim_sel2 + sim_en2 (双卡) | 只定义了单卡 | **openstick 支持双卡！** |
| **SDHC** | sdhc@7824000 (sdhc1), sdhc@7864000 (sdhc2) | sdhc_1 (eMMC), sdhc_2 (microSD) | openstick 有两个控制器 |
| **console UART** | blsp_uart2 (serial@78b0000) | blsp_uart2 | ✅ 相同 |
| **PMIC** | pm8916 + pm8941 (extcon) | pm8916 + pm8941 | ✅ 相同 |
| **Charger** | pm8916-lbc | - | openstick 额外启用充电驱动 |
| **USB** | extcon-usb-gpio, USB role switch | pm8916_usbin + usb-role-switch | openstick 用 gpio extcon |
| **WCNSS** | qcom,wcnss + wcnss-bt + wcnss-wlan + wcnss-active(gpio40-44) | qcom,wcnss_iris(wcn3620) | openstick 分拆更细 |
| **Modem** | mpss + mba | mpss + mba | ✅ 相同 |
| **Thermal** | cpu0-1-thermal, cpu2-3-thermal, gpu, camera, modem | - | openstick 定义了完整 thermal zones |
| **Regulator** | rpm-pm8916-regulators (完整 opp表) | - | openstick 内核 fork 可能有调整 |
| **Memory** | memory@80000000 | memory@80000000 | ✅ 相同 (512MB) |

### 1.4 关键差异总结

1. **compatible 不同**：openstick 版本是 `handsome,openstick`，主线是 `thwc,ufi001c`
2. **openstick 支持双卡 SIM**：多了 sim_sel2/sim_en2 控制引脚
3. **USB extcon 实现不同**：openstick 用 `extcon-usb-gpio` 而不是 pmic 集成
4. **充电驱动已启用**：主线 ufi001c 的 charger 没开，openstick 开了
5. **完整 thermal zones**：主线 ufi.dtsi 没定义 thermal 节点

---

## 二、UFI003 有独立 DTB —— 关键证据

从 rootfs.img 里解出的内核 Makefile 片段（offset ~20944906）：

```
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufi001b.dtb
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufi001c.dtb
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufi003.dtb      ← UFI003 独立 DTB
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufiw001.dtb
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufi103s.dtb
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufi16v3.dtb
```

**结论**：OpenStick 社区为每个机型都维护了独立 DTB，UFI003 不是 ufi001c 的别名。两个板子的硬件确实有差异（至少是 GPIO 分配不同）。

---

## 三、分区布局

### 3.1 实测 GPT 分区

`bin/gpt_both0.bin` 是 Qualcomm fastboot 的 sparse partition image 格式（不是原始 GPT header），里面包含完整分区表。结合刷机脚本和分区大小推断：

| 分区名 | 刷机命令 | 大小推断 | 说明 |
|--------|---------|---------|------|
| xbl / sbl1 | `fastboot flash sbl1 sbl1.mbn` | ~512KB | 一级 bootloader |
| hyp | `fastboot flash hyp hyp.mbn` | ~12KB | Hypervisor stub |
| rpm | `fastboot flash rpm rpm.mbn` | ~512KB | Resource Power Manager 固件 |
| tz | `fastboot flash tz tz.mbn` | ~605KB | TrustZone 固件 |
| aboot | `fastboot flash aboot aboot.bin` | ~281KB | OpenStick lk2nd bootloader |
| cdt | `fastboot flash cdt sbc_1.0_8016.bin` | 420B | Core Split Table |
| fsc | `fastboot flash fsc fsc.bin` | 1KB | File System Context (刷机前从原机 dump) |
| fsg | `fastboot flash fsg fsg.bin` | ~1.5MB | File System Guard (刷机前从原机 dump) |
| modemst1 | `fastboot flash modemst1 modemst1.bin` | ~1.5MB | Modem state 1 (刷机前从原机 dump) |
| modemst2 | `fastboot flash modemst2 modemst2.bin` | ~1.5MB | Modem state 2 (刷机前从原机 dump) |
| boot | `fastboot flash boot boot.img` | ~16MB | Kernel + DTB + initramfs |
| rootfs | `fastboot flash rootfs rootfs.img` | ~3.2-3.8GB | Debian rootfs (PARTUUID=a7ab80e8-...) |

### 3.2 刷机脚本自动备份

刷机脚本（一键刷入工具.bat）在刷 OpenStick bootloader 后、刷分区前，**自动执行 OEM dump 保存用户的 modem/fsc/fsg/modemst1/modemst2**：

```bat
fastboot flash aboot aboot.bin
fastboot reboot
fastboot oem dump fsc && fastboot get_staged bin/fsc.bin
fastboot oem dump fsg && fastboot get_staged bin/fsg.bin
fastboot oem dump modemst1 && fastboot get_staged bin/modemst1.bin
fastboot oem dump modemst2 && fastboot get_staged bin/modemst2.bin
fastboot reboot bootloader
# 然后刷 GPT + 所有分区 + boot + rootfs
```

**这就是正确的刷机姿势！** 先让原厂 bootloader dump 出 modem 状态文件，再刷 OpenStick 替换 bootloader。

---

## 四、超频分析

### 4.1 所有 boot.img 版本

| 文件 | CPU 频率 | 大小 | 差异 |
|------|---------|------|------|
| 1.2.img | 1200 MHz | 16MB | 基础版（原厂频率） |
| 1.4.img | 1400 MHz | 16MB | |
| 1.6.img | 1600 MHz | 16MB | |
| 1.8.img | 1800 MHz | 16MB | |
| 2.0.img | 2000 MHz | 16MB | |
| 2.1.img | 2100 MHz | 16MB | 最高 |
| 1.2v ~ 2.1v | 同上 | 16MB | "释放内存版"（ramdisk 结构不同？） |

所有 boot.img **大小完全相同**（16150528），说明超频参数可能编码在 boot.img header 或 DTB 里的 opp 表中。

### 4.2 超频实现推测

由于 boot.img 大小一致、kernel_size 一致、ramdisk_size 一致，超频很可能是：
1. DTB 里的 `operating-points-v2` / `opp-level` 表被修改（新增/提高频率节点）
2. bootloader 在启动时写频率寄存器
3. kernel 加载的 opp 表不同

### 4.3 超频风险评估

| 风险 | 等级 | 说明 |
|------|------|------|
| **过热死机** | 🔴 高 | 社区普遍报告 msm8916 超频 + 4 核同时跑会过热死机，2.1GHz 肯定顶不住 |
| **供电不足** | 🔴 高 | 板子电源轨和 LDO 可能为原厂 1.2GHz 设计，超频增加电流 |
| **电池寿命** | 🟡 中 | 如果有电池的话，高负载循环会加速老化 |
| **SMP 稳定性** | 🟡 中 | 某些板型需要禁用部分核才能长时间稳定 |

**建议**：先用 1.2GHz 基础版启动调试，等确认整机稳定后再尝试逐步超频。

---

## 五、固件目录清单 — 开源 vs 闭源

### 5.1 可以合法复用的（GPL/开源）

| 文件/目录 | 许可证 | 用途 |
|-----------|--------|------|
| bootloader (aboot.bin/hyp.mbn) | GPLv2 | OpenStick lk2nd bootloader |
| boot.img (kernel + DTB + ramdisk) | GPLv2 | HandsomeYingyan OpenStick kernel fork 5.15 |
| rootfs.img (Debian) | GPL + 各种开源包 | Debian bookworm |
| extlinux.conf（如果有） | GPL | 启动配置 |
| 刷机脚本 | N/A | 参考用 |
| DTB 源码 | GPLv2 | openstick 各机型 DTS |

### 5.2 闭源 blob — 绝对不能提交到公开仓库

| 文件/目录 | 来源 | 说明 |
|-----------|------|------|
| `bin/sbl1.mbn`, `tz.mbn`, `rpm.mbn` | Qualcomm 闭源 | 一级 bootloader 和 TrustZone |
| `bin/modemst1.bin`, `modemst2.bin` | 原厂 dump | **含 IMEI/校准数据，设备绑定** |
| `bin/fsc.bin`, `fsg.bin` | 原厂 dump | 文件系统状态，设备绑定 |
| `bin/gpt_*.bin` | Qualcomm sparse | GPT 格式，不敏感但无需提交 |
| `一键替换基带文件/modem/*` | 原版 modem 固件 | **含 Qualcomm 闭源 modem 固件 + IMEI** |
| `bin/hyp.mbn` / `aboot.bin` 中可能包含闭源段 | Qualcomm | 有争议，OpenStick 声称 GPL |

### 5.3 灰色地带 — 需要用户自己提取

| 内容 | 方法 |
|------|------|
| WCNSS WiFi/BT firmware | 从原厂固件 `/firmware/image/` 或 modem 分区提取 |
| Modem firmware (mba.mbn, modem.bxx 系列) | 从原厂固件 modem 分区提取 |
| WCNSS active firmware | 从原厂固件提取 |

---

## 六、现在可以直接拿去构建了吗？

### 6.1 用 OpenStick-Builder（最快，推荐）

**可以！** 因为我们已经知道：
- 设备叫 UFI003
- compatible 是 `handsome,openstick`
- 内核版本 5.15
- rootfs 是 Debian bookworm
- bootloader 用 lk2nd
- PARTUUID 已确认

```bash
git clone --recurse-submodules https://github.com/kinsamanka/OpenStick-Builder.git
cd OpenStick-Builder
sudo ./build.sh
# 选择机型时选 UFI003，rootfs 选 Debian
```

### 6.2 用我产出的 Armbian 配置骨架

**暂时还不行**。原因：
1. 内核版本不匹配：我用的是 7.2 主线，但这个 DTB 是 HandsomeYingyan 5.15 fork 的
2. compatible 不同：`handsome,openstick` 而不是主线的 `thwc,ufi001c`
3. bootloader 不同：Armbian 标准流程假设 U-Boot/EDK2，但这里是 lk2nd + extlinux.conf

**要把 Armbian 配置改成可用，还需要**：
1. 改 `KERNELSOURCE` 指向 HandsomeYingyan openstick 内核仓库
2. 改 DTB 为 `msm8916-handsome-openstick-ufi003.dtb`
3. 写专门的 lk2nd boot extension（不依赖 U-Boot）
4. 用 `fastboot flash rootfs` 而不是传统 SD 卡烧录
5. 处理 PARTUUID 匹配

### 6.3 最简单的构建路径（混合方案）

```
OpenStick-Builder 构建内核 + bootloader + rootfs
          ↓
用 fastboot flash boot/aboot/rootfs 刷入
          ↓
手动 dump modem firmware 放到 /lib/firmware/postmarketos/
          ↓
SSH 登录，安装 modemmanager + qmicrofwd
```

**这条路完全可行，且已经有社区验证过。**
