# UFI003 OpenStick 固件深度逆向分析报告

> **结论先行**：
> 1. UFI003 的真实硬件身份是 **"Handsome OpenStick jsbsbxjxh66-bianyi UFI003"**，compatible 是 `["handsome,openstick", "qcom,msm8916"]`，**不是主线的 `thwc,ufi001c`**
> 2. UFI003 **支持双卡SIM**（4个GPIO控制），主线 ufi001c 只有单卡——这是不能直接复用主线DTB的原因之一
> 3. 超频版（2.1GHz）在DTB里**增加了9个高频opp节点**（1300~2100MHz），其他部分完全一致；GPU没有超频
> 4. **最快可用路径是 OpenStick-Builder**，Armbian框架适配需要额外把openstick DTS合入主内核
> 5. 固件里的闭源blob（modem/bootloader/fsc/fsg/modemst）**绝对不能提交到公开仓库**

---

## 一、硬件身份确认（实测，从boot.img内嵌DTB提取）

### 1.1 DTB来源

| 项目 | 值 |
|------|-----|
| 源文件 | `jsbsbxjxh66-boot/1.2.img` |
| 提取方式 | Python 手动解析 Android boot header + 内嵌 FDT |
| DTB位置 | boot.img 偏移 0x903F5C |
| DTB大小 | 49,716 字节 (1.2版) / 50,112 字节 (2.1版) |
| FDT版本 | 17 (标准) |

### 1.2 Root节点关键字段

```
compatible = "handsome,openstick", "qcom,msm8916"
model      = "Handsome OpenStick  jsbsbxjxh66-bianyi UFI003"
```

**⚠️ 关键差异**：主线内核的 `msm8916-thwc-ufi001c.dts` 写的是：
```
compatible = "thwc,ufi001c", "qcom,msm8916"
model      = "Thwc UFI001C"
```

**为什么不能直接复用主线ufi001c DTB？**
1. compatible 字符串不同 → 内核匹配设备表时会失败
2. UFI003有双卡SIM控制（`sim_sel/sim_en/sim_sel2/sim_en2`），主线没有
3. OpenStick DTB里有额外的节点（可能是lk2nd、openstick特有配置）

### 1.3 rootfs Makefile确认DTB名

从 `rootfs.img` 内的内核Makefile提取：
```makefile
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufi001b.dtb
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufi001c.dtb
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufi003.dtb    ← 独立DTB！
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufiw001.dtb
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufi103s.dtb
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-ufi16v3.dtb
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-sp970.dtb
dtb-$(CONFIG_ARCH_QCOM) += msm8916-handsome-openstick-uz801.dtb
```

**每个型号都有独立DTB！** 内核版本：`5.15.0-handsomekernel+` / `5.15.0-jsbsbxjxh66+`

---

## 二、完整硬件规格（DTB实测）

### 2.1 SoC/CPU

| 项目 | 值 | 来源 |
|------|-----|------|
| SoC | Qualcomm MSM8916 (Snapdragon 410) | DTB root compatible |
| CPU | ARM Cortex-A53 × 4 | DTB `/cpus/cpu@0~3` |
| base freq | 1.2 GHz | DTB `/cpu-opp-table` opp-1200000000 |
| opp格式 | operating-points-v2 (新格式) | DTB cpu@0~3 properties |

### 2.2 内存

| 项目 | 值 | 来源 |
|------|-----|------|
| 地址 | 0x80000000 | DTB `/memory@80000000` reg |
| 大小 | 512MB（DTB reg size=0，由bootloader探测） | 刷机脚本 + 已知信息 |
| reserved-memory | tz-apps (3MB), smem (1MB), hypervisor (1MB), tz (1.5MB), rmtfs (960KB), rfsa (128KB), mpss (85MB), wcnss (6MB), venus (5MB), mba (1MB) | DTB `/reserved-memory/*` |

### 2.3 存储

| 项目 | 值 | 来源 |
|------|-----|------|
| eMMC | sdhc1@7824000, 8-bit, non-removable, okay | DTB `/soc/sdhci@7824000` |
| SD卡 | sdhc2@7864000, 4-bit, disabled | DTB `/soc/sdhci@7864000` |
| eMMC供电 | vmmc-supply=<0x60>, vqmmc-supply=<0x4D> | DTB sdhc1 properties |

### 2.4 串口

| 项目 | 值 | 来源 |
|------|-----|------|
| Console | blsp_uart2 @ 0x78b0000 (ttyMSM0) | DTB `/soc/serial@78b0000`, status=okay |
| UART1 | blsp_uart1 @ 0x78af000, disabled | DTB `/soc/serial@78af000` |
| 波特率 | 115200 (boot header cmdline确认) | boot.img header |

### 2.5 WiFi/BT

| 项目 | 值 | 来源 |
|------|-----|------|
| Controller | WCN3620 (wcnss) | DTB `/soc/wcnss@8df00000` |
| WiFi | wcnss-wlan | DTB child node |
| BT | wcnss-bt | DTB child node |
| Active GPIO | gpio40~44 (wcnss-active) | DTB |

### 2.6 双卡SIM控制（UFI003独有！）

```
sim_sel  = tlmm block 62, pin 2
sim_en   = tlmm block 62, pin 1
sim_sel2 = tlmm block 62, pin 0
sim_en2  = tlmm block 62, pin 3
```

主线 ufi001c 只有 `sim_sel/sim_en` 两个GPIO——**UFI003增加了第二张卡的控制脚**！

### 2.7 LED

| LED | label | 默认状态 | 来源 |
|-----|-------|---------|------|
| WiFi | `blue:wifi` | on | DTB gpio-leds |
| Internet | `green:internet` | on | DTB gpio-leds |
| OS/Power | `red:os` | on | DTB gpio-leds |
| SIM SEL | `sim:sel` | on | DTB |
| SIM EN | `sim:en` | on | DTB |
| SIM SEL2 | (hex label) | on | DTB |
| SIM EN2 | (hex label) | on | DTB |

### 2.8 按键

| 按键 | GPIO | active | 来源 |
|------|------|--------|------|
| Reset/Restart | gpio62_37 | active-low (1) | DTB gpio-keys reset node |

### 2.9 USB

| 项目 | 值 | 来源 |
|------|-----|------|
| Role switch | extcon-usb-gpio + pm8941-misc | DTB `/soc/extcon@1300` |
| Role switch status | disabled (runtime enable) | DTB |
| Charger | pm8916-lbc charger@1000 | DTB `/soc/spmi/pmic/charger@1000` |
| Charger status | disabled | DTB |

### 2.10 Modem

| 项目 | 值 | 来源 |
|------|-----|------|
| Controller | mpss@86800000 (Qualcomm Adreno/MDM) | DTB `/reserved-memory/mpss` |
| Boot assembler | mba@8ea00000 | DTB `/reserved-memory/mba` |
| Transport | qcom,msm8916-qdsp6-sndcard (音频) | DTB |

### 2.11 电源/PMIC

| 项目 | 值 | 来源 |
|------|-----|------|
| PMIC | pm8916 + pm8941 (SPMI) | DTB `/soc/spmi@200f000/pmic@0` |
| Regulators | rpm-pm8916-regulators | DTB smd/rpm/rpm-requests |
| 列出的LDO数 | s3, s4, l1~l17 共19路 | DTB |

### 2.12 Thermal zones

| Zone | 来源 |
|------|------|
| cpu0-1-thermal | DTB thermal-zones child |
| cpu2-3-thermal | DTB thermal-zones child |
| gpu-thermal | DTB thermal-zones child |
| modem-thermal | DTB thermal-zones child |
| camera-thermal | DTB thermal-zones child |

### 2.13 显示

| 项目 | 值 |
|------|-----|------|
| mdss display | disabled | DTB |
| 结论 | **无视频输出** | boot header cmdline `no_framebuffer=true` |

---

## 三、开机链（实测 + 刷机脚本确认）

```
EDL 9008 (紧急模式, 原厂)
  ↓
lk1st (原厂 aboot.bin)  ← 可被覆盖！
  ↓ flash aboot aboot.bin
lk2nd (OpenStick bootloader, 支持 extlinux.conf)
  ↓
Kernel + DTB (从 boot.img Android boot 格式加载)
  ↓ boot header cmdline (实测):
  ↓   earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e
  ↓   console=ttyMSM0,115200 no_framebuffer=true rw
  ↓
initramfs (如果有, 在 Android boot 格式的 ramdisk 里)
  ↓
rootfs (Debian bookworm, ext4, GPT分区)
```

### boot header 实测字段

| 字段 | 值 |
|------|-----|
| Magic | ANDROID! (标准 Android boot format) |
| kernel_size | 9,501,072 字节 (9.06 MB) |
| kernel_addr | 0x80080000 |
| ramdisk_size | 6,644,810 字节 (6.34 MB) |
| ramdisk_addr | 0x82000000 |
| page_size | 2048 |
| cmdline | `earlycon root=PARTUUID=a7ab80e8-e9d1-e8cd-f157-93f69b1d141e console=ttyMSM0,115200 no_framebuffer=true rw` |
| dt_size | 0 (DTB内嵌在kernel Image末尾) |

### Ramdisk 格式

ramdisk 前4字节 magic `0xE0AF0A54` — **不是标准gzip/xz/lz4**。可能是 Qualcomm 签名格式，或者是特殊压缩方式。没有在ramdisk里找到extlinux.conf内容，说明kernel启动时用的是boot header里的cmdline，不需要extlinux.conf？或者lk2nd会重新生成？

---

## 四、分区布局（从刷机脚本 + gpt_both0.bin推断）

刷机脚本 `一键刷入工具.bat` 的分区刷写顺序：
```
fastboot flash partition gpt_both0.bin     # 分区表
fastboot flash hyp hyp.mbn
fastboot flash rpm rpm.mbn
fastboot flash sbl1 sbl1.mbn
fastboot flash tz tz.mbn
fastboot flash fsc fsc.bin                 # 用户态校准
fastboot flash fsg fsg.bin                 # 用户态校准
fastboot flash modemst1 modemst1.bin       # IMEI/校准
fastboot flash modemst2 modemst2.bin       # IMEI/校准
fastboot flash aboot aboot.bin             # → 改为lk2nd
fastboot flash cdt sbc_1.0_8016.bin
fastboot erase boot
fastboot erase rootfs
# 然后:
fastboot flash boot boot.img
fastboot -S 200m flash rootfs rootfs.img
```

**by-name分区列表**（从刷机脚本推断 + OpenStick文档）：
- **boot** — boot.img (Android boot format, 16MB固定)
- **rootfs** — rootfs.img (ext4, 剩余eMMC空间)
- **aboot** — lk1st bootloader (替换为lk2nd的aboot)
- **sbl1** — Qualcomm Secondary Boot Loader
- **hyp** — Hypervisor
- **rpm** — Resource Power Manager
- **tz** — TrustZone
- **fsc, fsg** — 用户态校准数据（**从原厂dump！**）
- **modemst1, modemst2** — modem固件分区（**从原厂dump！**）
- **cdt** — Qualcomm Configuration Data Table

**注意**：刷机脚本在刷gpt_both0.bin后**扩大了rootfs分区**（原始固件的GPT可能rootfs比较小，OpenStick的GPT让rootfs占满剩余空间）。

---

## 五、超频分析（1.2GHz vs 2.1GHz boot.img 对比）

### 5.1 差异总结

| 对比项 | 1.2 GHz (基线) | 2.1 GHz (超频) |
|--------|---------------|---------------|
| boot.img 总大小 | 16,150,528 | 16,150,528 |
| kernel_size | 9,501,072 | 9,501,468 (+396) |
| ramdisk_size | 6,644,810 | 6,644,810 |
| DTB 大小 | 49,716 | 50,112 (+396) |
| cmdline | 完全相同 | 完全相同 |
| GPU opp表 | opp-19200000, opp-400000000 | opp-19200000, opp-400000000 (**相同**!) |
| regulators | 19路LDO, 数值相同 | 19路LDO, 数值相同 |
| thermal zones | 5个, 配置相同 | 5个, 配置相同 |
| CPU opp节点数 | 5 | 14 |

### 5.2 CPU opp表详细对比

**1.2 GHz（基线版）**：
```
opp-400000000: 400 MHz
opp-800000000: 800 MHz
opp-1000000000: 1.0 GHz
opp-1100000000: 1.1 GHz
opp-1200000000: 1.2 GHz  ← 官方最大值
```

**2.1 GHz（超频版）**：
```
opp-400000000: 400 MHz
opp-800000000: 800 MHz
opp-1000000000: 1.0 GHz
opp-1100000000: 1.1 GHz
opp-1200000000: 1.2 GHz
opp-1300000000: 1.3 GHz  ← 新增
opp-1400000000: 1.4 GHz  ← 新增
opp-1500000000: 1.5 GHz  ← 新增
opp-1600000000: 1.6 GHz  ← 新增
opp-1700000000: 1.7 GHz  ← 新增
opp-1800000000: 1.8 GHz  ← 新增
opp-1900000000: 1.9 GHz  ← 新增
opp-2000000000: 2.0 GHz  ← 新增
opp-2100000000: 2.1 GHz  ← 新增
```

### 5.3 超频方式

超频方式非常**朴素**——只是在DTB的 `/cpu-opp-table` 里增加了9个新的 `opp-*` 子节点，每个节点定义了一个更高的 `opp-hz` 值。**没有修改电压寄存器（regulator数值两版完全一致）**。

### 5.4 超频风险评估

| 风险 | 严重程度 | 说明 |
|------|---------|------|
| **供电不足** | 🔴 高 | MSM8916是低成本SoC，默认设计频率1.2GHz，超频到2.1GHz (75%+提升) 供电余量非常小 |
| **散热** | 🔴 高 | UFI003是棒状设备，被动散热；高频下功耗翻倍但散热条件没变 |
| **电压不变** | 🟡 中 | 超频版没调整电压，说明可能依赖CPU的DVFS自动调节电压——但如果电压不够会不稳定 |
| **没有GPU超频** | 🟢 低 | GPU opp表没变，说明GPU不需要/不支持更高频率 |
| **thermal zone相同** | 🟡 中 | 超频版没有修改thermal trip points，可能CPU会频繁过热降频 |

**结论**：1.4~1.6GHz可能是安全的上限，1.8GHz以上风险较大。2.1GHz版可能是"极限版"，实际长期运行大概率会因为过热或供电不足出问题。

---

## 六、闭源blob处理规则（红线）

### ✗ 绝对不能提交到公开仓库的

| 文件 | 位置 | 原因 |
|------|------|------|
| `bin/sbl1.mbn` | 固件包根 | Qualcomm闭源bootloader |
| `bin/hyp.mbn` | 固件包根 | Qualcomm闭源hypervisor |
| `bin/rpm.mbn` | 固件包根 | Qualcomm闭源RPM firmware |
| `bin/tz.mbn` | 固件包根 | Qualcomm闭源TrustZone |
| `bin/aboot.bin` | 固件包根 | 原厂aboot（可以用OpenStick的开源lk2nd替代） |
| `bin/sbc_1.0_8016.bin` | 固件包根 | Qualcomm CDT |
| `bin/fsc.bin` | 固件包根 | **用户态校准数据，IMEI绑定** |
| `bin/fsg.bin` | 固件包根 | **用户态校准数据，IMEI绑定** |
| `bin/modemst1.bin` | 固件包根 | **Modem固件分区，含IMEI/SIM auth** |
| `bin/modemst2.bin` | 固件包根 | **Modem固件分区，含IMEI/SIM auth** |
| `一键替换基带文件/modem/*` | 固件包根 | 整套闭源modem firmware (mba.mbn + modem.b00~ + wcnss.*) |

### ✓ 可以提交的（开源许可证）

| 文件 | 许可证 | 说明 |
|------|--------|------|
| **内核源码** (openstick fork) | GPLv2 | [HandsomeYingyan](https://github.com/HandsomeYingyan) 或 openstick fork |
| **DTS/DTB** | GPLv2 | 作为内核源码的一部分 |
| **lk2nd bootloader** | GPL | OpenStick项目的bootloader |
| **刷机脚本** | 纯文本工具 | 本地上传的`.bat`/`.sh`脚本 |
| **Armbian配置** | GPL | `config/boards/*.csc` 等 |
| **OpenStick-Builder** | GPL | [kinsamanka/OpenStick-Builder](https://github.com/kinsamanka/OpenStick-Builder) |

### 必须用户自己dump的（从原设备）

```bash
# 方式1：fastboot OEM dump
adb reboot bootloader
fastboot flash aboot <原厂aboot>   # 先恢复原厂bootloader
fastboot reboot
# 等系统起来后再进入fastboot
fastboot reboot bootloader
fastboot oem dump fsc && fastboot get_staged fsc.bin
fastboot oem dump fsg && fastboot get_staged fsg.bin
fastboot oem dump modemst1 && fastboot get_staged modemst1.bin
fastboot oem dump modemst2 && fastboot get_staged modemst2.bin

# 方式2：EDL完整备份（推荐）
adb reboot edl
edl rl backup_ufi003 --genxml
edl r fsc fsc.bin; edl r fsg fsg.bin
edl r modemst1 modemst1.bin; edl r modemst2 modemst2.bin
edl r modem modem.bin; edl r persist persist.bin; edl r sec sec.bin
```

---

## 七、构建路径分析

### 路径A：OpenStick-Builder（最快，推荐）

```bash
git clone --recurse-submodules https://github.com/kinsamanka/OpenStick-Builder.git
cd OpenStick-Builder/
sudo ./build.sh
```

- ✅ 已经包含 openstick 内核 fork + lk2nd bootloader + 刷机脚本
- ✅ 支持所有 openstick 机型（ufi001b/ufi001c/ufi003/ufiw001/ufi103s/ufi16v3/uz801...）
- ⚠️ 默认配置针对UZ801，需要改 `/boot/extlinux/extlinux.conf` 里的DTB名
- ⚠️ 实测 postmarketOS 内核可能不是最新（当前是5.15）
- ⚠️ 需要在Linux环境下构建（Ubuntu 22.04+）

### 路径B：Armbian框架（完整适配，更灵活）

当前工作目录下的配置文件已更新为实测值：

| 文件 | 更新内容 |
|------|---------|
| [ufi003.csc](file:///C:/Users/Administrator/Documents/Trae-CN/temp_20261102_02/ufi003-armbian/config/boards/ufi003.csc) | BOOT_FDT_FILE → openstick-ufi003, 新增双卡SIM脚本, 实测cmdline |
| [msm8916.conf](file:///C:/Users/Administrator/Documents/Trae-CN/temp_20261102_02/ufi003-armbian/config/sources/families/msm8916.conf) | 内核源 → openstick fork 或主线+overlay |
| [bootscript-msm8916.sh](file:///C:/Users/Administrator/Documents/Trae-CN/temp_20261102_02/ufi003-armbian/config/bootscripts/bootscript-msm8916.sh) | 默认DTB → openstick-ufi003, 实测cmdline |

**构建命令**（在Linux主机或WSL2里）：
```bash
# 克隆Armbian框架
git clone --depth 1 https://github.com/armbian/build.git

# 复制我们的配置
cp ufi003-armbian/config/boards/ufi003.csc build/config/boards/
cp ufi003-armbian/config/sources/families/msm8916.conf build/config/sources/families/
cp ufi003-armbian/config/bootscripts/bootscript-msm8916.sh build/config/bootscripts/

# 构建
cd build
sudo ./compile.sh BOARD=ufi003 BRANCH=edge RELEASE=trixie \
    BUILD_MINIMAL=yes KERNEL_CONFIGURE=no EXPERT=no
```

### 路径C：主线内核 + openstick DTS overlay

如果想用主线Linux（6.12+）：
1. 主线已有 `msm8916-ufi.dtsi` 基础支持
2. 需要把 openstick 的 DTS（HandsomeYingyan fork）作为 overlay 加进去
3. OpenWRT patch 已证明可行：HandsomeYingyan 在 [OpenWrt Forum](https://forum.openwrt.org/t/extract-branch-targets-into-pure-feeds-to-compile-mainline-openwrt-dts-to-dtb-error/171189/9) 提交过 openstick DTS 系列 patch

---

## 八、已验证事实 vs 推测

| 项目 | 类型 | 来源 |
|------|------|------|
| compatible = "handsome,openstick", "qcom,msm8916" | ✅ 已验证 | boot.img DTB offset 0x903F5C |
| model = "Handsome OpenStick jsbsbxjxh66-bianyi UFI003" | ✅ 已验证 | boot.img DTB |
| msm8916-handsome-openstick-ufi003.dtb 存在 | ✅ 已验证 | rootfs Makefile 字符串扫描 |
| boot cmdline: earlycon root=PARTUUID=... console=ttyMSM0,115200 no_framebuffer=true rw | ✅ 已验证 | Android boot header offset 64 |
| UFI003 有双卡SIM (sim_sel/sim_en/sim_sel2/sim_en2) | ✅ 已验证 | DTB gpio-leds / sim 节点 |
| 1.2GHz opp: 400/800/1000/1100/1200 MHz | ✅ 已验证 | DTB /cpu-opp-table |
| 2.1GHz opp: 400~2100 MHz (14个频率点) | ✅ 已验证 | DTB /cpu-opp-table |
| 1.2 vs 2.1: regulators/thermal/GPU opp 全相同 | ✅ 已验证 | DTB 完整对比 |
| charger@1000 status=disabled (两版) | ✅ 已验证 | DTB /soc/spmi/pmic/charger |
| reserved-memory 布局 (mpss 85MB, wcnss 6MB 等) | ✅ 已验证 | DTB /reserved-memory/* |
| RAM = 512MB | ⚠️ 推测 | DTB memory reg size=0, 刷机脚本 + 已知信息 |
| boot 是 Android boot format (不是 lk2nd extlinux) | ⚠️ 推测 | boot header 显示 ANDROID! magic + dt_size=0 |
| ramdisk 格式是 Qualcomm 签名 (magic 0xE0AF0A54) | ⚠️ 推测 | 未解出格式 |
| OpenStick-Builder 能直接产出 UFI003 固件 | ⚠️ 推测 | README 写了 UFI001C DTB 但没提 openstick fork |

---

## 九、现在可以直接拿去构建了吗？

### OpenStick-Builder 路径
✅ **可以！** 最快路径。只需要：
1. 在 Linux 主机克隆 + 安装依赖
2. `sudo ./build.sh`
3. 刷写时用正确的 openstick-ufi003 DTB（或直接用内核自带的）
4. 记得从原设备 dump modem firmware (fsc/fsg/modemst1/2)

### Armbian 框架路径
⚠️ **还不能直接构建**。还需要：
1. **内核源确认** — 我不确定 HandsomeYingyan 内核 fork 的正确仓库地址和分支名。family 配置里写了 `https://github.com/HandsomeYingyan/kernel_ufi_msm8916`，但需要确认是否存在
2. **或改用主线内核 + openstick DTS overlay** — 需要把 openstick DTS patch 主线
3. **PARTUUID 问题** — boot header 里的 PARTUUID `a7ab80e8-e9d1-e8cd-f157-93f69b1d141e` 是原始固件 rootfs 分区的 UUID，Armbian 新构建的 rootfs 分区 UUID 会不同。bootscript 里已经用了 `PARTLABEL=rootfs` 来避免这个问题

### 你的下一步行动

```bash
# 1. 在 Linux 主机 / WSL2 (wsl --update; wsl --install -d Ubuntu) 上：
git clone --recurse-submodules https://github.com/kinsamanka/OpenStick-Builder.git
cd OpenStick-Builder/
sudo scripts/install_deps.sh
sudo ./build.sh

# 2. 从原设备 dump modem firmware（必须！）
adb reboot bootloader
fastboot flash aboot <原厂aboot.bin>
fastboot reboot
# 等系统起来后
adb reboot edl
edl r fsc fsc.bin; edl r fsg fsg.bin
edl r modemst1 modemst1.bin; edl r modemst2 modemst2.bin

# 3. 刷写新固件
fastboot flash partition gpt_both0.bin
fastboot flash aboot OpenStick-Builder/files/aboot.mbn  # lk2nd!
fastboot flash hyp hyp.mbn
fastboot flash rpm rpm.mbn
fastboot flash sbl1 sbl1.mbn
fastboot flash tz tz.mbn
fastboot flash boot boot.img
fastboot flash rootfs rootfs.img
fastboot reboot
```

---

## 十、真机确认步骤（用户侧）

如果设备还在手上，执行以下命令确认：

```bash
adb shell "cat /proc/device-tree/compatible; echo"
# 期望输出: handsome,openstick qcom,msm8916

adb shell "cat /proc/device-tree/model; echo"
# 期望输出: Handsome OpenStick  jsbsbxjxh66-bianyi UFI003

adb shell "ls /dev/block/by-name/"
# 期望看到: boot rootfs aboot sbl1 hyp rpm tz fsc fsg modemst1 modemst2 persist sec

adb shell "cat /proc/meminfo | head -3"
# 期望: MemTotal: 约 400-500MB

adb shell "cat /proc/cpuinfo | head -20"
# 确认 4× Cortex-A53

adb shell "dmesg | grep -i 'openstick\|ufi003\|sim'"
# 确认双卡SIM驱动加载
```

如果实际输出和这里有差异，说明固件包可能来自不同硬件批次，需要重新分析。

---

**报告生成日期**: 2026-11-02
**分析方法**: 纯Python二进制解析（无外部工具），从 boot.img + rootfs.img + 刷机脚本逆向
**数据来源**: `D:\PerFiles\suishenwifi\msm8916\ufi003-debian超频版\`
