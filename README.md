# DebianTerminal

在 **无越狱 iPad mini 7（iPadOS 26.1, ARM64）** 上运行真实的 **Debian GNU/Linux 12 (bookworm) ARM64** 系统。

目标架构：

```
iPadOS → DebianTerminal.app → QEMU AArch64 (TCG/JIT) → ARM64 Linux Kernel → Debian 12 → systemd → bash
```

> 这不是用 proot / Termux / BusyBox 伪造的 Linux，而是真正由 QEMU 启动的 ARM64 Linux 内核 + 官方 Debian 用户空间。

---

## 当前状态（POC 阶段，A–F 状态标记）

| 状态 | 含义 | 进度 |
|---|---|---|
| A | QEMU 已编译（iOS arm64 目标） | ⏳ CI 验证中 |
| B | QEMU 已打包进 App | ⏳ CI 验证中 |
| C | QEMU 已在 iPad 上运行 | ❌ 待实机 |
| D | Linux Kernel 已启动 | ❌ 待实机 |
| E | Debian 12 已启动 | ❌ 待实机 |
| F | 可交互 bash | ❌ 待实机 |

**云端构建成功 ≠ iPad 实机验证成功。** 见 [docs/POC.md](docs/POC.md) 了解验证路线。

---

## 项目布局

```
DebianTerminal/
├── DebianTerminal.xcodeproj/     # Xcode 工程（手写 pbxproj）
├── DebianTerminal/               # Swift 源码
│   ├── App/                      # 入口、状态机
│   ├── UI/                       # SwiftUI 主页 / 设置 / 终端
│   ├── VM/                       # VMManager、VMConfig、JIT 检测
│   └── QEMUBridge/               # QEMU C 桥接
├── QEMU/                         # QEMU iOS 构建脚本与补丁说明
├── Kernel/                       # 内核获取与最小配置
├── Scripts/                      # 构建辅助脚本
├── .github/workflows/            # build-ios.yml / test.yml
├── Tests/                        # 可自动化测试
└── docs/                         # 可行性研究、POC、签名说明
```

---

## 快速开始（无 Mac）

1. 在 GitHub 网页端打开 `.github/workflows/build-ios.yml`，点击 **Run workflow**（或 push 触发）。
2. 工作流会在 **macOS Runner + Xcode** 上完成：
   - 编译 QEMU（iOS arm64, TCG, 无 KVM）
   - 准备 Linux Kernel（`Image` + 设备树）
   - 准备 Debian 12 ARM64 镜像
   - 编译 iOS App
   - 产出未签名 `.app` / `.ipa`（条件允许时）
3. 在 Actions → Artifacts 下载产物。
4. 按 [docs/SIGNING.md](docs/SIGNING.md) 用 SideStore/AltStore 安装。
5. 按 [docs/JIT.md](docs/JIT.md) 启用 JIT。
6. 打开 App → **Start** → 进入 `root@debian:~#`。

---

## 技术要点

- **QEMU**：`qemu-system-aarch64`，`-machine virt`，TCG（无 KVM），动态翻译需要 JIT 内存。
- **内核**：ARM64 `virt` 机器最小配置，`PL011 UART` + `VirtIO Block` + `ext4`，根驱动编译进内核。
- **Guest**：Debian 12 Bookworm ARM64（systemd / bash / apt / python3 / curl / git）。
- **终端**：QEMU 串口（`-serial stdio`/`chardev`）直接对接 App 终端，`console=ttyAMA0`。
- **持久化**：磁盘存 `Documents/Debian/debian12.img`，支持导入/导出/备份。

---

## 许可与第三方组件

本项目包含 QEMU（GPLv2）、Linux Kernel（GPLv2）、Debian 用户空间（各自上游许可）。详见 [docs/LICENSING.md](docs/LICENSING.md)。
