#!/usr/bin/env bash
# 阶段 A 构建层可自动化测试：验证产物存在与基本完整性。
# 不能替代 iPad 实机验证（阶段 B–F）。
set -euo pipefail
BUILD="${1:-$PWD/build}"
fail=0

check() {
  if [[ -e "$1" ]]; then
    echo "PASS: $1"
  else
    echo "FAIL: 缺少 $1"
    fail=1
  fi
}

echo "=== 阶段 A：构建测试 ==="
check "$BUILD/qemu-ios"
check "$BUILD/kernel/Image"
# debian12.img 可能离线缺失，仅提示
if [[ -e "$BUILD/debian12.img" ]]; then
  echo "PASS: debian12.img 存在"
else
  echo "WARN: debian12.img 缺失（离线），需在联网环境生成"
fi

# App 产物
APP_GLOB="$BUILD/derived/Build/Products/Release-iphoneos/DebianTerminal.app"
if compgen -G "$APP_GLOB" > /dev/null; then
  echo "PASS: App 编译产物存在"
else
  echo "WARN: App 产物缺失（可能 CI 未跑到此步）"
fi

echo "=== 阶段 B–F（iOS 实机 / Linux 启动 / Debian 功能 / 网络 / 持久化）需目标设备手动执行，见 docs/POC.md ==="
exit $fail
