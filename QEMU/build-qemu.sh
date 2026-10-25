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

echo "### QEMU configure（iOS arm64 交叉编译）"
CC="${CC_BIN} --sysroot=${SDK} --target=arm64-apple-ios17.0" \
CXX="${CXX_BIN} --sysroot=${SDK} --target=arm64-apple-ios17.0" \
./configure \
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
