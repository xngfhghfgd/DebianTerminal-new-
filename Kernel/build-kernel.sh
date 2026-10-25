#!/usr/bin/env bash
# 构建 ARM64 virt 内核（供 QEMU virt 机器启动 Debian 12）。
# 需要 aarch64-linux-gnu 交叉编译工具链。
set -euo pipefail

KERNEL_SRC="${KERNEL_SRC:-linux}"
OUT="${OUT:-$PWD/build/kernel}"
JOBS="${JOBS:-8}"

mkdir -p "$OUT"
cd "$KERNEL_SRC"

# virt_defconfig 含 PL011 / virtio / ext4 等根启动所需驱动
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- virt_defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS" Image

cp -f arch/arm64/boot/Image "$OUT/Image"
echo "内核构建完成: $OUT/Image"
