# POC 验证路线（A–F 状态标记）

任务书要求：在 POC 成功前不投入终端美化/文件管理器/复杂设置页；并明确区分 A–F 状态，只有实际测试通过才能标记成功。

## 当前状态

| 状态 | 描述 | 标记 | 证据 |
|---|---|---|---|
| A | QEMU 已编译（iOS arm64） | ⏳ 待 CI | 见 Actions build 日志 |
| B | QEMU 已打包进 App | ⏳ 待 CI | 产物清单 |
| C | QEMU 已在 iPad 上运行 | ❌ 未开始 | 需实机 |
| D | Linux Kernel 已启动 | ❌ 未开始 | 需实机 |
| E | Debian 12 已启动 | ❌ 未开始 | 需实机 |
| F | Debian 命令行可交互 | ❌ 未开始 | 需实机 |

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
