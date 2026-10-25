# 签名与安装说明

> 本文件说明**未签名产物**与**可安装产物**的区别，以及 SideStore / AltStore 的实际要求。

## 产物状态分层

| 层级 | 含义 | 能否直接安装 |
|---|---|---|
| 1 | 编译产物（`.o` / 二进制） | 否 |
| 2 | 未签名 `.app` | 否 |
| 3 | 未签名 `.ipa` | 否 |
| 4 | 已签名 `.ipa` | 取决于签名方式 |
| 5 | 能在目标 iPad 上启动的 `.ipa` | 需实机验证 |
| 6 | 能获得 JIT 并启动 Debian 的 `.ipa` | 需实机验证 |

**不得把未签名 IPA 描述为可直接安装的 IPA。**

## 签名方式

### 免费 Apple ID（SideStore / AltStore 7 天证书）
- GitHub Actions **不能**自动完成个人签名（没有你的 Apple 账号）。
- 云端只产出**未签名 App / IPA**。
- 你在本地用 SideStore（或 AltStore + 付费证书）完成签名与安装。
- 限制：免费签名 7 天过期，需定期刷新；JIT 支持需额外启用。

### 付费 Apple Developer
- 可上传证书/Provisioning Profile 到 GitHub Secrets 做自动签名（**不要把私钥提交到公开仓库**）。
- JIT 支持相对稳定。

## JIT 启用

见 [JIT.md](JIT.md)。安装成功 ≠ JIT 可用，必须在 App 内检测并在文档中明确。

## 安全

- 不得将 Apple 账号密码、证书私钥、Provisioning Profile 提交到公开仓库或写入脚本明文。
- 如需用户提供签名材料，必须先完成代码编译与 POC。
