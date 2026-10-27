# POC 验证路线（A–F 状态标记）

任务书要求：在 POC 成功前不投入终端美化/文件管理器/复杂设置页；并明确区分 A–F 状态，只有实际测试通过才能标记成功。

## 当前状态

> 构建层（A/B + 内核/磁盘镜像随附）已由 GitHub Actions 全绿验证；C–F 需真机 iPad 实测。

| 状态 | 描述 | 标记 | 证据 |
|---|---|---|---|
| A | QEMU 已编译（iOS arm64, TCG+TCTI） | ✅ CI 通过 | build job「build QEMU」success（Actions 日志） |
| B | QEMU 已打包进 App bundle | ✅ CI 通过 | `.app/Resources/qemu-system-aarch64`（Mach-O arm64，~37 MB） |
| B' | aarch64 内核 `Image` 已装入 bundle | ✅ CI 通过 | `.app/Resources/Image`（ubuntu-latest job 编译） |
| B'' | Debian 12 `debian12.img` 已装入 bundle | ✅ CI 通过 | genericcloud qcow2→raw（4 GB，`prepare-debian.sh` 自动下载） |
| C | QEMU 已在 iPad 上运行 | ❌ 未开始 | 需真机 + 签名 |
| D | Linux Kernel 已启动 | ❌ 未开始 | 需实机 |
| E | Debian 12 已启动 | ❌ 未开始 | 需实机 |
| F | Debian 命令行可交互 | ❌ 未开始 | 需实机 |

**未签名 IPA 已生成**（未做签名，需 SideStore/AltStore 本地签后装 iPad，见 SIGNING.md）。
**JIT 未启用**：TCG 模式跑 Linux 内核可能极慢或不稳定，需实机确认（见 JIT.md）。
**Debian genericcloud 首启**：默认 `cloud-user`/`Debian12`，建议首启改强口令并 `systemctl set-default multi-user.target`（见 bundle 内 `prepare-notes.txt`）。

## 验证命令（实机阶段，逐级执行）

```
cat /etc/os-release        # 期望: PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"
cat /etc/debian_version    # 期望: 12.x
uname -m                   # 期望: aarch64
uname -a                   # 期望: 显示 Guest 内核真实信息
ls / ; mount ; ip addr ; ip route ; ps ; systemctl
apt update ; python3 --version ; curl https://deb.debian.org
```

**预期与真实输出不一致时必须记录失败原因与日志，不得伪造。**

## 失败报告模板（某级不通过时）

1. 失败阶段：A/B/C/D/E/F
2. 实际错误：
3. 已尝试方法：
4. 平台限制：
5. 可行替代方案：
6. 对最终目标的影响：
