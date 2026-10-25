#!/usr/bin/env bash
# 构建 QEMU（iOS arm64 目标，TCG + TCTI 解释器）。
# 在 macOS Runner（Xcode）上运行。
#
# 关键点：
#  - QEMU 的 configure **不支持** --host=ios，也不认 --sysroot。
#  - 通过 meson 交叉文件（QEMU/meson-ios-cross.txt）告诉 QEMU 的构建系统
#    目标是 iOS（非宿主），从而跳过"运行可执行文件探测"的失败。
#  - 目标架构 host = aarch64（与设备匹配），TCG 默认启用（iOS 无 KVM）。
#  - 禁用 UI/宿主依赖（gtk/sdl/vnc/curl/spice/pixman）减体积并避免链接失败。
#  - 保留 slirp 用于 user-mode 网络。
set -euo pipefail

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
QEMU_SRC="${QEMU_SRC:-qemu-src}"
OUT="${OUT:-$PWD/build/qemu-ios}"
CC_BIN="$(xcrun --find clang)"
CXX_BIN="$(xcrun --find clang++)"

cd "$QEMU_SRC"

# QEMU 构建需要 Python 3.9–3.12。macOS 15 runner 的 /usr/bin/python3 是 3.9.6（无 pip），
# brew 的 python@3.12 有 pip 但需要预装 tomli（Python<3.11 缺 tomllib）。
# 策略：brew 装 python@3.12，创建 venv 装构建依赖，--python 指向它。
PY="$(brew --prefix)/opt/python@3.12/bin/python3.12"
echo "### 使用 Python: $PY ($($PY --version 2>&1))"
VENV="$PWD/.qemu-pyvenv"
rm -rf "$VENV"
"$PY" -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet tomli distlib
export PYTHON="$VENV/bin/python"

# 让 QEMU 使用已装好依赖的解释器 + meson 交叉文件（iOS 目标）
# 关键：QEMU 的 configure 根据 --cross-prefix 生成 build/config-meson.cross，
# 但 iOS/darwin 目标可能不被正确推导，导致 meson 误判同架构并尝试运行
# 可执行文件（"not runnable"）。configure 后手动增强该交叉文件。
echo "### QEMU configure（iOS arm64 交叉编译）"
CC="${CC_BIN}" \
CXX="${CXX_BIN}" \
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
  --disable-docs \
  --disable-guest-agent \
  --cross-prefix=aarch64-apple-ios \
  --extra-cflags="--target=arm64-apple-ios17.0 --sysroot=${SDK}" \
  --extra-cxxflags="--target=arm64-apple-ios17.0 --sysroot=${SDK}" \
  --extra-ldflags="--target=arm64-apple-ios17.0 --sysroot=${SDK}" \
  --prefix="$OUT"

# 手动把 QEMU 生成的 config-meson.cross 增强为正确的 iOS 目标机器
# （QEMU 9.2 生成在 build 子目录或源码目录的 config-meson.cross）
for CF in build/config-meson.cross config-meson.cross; do
  if [[ -f "$CF" ]]; then
    echo "### 增强 meson 交叉文件: $CF"
    cat >> "$CF" <<EOF

# --- DebianTerminal iOS 目标补丁（覆盖同架构误判）---
[built-in options]
c_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
cpp_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
c_link_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']

[properties]
can_run_host_bins = false
root = '${SDK}'

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF
    break
  fi
done

echo "### make"
make -j"$(sysctl -n hw.ncpu)"

echo "QEMU iOS 构建完成: $OUT"
ls -la "$OUT"/bin 2>/dev/null || echo "  (产物路径见 build 日志)"
# 静态库模式：QEMU 会产出 .a，需要把对应 .o/.a 链接进 App
ls -la "$OUT"/lib 2>/dev/null | head -5 || true
