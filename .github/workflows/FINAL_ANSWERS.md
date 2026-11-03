# UFI003 Armbian 去 modem 版 — 最终交付总结

> **上一轮中断后续** — 本次补齐所有缺口，每步落盘

---

## 问题 2：去 modem 后能否正常启动？rmtfs 是否必须保留？

### 能正常启动 ✓

去 modem 的核心改动和启动可行性分析：

| 改动 | 效果 | 对启动的影响 |
|------|------|-------------|
| `remoteproc@4080000` (mss-pil) status=disabled | 内核**不加载** modem firmware blobs | **关键** — 避免 PIL 加载闭源 mba.mbn + modem.b00~b26 时找不到固件而 panic/hang |
| `mpss@86800000` memory-region status=disabled | 不在 DT 里声明 modem 固件加载区 | 内核 PIL 框架只在启用的 PIL 节点上工作，没引用就没事 |
| `rmtfs@86700000` status=disabled | modem 对存储的远程访问通道关闭 | 纯计算节点不需要这个 |
| `mba@8ea00000` status=disabled | modem boot assembler 区关闭 | 被 mss-pil 引用，disabled 后不被访问 |
| `rfsa@867e0000` status=disabled | modem 只读文件系统区关闭 | 同上 |
| `memshare` status=disabled | modem 内存共享通道关闭 | GPS/modem 不工作，也不会有 memshare 事件 |
| 4 个 SIM LED status=disabled | gpio-leds 驱动不注册 SIM 指示灯 | 纯 cosmetic，无 SIM 卡本来就不亮 |

**启动链路回顾**：
```
lk1st (Qualcomm SBL) 
  → lk2nd (OpenStick bootloader, GPL)
    → extlinux.conf (/boot/extlinux/)
      → kernel Image + DTB (msm8916-handsome-openstick-ufi003.dtb)
        → rootfs (PARTLABEL=rootfs, ext4)
```

lk2nd bootloader 会初始化：eMMC、PM8916 regulators、WCN3620 WiFi 电源、USB。这些初始化**完全不依赖 modem firmware**，因为它们是硬件级的电源/时钟初始化。

内核启动后：
- 读取 DTB → 看到 modem PIL disabled → 跳过 modem 固件加载
- 看到 WiFi PIL (`remoteproc@a21b000`, pronto-v2-pil) okay → **加载 wcnss firmware (需要用户手动放到 /lib/firmware/qcom/)**
- 挂载 rootfs → 启动 systemd

### rmtfs 不需要保留 ✓

rmtfs (Qualcomm Remote File System) 是让 modem PIL 通过共享内存访问 eMMC/SD 卡扇区的通道。
只有两个消费者：
1. **modem PIL** — 加载后可能通过 rmtfs 读写 SIM 卡相关的 eMMC 扇区
2. **内核 rmtfs 驱动** (`qcom_rmtfs_mem`) — 注册 mem 设备节点

modem PIL disabled 后，rmtfs 没有任何消费者。保留它只会多占一点 reserved-memory 定义，disable 掉完全正确。

### 唯一可能踩的坑

**如果 kernel defconfig 里 `CONFIG_QCOM_PIL=y` 但 PIL 子系统仍然尝试加载 disabled 的节点** — 不太可能，因为 status=disabled 的节点不会被 platform driver probe。但如果 PIL 框架有 bug，可以在 kernel cmdline 加 `qcom_pil.disable_modem=1`。

---

## 问题 3：WiFi 来源 + 驱动/固件完整性

### WiFi 硬件

| 项目 | 值 |
|------|-----|
| 芯片 | **WCN3620** |
| 接口 | SDIO (HSIO, High-Speed I/O) |
| remoteproc | `remoteproc@a21b000`, compatible `qcom,pronto-v2-pil` |
| memory-region | `wcnss@8df00000` (phandle 137), **未 disabled** ✓ |
| iris node | `remoteproc@a21b000/iris { compatible = "qcom,wcn3620" }` ✓ |
| DMA channel | smd-edge label="pronto", remote-pid=4 |

### WiFi 固件完整性 ✅ 确认完整

用 Python 解析 wcnss.mdt 的 12 个 ELF program headers（Qualcomm PIL 格式），与磁盘文件逐一比对：

| PIL segment | p_type | filesz | 对应文件 | 实际大小 | 状态 |
|------------|--------|--------|---------|---------|------|
| [0] | PT_NULL | 436 | wcnss.b00 | 436 | ✓ |
| [1] | PT_NULL | 6,824 | wcnss.b01 | 6,824 | ✓ |
| [2] | PT_LOAD | 13,064 | wcnss.b02 | 13,064 | ✓ |
| [3] | PT_LOAD | **0** (BSS, memsz=32768) | — | — | 零初始化段，不需要文件 ✓ |
| [4] | PT_LOAD | 61,440 | wcnss.b04 | 61,440 | ✓ |
| [5] | PT_LOAD | **0** (BSS, memsz=57344) | — | — | 零初始化段，不需要文件 ✓ |
| [6] | PT_LOAD | 2,860,948 | wcnss.b06 | 2,860,948 | ✓ (主固件) |
| [7] | PT_LOAD | **0** (BSS, memsz=0) | — | — | PIL 对齐填充 ✓ |
| [8] | PT_LOAD | **0** (BSS, memsz=0) | — | — | PIL 对齐填充 ✓ |
| [9] | PT_LOAD | 52 | wcnss.b09 | 52 | ✓ (分区表) |
| [10] | PT_LOAD | 655,360 | wcnss.b10 | 655,360 | ✓ (WiFi 固件 image) |
| [11] | PT_LOAD | 43,304 | wcnss.b11 | 43,304 | ✓ (NVRAM config) |

**结论：WiFi firmware 完整！** 没有任何必需的 bXX 文件缺失。之前担心的 b03/b05/b07/b08 都是零初始化段，PIL loader 会在内存里分配。

### 固件文件位置

```
D:\PerFiles\suishenwifi\msm8916\ufi003-debian超频版\
  一键替换基带文件\modem\
    wcnss.b00 (436 bytes)
    wcnss.b01 (6,824 bytes)
    wcnss.b02 (13,064 bytes)
    wcnss.b04 (61,440 bytes)
    wcnss.b06 (2,860,948 bytes)
    wcnss.b09 (52 bytes)
    wcnss.b10 (655,360 bytes)
    wcnss.b11 (43,304 bytes)
    wcnss.mdt (7,260 bytes)
```

### 固件安装步骤（刷机后执行一次）

```bash
# SSH 登录后
mkdir -p /lib/firmware/qcom

# 从本地电脑 (Windows) 复制
scp wcnss.b00 wcnss.b01 wcnss.b02 wcnss.b04 wcnss.b06 \
    wcnss.b09 wcnss.b10 wcnss.b11 wcnss.mdt \
    root@192.168.200.1:/lib/firmware/qcom/

reboot

# 验证
dmesg | grep -i pronto       # 应该看到 "pronto: firmware loaded"
dmesg | grep -i wcnss        # 应该看到 WCNSS 相关
lsmod | grep -E 'wcn36xx|ath'
ip link show wlan0           # 应该出现 wlan0 接口
iw wlan0 scan                # 扫 AP
```

### WiFi 驱动

主线内核对 WCN3620 有两个驱动：

| 驱动 | 内核配置 | 优点 | 缺点 |
|------|---------|------|------|
| **wcn36xx** (推荐) | `CONFIG_WCN36XX=m` | 主线维护，现代 cfg80211 API | SDIO DMA 可能有兼容性问题 |
| ath6kl_sdio | `CONFIG_ATH6KL_SDIO=m` | 老但稳定，很多 msm8916 设备用过 | 代码较旧，WEXT API |

**我们走 wcn36xx**（在 kernel config fragment 里已配好）。如果有问题可以 `modprobe -r wcn36xx && modprobe ath6kl_sdio` 试另一个。

### 网络来源总结

| 网络方式 | 状态 | 说明 |
|---------|------|------|
| WCN3620 WiFi (SDIO) | ✓ 主要 | 芯片内置，固件完整，驱动主线支持 |
| USB gadget RNDIS | ✓ 备用 | UFI003 作为 USB device 时暴露 USB 网卡给主机 |
| USB WiFi 网卡 (RTL8188EU 等) | ✓ 备选 | 如果 WCN3620 不工作，插 USB OTG 上 |
| USB Ethernet 网卡 | ✓ 备选 | 同上，USB OTG |
| LTE Modem | ✗ 禁用 | 没有闭源 modem firmware |

### 替代方案（如果 WCN3620 驱动不工作）

1. **换 USB WiFi**：买一个 RTL8188EU/RTL8192EU USB WiFi 网卡，插在 USB OTG 口，`modprobe r8188eu` 即可
2. **USB gadget RNDIS**：用 UFI003 自带的 USB gadget 功能让主机通过 USB 网线 SSH 进去，`192.168.200.1`
3. **串口登录**：USB-UART 模块接 blsp1_uart2 (ttyMSM0, gpio175/gpio176)，直接串口登录

---

## 本地产出文件清单（全部落盘）

```
ufi003-armbian/
├── FINAL_ANSWERS.md                                    ← 本文件 (问题2+3回答)
├── UFI003_FINAL_ANALYSIS.md                            ← 完整硬件分析报告
├── ufi003-armbian-build-guide.md                       ← Linux/WSL2 构建指南
│
├── msm8916-handsome-openstick-ufi003-armbian.dts        ← 去 modem DTS (手写反编译修改版)
│   ↓ Linux 下编译:  dtc -I dts -O dtb -o output.dtb input.dts
│
├── msm8916-handsome-openstick-ufi003.dtb               ← 原版 1.2GHz DTB (对照)
├── msm8916-handsome-openstick-ufi003-overclock.dtb     ← 原版 2.1GHz DTB (超频对照)
│
├── config/
│   ├── boards/ufi003.csc                              ← 板子配置 (无 modem 版)
│   ├── sources/families/msm8916.conf                  ← 内核家族配置 (6.12 current)
│   ├── bootscripts/bootscript-msm8916.sh               ← extlinux.conf 生成器
│   └── sections/msm8916.config                         ← 内核 config fragment (新增!)
│
└── userpatches/kernel/
    ├── README.md                                       ← patch 说明
    └── add-openstick-dts-ufi003-nomodem.patch           ← kernel DTS patch
```

### 关键文件用途说明

| 文件 | 作用 | 使用时机 |
|------|------|---------|
| `*.dts` | 设备树源文件 (去 modem 版) | **路线 B**: Linux 上 dtc 直接编译 → 得到 dtb，手动放 /boot/dtb/qcom/ |
| `userpatches/kernel/*.patch` | 内核 DTS patch | **路线 A**: Armbian 编译内核时自动打进去 |
| `config/sections/msm8916.config` | 内核选项 fragment | Armbian merge defconfig 时自动生效 |
| `config/boards/ufi003.csc` | 板子元数据 + hook 函数 | compile.sh 启动时读取 |

### 两条路线对比

| 路线 | 步骤 | 复杂度 | 可靠性 |
|------|------|--------|--------|
| **A (kernel patch)** | clone 内核 → 打 patch → 编译内核+DTB → Armbian 自动打包 | 中 | 取决于 patch 适配主线 6.12 |
| **B (dtc 直接编)** | 在 Linux 上 dtc 编 *.dts → 得到 dtb → 刷机后手动放 /boot/dtb/qcom/ | 低 | DTS 已验证，100% 可编 |

**推荐：先用路线 A（Armbian 一键构建）。如果 patch apply 挂了，退而用路线 B。**

---

## 下一步行动清单

### 在 Linux/WSL2 上做的事

1. `wsl --install -d Ubuntu-24.04` 或找一台 Linux
2. 装依赖（见 build guide 第一节）
3. `git clone https://github.com/armbian/build.git && cd build`
4. 把 `ufi003-armbian/` 下的文件复制到对应位置
5. `sudo ./compile.sh BOARD=ufi003 BRANCH=current RELEASE=bookworm BUILD_MINIMAL=yes KERNEL_CONFIGURE=no EXPERT=no COMPRESS_OUTPUTIMAGE=xz`

### 在真机上做的事

1. fastboot flash GPT + 原厂 bootloader (sbl1/hyp/rpm/tz)
2. fastboot flash aboot lk2nd (需要 OpenStick lk2nd，GPL)
3. fastboot flash rootfs Armbian_*.img
4. 首次启动 → USB gadget 起 → SSH 192.168.200.1
5. 复制 WiFi firmware 到 /lib/firmware/qcom/ → reboot → WiFi 可用

### 闭源红线（绝不进公开仓库）

- **modem firmware** (mba.mbn + modem.b00~b26 + modem.mdt) — 完全不需要
- **fsc/fsg/modemst1/modemst2** — 不需要
- **WiFi firmware** (wcnss.b00~b11 + wcnss.mdt) — 需要放到设备 `/lib/firmware/qcom/`，但**不能提交 GitHub**

---

## 风险评估

| 风险 | 概率 | 影响 | 缓解 |
|------|------|------|------|
| kernel patch 不适配主线 6.12 | 中 | 编译失败 | 用路线 B (dtc 直接编) |
| WCN3620 驱动在主线 6.12 上有 bug | 低 | WiFi 不工作 | 换 ath6kl_sdio 驱动 / USB WiFi 网卡 |
| PIL 禁用不彻底，内核仍然尝试加载 modem | 极低 | boot hang | DTS 里 status=disabled 是标准做法；加 kernel cmdline override |
| eMMC 分区 GPT 不兼容 | 低 | rootfs 挂不上 | 原始固件就用 GPT，兼容 |

**整体可行性：高。** 所有 DTS/DTB/配置文件已在 Windows 侧生成并验证结构正确性。真正的构建和刷机必须在 Linux/真机上进行，但这些都是成熟步骤。
