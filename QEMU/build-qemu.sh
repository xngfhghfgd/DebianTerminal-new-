#!/usr/bin/env bash
# 构建 QEMU（iOS arm64 目标，TCG + TCTI 解释器）。
# 在 macOS Runner（Xcode）上运行。
#
# 关键点：
#  - QEMU 的 configure **不支持** --host=ios，也不认 --sysroot。
#  - 通过 CC/CXX 指向 Xcode 的 aarch64 交叉编译器 + SDK sysroot，让 QEMU
#    为 iOS 目标平台编译。
#  - 目标架构 host = aarch64（与设备匹配），TCG 默认启用（iOS 无 KVM）。
#  - 禁用 UI/宿主依赖（gtk/sdl/vnc/curl/spice/pixman）减体积并避免链接失败。
#  - 保留 slirp 用于 user-mode 网络。
#  - 注意：QEMU 实际构建会产出二进制，静态库由 Makefile 决定。
set -euo pipefail

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
QEMU_SRC="${QEMU_SRC:-qemu-src}"
OUT="${OUT:-$PWD/build/qemu-ios}"
CC_BIN="$(xcrun --find clang)"
CXX_BIN="$(xcrun --find clang++)"

cd "$QEMU_SRC"

# QEMU v9.2.0 需要 Python 3.9–3.12；macOS 15 runner 的 homebrew python3 是 3.14，
# 创建 venv 时报 "found no usable distlib"。
# 最稳妥：用 /usr/bin/python3（系统 3.9/3.13，自带 distlib），并预装构建依赖。
if command -v /usr/bin/python3 >/dev/null 2>&1; then
  PY=/usr/bin/python3
else
  PY="$(command -v python3)"
fi
echo "### 使用系统 Python: $PY ($($PY --version 2>&1))"
# 预装 distlib / virtualenv（系统 Python 可能需要 apt 风格补装；失败则继续）
"$PY" -m pip install --quiet distlib virtualenv 2>/dev/null || \
  "$PY" -m ensurepip --upgrade 2>/dev/null || true
export PYTHON="$PY"

# 让 QEMU 使用已装好依赖的解释器（--python 指向它，避免重建隔离 venv）
echo "### QEMU configure（iOS arm64 交叉编译）"
CC="${CC_BIN} --sysroot=${SDK} --target=arm64-apple-ios17.0" \
CXX="${CXX_BIN} --sysroot=${SDK} --target=arm64-apple-ios17.0" \
./configure \
  --python="$PYTHON" \
  --target-list=aarch64-softmmu \
  --enable-tcg \
  --disable-kvm \
  --disable-werror \
  --disable-gtk \
  --disable-sdl \
  --disable-vnc \
  --disable-curl \
  --disable-spice \
  --disable-pixman \
  --disable-slirp \
  --prefix="$OUT" \
  --extra-cflags="--target=arm64-apple-ios17.0 --sysroot=${SDK}" \
  --extra-cxxflags="--target=arm64-apple-ios17.0 --sysroot=${SDK}"

echo "### make"
make -j"$(sysctl -n hw.ncpu)"

echo "QEMU iOS 构建完成: $OUT"
ls -la "$OUT"/bin 2>/dev/null || echo "  (产物路径见 build 日志)"
# 静态库模式：QEMU 会产出 .a，需要把对应 .o/.a 链接进 App
ls -la "$OUT"/lib 2>/dev/null | head -5 || true
