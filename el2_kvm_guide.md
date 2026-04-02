# Huawei MateBook E Go 2023 EL2 + KVM 指南

## 1. 目标概述

- 使 MateBook E Go 2023 通过 Secure Launch 进入 EL2。
- 在 EL2 模式下补全 DSP 启动链，尽可能恢复音频等依赖 remoteproc 的功能。
- 在 Linux 中启用可用的 KVM。

## 2. 结论

仅凭 `slbounce` 即可进入 EL2，但其不负责 Linux 侧的 DSP 启动。若未通过 `qebspil` 预先启动 DSP，Linux 中将完全没有声音。`qebspil` 的作用是：在 `ExitBootServices()` 执行之前，依据设备树中已启用的 remoteproc 节点，将对应固件加载并启动。对于 EL2 Linux 而言，这一步通常是音频功能能否正常工作的关键分界点。

1. `slbounce` 负责在 `ExitBootServices()` 时完成向 EL2 的切换。
2. 音频所依赖的 ADSP/CDSP/SLPI 等 remoteproc，在 EL2 下通常无法再依赖 Qualcomm 原有 hypervisor 自动拉起。
3. 因此需要额外引入 `qebspil`，在退出 UEFI 前预先启动 DSP 固件。
4. Linux 内核侧还需合入 `qebspil` 对应的 remoteproc/PAS handover 补丁；否则即使 DSP 已被提前启动，内核也可能无法正确接管。

## 3. 所需组件

EFI 侧至少需要以下文件：

- `BOOTAA64.EFI`
- `slbounceaa64.efi`
- `tcblaunch.exe`
- `qebspilaa64.efi`
- `/firmware/...` 下的 DSP 固件文件

其中：

- `BOOTAA64.EFI` 现在是 `systemd-boot`
- `slbounceaa64.efi` 和 `qebspilaa64.efi` 需要放到 `\EFI\systemd\drivers\`

内核侧至少需要：

- EL2 DTB：`sc8280xp-huawei-gaokun3-el2.dtb`
- EL2 内核：`CONFIG_LOCALVERSION="-gaokun3-el2"`
- `CONFIG_VIRTUALIZATION=y`
- `CONFIG_KVM=y`
- `CONFIG_REMOTEPROC=y`
- Qualcomm remoteproc/PAS 相关驱动
- qebspil 对应的 handover / late-attach / EL2-PAS 补丁

## 4. 推荐启动链

建议将启动链调整为如下顺序：

1. `\EFI\BOOT\BOOTAA64.EFI`
2. `\EFI\systemd\drivers\slbounceaa64.efi`
3. `\EFI\systemd\drivers\qebspilaa64.efi`
4. `systemd-boot` -> EL2 菜单项

说明：

- `slbounce` 仍负责 Secure Launch 及 EL2 切换。
- `qebspil` 负责在退出 UEFI 前预启动 DSP。
- `systemd-boot` 的 EL2 菜单项须显式指定 `-gaokun3-el2` 内核和 `-el2.dtb`。

## 5. 编译说明

当前可直接使用仓库内 `tools/el2` 中的必要引导组件，主要文件如下：

- `slbounceaa64.efi`：slbounce 驱动文件。
- `tcblaunch.exe`：已验证版本的 TCB 文件。
- `qebspilaa64.efi`：qebspil 编译产物。

### 5.1 编译 slbounce

```bash
git clone --recursive https://github.com/TravMurav/slbounce.git
cd slbounce
make CROSS_COMPILE=aarch64-linux-gnu-
```

产物：

- `out/slbounce.efi`

重命名为 `slbounceaa64.efi` 后部署至 `\EFI\systemd\drivers\`。

### 5.2 编译 qebspil

```bash
git clone --recursive https://github.com/stephan-gh/qebspil.git
cd qebspil
make CROSS_COMPILE=aarch64-linux-gnu-
```

产物：

- `out/qebspilaa64.efi`

部署至 `\EFI\systemd\drivers\`。

如需强制启动所有 remoteproc（而非仅限带有 `qcom,broken-reset` 标记的节点）：

```bash
make CROSS_COMPILE=aarch64-linux-gnu- QEBSPIL_ALWAYS_START=1
```

若对平台 DTS 的完整性尚无把握，建议暂不启用此选项。

## 6. 内核补全说明

### 6.1 必选配置项

重新编译内核前，至少确认以下配置项已启用：

```text
CONFIG_VIRTUALIZATION=y
CONFIG_KVM=y
CONFIG_REMOTEPROC=y
CONFIG_QCOM_SYSMON=y
CONFIG_QCOM_Q6V5_COMMON=y
CONFIG_QCOM_Q6V5_ADSP=y
CONFIG_QCOM_Q6V5_MSS=y
CONFIG_QCOM_PIL_INFO=y
```

不同内核版本的符号名称可能略有差异，请以实际版本为准，但核心原则不变：**KVM、remoteproc 及 qcom PAS/Q6V5 必须齐备**。

### 6.2 必要补丁方向

当前可直接使用仓库内 `patches/el2` 中的补丁集。按语义分类，重点涉及以下三个方向：

1. **remoteproc handover / late attach**
   使 Linux 能够接管由 qebspil 预先启动的 remoteproc，而非将其识别为异常状态。

2. **qcom PAS 在 EL2 下的支持**
   当 Linux 自行管理 IOMMU / stream ID / resource table 时，允许 PAS 正确完成固件认证与接管。

3. **ADSP lite firmware / DTB 清理与接管修正**
   若不处理，旧的 lite ADSP 可能占用内存或保留异常状态，导致完整音频固件无法正常加载，仍可能出现无声问题。

## 7. 固件准备

`qebspil` 通过读取设备树中的 `firmware-name` 属性来定位固件，因此需将对应固件文件放置于 ESP 顶层的 `/firmware` 目录下。

建议先在可正常工作的系统中确认所需文件：

```bash
find /sys/firmware/devicetree -name firmware-name -exec cat {} + | xargs -0n1
```

然后将对应文件从 `/lib/firmware/` 或 Windows 分区复制至 EFI 分区。SC8280XP 平台通常至少需要以下文件：

- `qcadsp*.mbn`
- `qccdsp*.mbn`
- `qcslpi*.mbn`

若音频功能仍不正常，应首先排查此处是否存在问题。

## 8. EFI 部署

建议备份原有文件后再行替换：

1. 备份 `\EFI\BOOT\BOOTAA64.EFI`
2. 在 `\EFI\systemd\drivers\` 放置：
   - `slbounceaa64.efi`
   - `qebspilaa64.efi`
3. 在 EFI 分区根目录放置：
   - `\tcblaunch.exe`
4. 在 EFI 分区顶层放置：
   - `\firmware\...`
5. 通过 `systemd-boot` 选择 EL2 菜单项

建议的目录结构如下：

```text
/boot/efi
├── EFI
│   ├── BOOT
│   │   └── BOOTAA64.EFI
│   └── systemd
│       ├── systemd-bootaa64.efi
│       └── drivers
│           ├── qebspilaa64.efi
│           └── slbounceaa64.efi
├── firmware
│   └── qcom
│       └── sc8280xp
│           └── HUAWEI
│               └── gaokun3
│                   ├── qcadsp8280.mbn
│                   ├── qccdsp8280.mbn
│                   └── qcslpi8280.mbn
├── tcblaunch.exe
├── loader
│   ├── entries
│   │   └── *.conf
│   └── loader.conf
└── gaokun3
    └── ...
```

## 9. 启动后验证

进入系统后，执行以下命令进行验证：

```bash
uname -a
dmesg | grep -Ei 'kvm|hypervisor|el2|q6v5|adsp|cdsp|slpi|remoteproc'
ls -l /dev/kvm
ls /sys/class/remoteproc/
```

重点关注以下几点：

- `/dev/kvm` 是否存在
- 系统是否已运行于 EL2
- remoteproc 节点是否存在且未全部处于离线状态
- 是否存在 ADSP/CDSP/SLPI 相关错误信息

## 10. "EL2 正常但音频无效"排查顺序

1. 确认是否已部署 `qebspilaa64.efi`
2. 确认 ESP 顶层 `/firmware/...` 目录是否存在，且文件名与设备树中的 `firmware-name` 属性一致
3. 确认 EL2 菜单项是否已加载 `-el2.dtb`
4. 确认 EL2 菜单项是否使用了 `-gaokun3-el2` 内核
5. 确认内核是否包含 qebspil 对应的 remoteproc/PAS 补丁
6. 检查 `dmesg` 中是否出现 ADSP/CDSP handover、PAS、IOMMU 或 resource table 相关错误
7. 若 remoteproc 节点未带有 `qcom,broken-reset` 属性，可考虑重新编译并启用 `QEBSPIL_ALWAYS_START=1`

## 11. 最小操作建议

若当前目标仅为恢复音频功能，最小操作步骤如下：

1. 新增 `qebspilaa64.efi`
2. 补全 ESP 上的 `/firmware/...` 目录
3. 合入 qebspil README 所指向的 handover/PAS 补丁后重新编译 EL2 内核
4. 确认 EL2 菜单项使用 `-gaokun3-el2` 内核和 `-el2.dtb`
5. 验证 ADSP/CDSP/SLPI 的启动情况

在完成上述步骤之前，不建议将精力继续集中于 ALSA 或声卡驱动层面的排查。
