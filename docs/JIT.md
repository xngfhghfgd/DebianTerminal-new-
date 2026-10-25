# JIT 说明

## 什么是 JIT（对本项目）

QEMU TCG 需要分配可执行内存来放置翻译后的 Guest 指令。iOS 默认不允许普通 App 取得「可写 + 可执行」内存（W^X）。能否运行 QEMU，**决定性条件是能否获得 JIT / 可执行内存**。

## 检测方式（App 内，真实检测）

`VM/JITDetector.swift`：
1. `mmap(PROT_READ|PROT_WRITE, MAP_PRIVATE|MAP_ANONYMOUS)` 一块内存。
2. 写入 ARM64 `nop`（`0x00000000`）。
3. `mprotect(..., PROT_READ|PROT_EXEC)`。
4. 若 `mprotect` 成功且能执行（不崩），JIT **Available**；否则 **Unavailable**。

> 不得伪造检测结果绕过限制；不得把「Developer Mode 已开」当作 JIT 可用。

## 如何获得 JIT

- **付费 Apple Developer 证书**：签名的 App 通常允许 JIT（系统级 entitlement / 运行时授予）。
- **SideStore / AltStore（免费账号）**：JIT 需要安装方式提供「executable code」能力；历史上由 SideStore/AltStore 的 JIT 开关或运行时注入实现。**是否可用必须在目标设备上实测。**
- App 重启后可能需重新获得 JIT；JIT 失效时应重新检测并提示用户。

## App 内状态提示

UI 固定显示：

```
JIT status: Available
```
或
```
JIT status: Unavailable — 无法启动 QEMU（TCG 需要可执行内存）。请确认安装方式支持 JIT，并重启 App 后重试。
```

## 与 iOS 版本相关

iPadOS 26.x 的具体限制需实机确认。本文件记录的是设计预期，**不是已验证结论**；验证结果回填到 [POC.md](POC.md)。
