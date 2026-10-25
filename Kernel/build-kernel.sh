#!/usr/bin/env bash
# 构建 ARM64 内核（供 QEMU virt 机器启动 Debian 12）。
# 需要 aarch64-linux-gnu 交叉编译工具链。
#
# 环境变量：
#   KERNEL_SRC   内核源码目录（默认 linux）
#   OUT          产物目录（默认 $PWD/build/kernel）
#   JOBS         并行度（默认 8）
#   DEFCONFIG    基础 defconfig（默认 virt_defconfig，arm64 stable tarball 可能无 virt_defconfig，
#                则用 defconfig 生成 CONFIG 后叠加 EXTRA_KCONFIGS）
#   EXTRA_KCONFIGS  额外写入 .config 的 CONFIG 项（空格分隔）
set -euo pipefail

KERNEL_SRC="${KERNEL_SRC:-linux}"
OUT="${OUT:-$PWD/build/kernel}"
JOBS="${JOBS:-8}"
DEFCONFIG="${DEFCONFIG:-virt_defconfig}"
EXTRA_KCONFIGS="${EXTRA_KCONFIGS:-}"

mkdir -p "$OUT"
cd "$KERNEL_SRC"

# 1) 生成基础 defconfig（virt_defconfig 缺失则回退 defconfig）
if [[ -f "arch/arm64/configs/${DEFCONFIG}" ]]; then
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- "${DEFCONFIG}_defconfig"
else
  echo "  [warn] ${DEFCONFIG}_defconfig 不存在，回退 defconfig"
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig
fi

# 2) 叠加 EXTRA_KCONFIGS（virt 关键项：pl011/virtio/ext4/dm-verity 等）
if [[ -n "$EXTRA_KCONFIGS" ]]; then
  for kv in $EXTRA_KCONFIGS; do
    key="${kv%%=*}"
    # 先删旧行再追加，避免重复；末尾保留新值
    sed -i "/^# *${key} is not set$/d; /^${key}=/d" .config
    echo "$kv" >> .config
  done
  make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- olddefconfig </dev/null
fi

# 3) 编译 Image
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j"$JOBS" Image

cp -f arch/arm64/boot/Image "$OUT/Image"
echo "内核构建完成: $OUT/Image"
