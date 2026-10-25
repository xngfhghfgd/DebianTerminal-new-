#!/usr/bin/env bash
# 构建 QEMU（iOS arm64 目标，TCG + TCTI 解释器）。
# 在 macOS Runner（Xcode）上运行。
set -euo pipefail

SDK=$(xcrun --sdk iphoneos --show-sdk-path)
QEMU_SRC="${QEMU_SRC:-qemu}"
OUT="${OUT:-$PWD/build/qemu-ios}"

cd "$QEMU_SRC"
CC=clang CXX=clang++ ./configure \
  --host=aarch64-apple-ios12.0 \
  --sysroot="$SDK" \
  --target-list=aarch64-softmmu \
  --enable-tcg \
  --disable-kvm \
  --disable-werror \
  --disable-glib \
  --enable-static --disable-system \
  --prefix="$OUT"

make -j"$(sysctl -n hw.ncpu)"
echo "QEMU iOS 构建完成: $OUT"
ls -la "$OUT"/bin 2>/dev/null || true
