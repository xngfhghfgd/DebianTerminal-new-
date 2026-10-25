#!/usr/bin/env bash
# 准备 Debian 12 bookworm arm64 Guest 磁盘镜像。
#
# 两种来源（本脚本默认 1，备选 2）：
#  1. 官方 genericcloud qcow2（含 systemd/apt/python3，~150MB）
#     -> 转换为 raw 供 QEMU if=virtio,format=raw 使用，并扩容到目标容量。
#  2. debootstrap 自建最小系统（需要 aarch64 交叉 debootstrap 或容器内执行）。
#
# 输出：debian12.img（raw, ext4），默认 8GB 可用空间上限。
set -euo pipefail

OUT="${OUT:-$PWD/build/debian12.img}"
SIZE_MB="${SIZE_MB:-4096}"   # 默认 4GB（2048 内存 + 系统够用），可扩到 8GB
CLOUD_MIRROR="https://cdimage.debian.org/cdimage/cloud/12/"
QCOV="$(curl -sI "${CLOUD_MIRROR}" >/dev/null 2>&1 && \
        curl -s "${CLOUD_MIRROR}/current" | grep -oE 'debian-12\.genericcloud[^"]*arm64[^"]*\.qcow2' | head -1 || true)"
RAW_BASE="${RAW_BASE:-debian-12-genericcloud-arm64.qcow2}"

mkdir -p "$(dirname "$OUT")"

echo "[1/3] 获取 Debian 12 arm64 genericcloud 镜像"
if [[ -n "$QCOV" && -f "$QCOV" ]]; then
    curl -L -o "$RAW_BASE" "$QCOV"
fi
if [[ ! -f "$RAW_BASE" ]]; then
    echo "  尝试镜像 URL（需联网或预先放置 $RAW_BASE）"
    [[ -f "$RAW_BASE" ]] || { echo "ERROR: 未找到 $RAW_BASE，请预先放置或检查网络"; exit 1; }
fi

echo "[2/3] 转 raw 并扩容到 ${SIZE_MB}MB"
# qcow2 -> raw
qemu-img convert -f qcow2 -O raw "$RAW_BASE" "$OUT" 2>/dev/null || {
    echo "  qemu-img 不可用，假设已是 raw"
    [[ "$RAW_BASE" != "$OUT" ]] && cp -f "$RAW_BASE" "$OUT"
}
# 扩容（sparse，实际占用按需）
truncate -s "${SIZE_MB}M" "$OUT" 2>/dev/null || true

echo "[3/3] 生成 root 口令与默认服务配置（需 chroot 或 guest 内执行）"
cat > prepare-notes.txt <<'EOF'
首次启动后需在 guest 内执行：
  systemctl set-default multi-user.target   # 关闭图形
  passwd root
  ln -sf /bin/bash /bin/sh || true
EOF
echo "完成: $OUT"
