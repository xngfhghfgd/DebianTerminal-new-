#!/usr/bin/env bash
# 准备 Debian 12 bookworm arm64 Guest 磁盘镜像（genericcloud → raw，供 QEMU if=virtio,format=raw）。
#
# 来源：Debian 官方 cloud 镜像。正确路径结构（注意不是 /cloud/12/，而是 /cloud/bookworm/<date>/）：
#   https://cdimage.debian.org/cdimage/cloud/bookworm/<build-date>/
# 脚本自动探测最新 build 目录并取其中的 arm64 genericcloud qcow2。
#
# 用法：
#   RAW_BASE=<已下载的 qcow2> bash Scripts/prepare-debian.sh   # 离线复用
#   bash Scripts/prepare-debian.sh                             # 联网自动下载
set -euo pipefail

OUT="${OUT:-$PWD/build/debian12.img}"
SIZE_MB="${SIZE_MB:-4096}"
CLOUD_BASE="https://cdimage.debian.org/cdimage/cloud/bookworm"
RAW_BASE="${RAW_BASE:-debian-12-genericcloud-arm64.qcow2}"

mkdir -p "$(dirname "$OUT")"

# 下载函数（curl 带重试，失败可回退 wget）
dl() {
  local url="$1" out="$2"
  curl -L --fail --retry 3 --retry-delay 2 --max-time 600 -o "$out" "$url" 2>/dev/null && return 0
  wget -q -O "$out" "$url" && return 0
  return 1
}

echo "[1/3] 获取 Debian 12 arm64 genericcloud 镜像"
if [[ -n "${RAW_BASE_SET:-}" && -f "$RAW_BASE" ]]; then
  echo "  复用已存在的 $RAW_BASE（RAW_BASE 预置）"
else
  if [[ -f "$RAW_BASE" ]]; then
    echo "  发现本地 $RAW_BASE，直接复用"
  else
    # 自动探测最新 build 目录
    latest="$(curl -s --max-time 30 -L "$CLOUD_BASE/" | grep -oE '[0-9]{8}-[0-9]+' | sort -u | tail -1)"
    if [[ -z "$latest" ]]; then
      echo "ERROR: 无法探测最新 bookworm build 目录（无网络？）"; exit 1
    fi
    ver="$(curl -s --max-time 30 -L "$CLOUD_BASE/$latest/" | grep -oE 'debian-12-genericcloud-arm64-[^"]*\.qcow2' | sort -u | tail -1)"
    if [[ -z "$ver" ]]; then
      echo "ERROR: 在 $CLOUD_BASE/$latest/ 未找到 genericcloud arm64 qcow2"; exit 1
    fi
    echo "  下载 $CLOUD_BASE/$latest/$ver"
    if ! dl "$CLOUD_BASE/$latest/$ver" "$RAW_BASE"; then
      echo "ERROR: 下载 $ver 失败"; exit 1
    fi
    echo "  下载完成 ($(du -h "$RAW_BASE" | awk '{print $1}'))"
  fi
fi

echo "[2/3] 转 raw 并扩容到 ${SIZE_MB}MB"
# 判断是否为 qcow2（magic: "QFI\377" = 51 46 49 fb）
magic="$(head -c 4 "$RAW_BASE" | od -An -tx1 | tr -d ' \n')"
if [[ "$magic" == "514649fb" ]]; then
  echo "  检测到 qcow2 → qemu-img 转换为 raw"
  qemu-img convert -f qcow2 -O raw "$RAW_BASE" "$OUT"
else
  echo "  非 qcow2 魔数，直接拷贝为 raw"
  [[ "$RAW_BASE" == "$OUT" ]] || cp -f "$RAW_BASE" "$OUT"
fi
# 稀疏扩容到目标容量（实际磁盘占用按需分配）
truncate -s "${SIZE_MB}M" "$OUT" 2>/dev/null || true

echo "[3/3] 首启提示"
cat > "$(dirname "$OUT")/prepare-notes.txt" <<'EOF'
Debian genericcloud 首启：
  - 默认用户名 cloud-user / 密码 Debian12
  - 登录前建议：passwd cloud-user 改为强口令
  - 关闭图形：systemctl set-default multi-user.target
EOF
echo "完成: $OUT ($(du -h "$OUT" | awk '{print $1}'))"
