# 可行性研究：在 iPadOS 上运行真正的 ARM64 Linux VM

> 结论先行：**技术上可行**。iOS 上已有可运行的先例（UTM / UTM SE），但其 JIT 路径在 iPadOS 26.6+ 上脆弱，默认应采用**线程解释器（TCI/TCTI）模式**保证可运行，JIT 作为可选加速。本文件区分「已证实」与「推断」，并给出 POC 验证路线。

---

## 1. 关键约束

### 1.1 JIT（可执行内存）与解释器

QEMU 的 TCG 有两种代码生成路径：
- **JIT（动态翻译）**：`mmap + mprotect(PROT_EXEC)`，需要 iOS 允许可写可执行内存。
- **线程解释器（TCTI）**：不生成机器码，纯解释执行。**无需 JIT，可直接运行**，但慢（~8–12× 原生）。

**iOS 上的 JIT 现实（已核实）**：
- 默认不授予普通 App RWX。
- 付费 Developer 签名 + `get-task-allow` 可让调试器 attach，进而解锁可执行内存（SideStore/AltStore + StikDebug 流程）。
- **iOS 26.6 / 27 上 JIT 已再次受限，只对白名单 App 有效（UTM 在列）**。自定义 App **不保证**进入白名单。
- **不能把「App 安装成功」或「开了 Developer Mode」等同于「JIT 可用」。**

**设计结论**：
- POC 默认走 **TCTI 解释器模式**，保证在任意签名方式下都能启动 Debian。
- 提供 JIT 检测与可选启用（`VM/JITDetector.swift`），成功则切到 TCG 加速，失败则回退解释器并明确提示。
- 不得伪造检测。

### 1.2 先例（已核实）

- **UTM**（[utmapp/UTM](https://github.com/utmapp/UTM)）：QEMU 移植到 iOS，`Platform/QEMU` 维护 QEMU fork + `patches/` 补丁；App Store 版 **UTM SE** 用 TCTI 解释器，无需 JIT，已在 iPad 上跑起 Debian/Alpine arm64。
- **iSH**：用户态 x86_64（非全系统，不是本方案）。
- **MeloNX / maciOS / DolphiniOS / Manic EMU / ARMSX2 / DukeX**：JIT 全系统模拟器，仅 side-load + StikDebug，**不在 App Store**。
- Hypervisor.framework 在 iOS 上不可用（仅 macOS M1+）。

### 1.3 进程与线程

- QEMU 全系统模拟是**单进程内多线程**（pthread），不 fork 子进程，**符合 iOS 沙盒**。
- `systemd` 在 **Guest 内**运行，与 iOS 沙盒无关。
- `-smp` 多核用 pthread，可行。

### 1.4 文件与沙盒

- 磁盘镜像存 `Documents/Debian/debian12.img`，内核 `Image` + 设备树放 Bundle `Resources/`。
- App 被系统终止后 QEMU 随之结束，**Guest 需优雅关机**（`poweroff`）保护 ext4。

### 1.5 后台与内存

- 已核实：iOS 会快速终止后台资源型 App（UTM SE 后台 ~15–20s 被杀）。
- 设计为**前台使用**；后台被杀属于平台限制，需在文档中如实说明。
- Guest 默认 2048MB，**不保证 4096MB 稳定**；2048MB 为默认值。
- 性能推断：A15 级 CPU 上 TCG/解释器运行 Debian 5–15 分钟启动、可交互但慢，**适合 shell 用途**。

---

## 2. QEMU iOS 移植

### 2.1 构建目标（iOS 交叉编译）

- Xcode iOS SDK 交叉编译：
  ```
  CC=clang CXX=clang++ --host=aarch64-apple-ios12.0 \
    --sysroot=$SDK/iPhoneOS.sdk \
    --target-list=aarch64-softmmu --enable-tcg --disable-kvm
  ```
- iOS 无 KVM，必须 TCG/解释器。
- 参考 UTM 的 `Platform/QEMU` 构建脚本与 `patches/` 目录（`qemu-10.0.12-utm.patch`）。
- 解释器模式依赖 `ktemkin/qemu` 的 `tcg/aarch64-tcti` 分支（TCTI 实现）。
- 可选依赖：`libslirp`（用户态网络）、`glib`（可 `--disable-glib` 减体积）。

### 2.2 打包

- QEMU 编译为**静态库**链接进 App 二进制（UTM 方案），或打包为独立 `qemu-system-aarch64` 由 App 通过 `posix_spawn` 启动。
- POC 先采用「静态链接 + 进程内调用」或「独立二进制 + spawn」，**由实机测试确定**哪种在签名环境下可行。

> **macOS 上编译成功 ≠ iOS 上可运行。** 必须 iOS SDK 交叉编译并真机验证。

---

## 3. Linux 内核

- 使用 ARM64 `virt` 机器最小配置，`virt_defconfig` 为基线：
  - `CONFIG_ARM64=y`、`CONFIG_SERIAL_AMBA_PL011=y`、`CONFIG_VIRTIO_BLK=y`、`CONFIG_VIRTIO_NET=y`、`CONFIG_EXT4_FS=y`、`CONFIG_DEVTMPFS`、`CONFIG_PROC_FS`、`CONFIG_SYSFS`、`CONFIG_TMPFS`
  - 根文件系统所需驱动**编译进内核**（非模块），避免启动期无模块。
- 参考 [kernel.org qemu-arm64 howto](https://cdn.kernel.org/pub/linux/kernel/people/will/docs/qemu/qemu-arm64-howto.html)。

### 启动参数模板（**候选**，由 `VMConfig` 管理，非最终验证配置）

```
qemu-system-aarch64 -M virt -cpu max -smp 2 -m 2048 \
  -bios QEMU_EFI.fd \
  -drive if=none,file=debian12.qcow2,id=hd0,format=qcow2 \
  -device virtio-blk-device,drive=hd0 \
  -netdev user,id=n0 -device virtio-net-device,netdev=n0 \
  -append "root=/dev/vda rw console=ttyAMA0" \
  -nographic
```

需实机验证：`-M virt` 支持、`-cpu` 型号、BIOS/UEFI（`QEMU_EFI.fd`）需求、是否需要 `initramfs` / `rootwait`、console 参数。

> 任务书原模板用 `-kernel Image` 直接启动；Debian 官方 genericcloud 镜像通常走 UEFI。两条路径都保留，由 `VMConfig` 切换，实机验证后定稿。

---

## 4. Debian 12 Guest

- 首选：**官方 Debian 12 genericcloud arm64 镜像**（`debian-12-genericcloud-arm64.qcow2`，~150MB，含 systemd、apt、glibc、bash）。
  - 来源：https://image-finder.debian.net/ 或 cdimage.debian.org/cloud
- 必须组件（genericcloud 已含）：`systemd glibc bash coreutils apt dpkg procps util-linux mount iproute2 ca-certificates locales tzdata curl wget git python3 openssh-client`
- 可选（不预装，用 apt 装）：`gcc make nodejs tmux`
- 启动后 `systemctl set-default multi-user.target` 关闭图形。

---

## 5. POC 验证路线（A–F）

按任务书逐级验证，**不跳级**，只有实机通过才能标记：

1. **A**：CI 成功交叉编译 QEMU（iOS arm64，TCTI + TCG）。
2. **B**：QEMU + 内核/BIOS + Debian 镜像打包进 App，资源路径正确。
3. **C**：App 在 iPad 启动，解释器模式 QEMU 跑起来（JIT 可选）。
4. **D**：内核启动到 `console=ttyAMA0`。
5. **E**：挂载 Debian 12 镜像，systemd 起来。
6. **F**：`root@debian:~#` 可交互，`apt update` / `python3 --version` / `uname -m` 输出正确。

**失败报告**按 [POC.md](POC.md) 模板记录。

---

## 6. 证据来源（已抓取核实）

- UTM 仓库与文档：https://github.com/utmapp/UTM 、https://docs.getutm.app/installation/ios/
- TCTI 解释器：https://github.com/ktemkin/qemu/tree/with_tcti/tcg/aarch64-tcti
- SideStore JIT 文档（iOS 26/27 白名单）：https://docs.sidestore.io/docs/advanced/jit/
- UTM SE 后台被杀：https://github.com/utmapp/UTM/issues/7059
- 性能分析（TCG ~8–12× 原生）：https://www.linaro.org/blog/qemu-a-tale-of-performance-analysis/
- 内核 arm64 QEMU howto：https://cdn.kernel.org/pub/linux/kernel/people/will/docs/qemu/qemu-arm64-howto.html
- Debian cloud 镜像 + 示例启动命令：https://wiki.debian.org/Arm64Qemu 、https://image-finder.debian.net/
