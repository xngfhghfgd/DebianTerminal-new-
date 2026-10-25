#!/usr/bin/env bash
# 构建 QEMU（iOS arm64 目标，TCG + TCTI 解释器）。
# 在 macOS Runner（Xcode）上运行。
#
# 关键点：
#  - QEMU 的 configure 不支持 --host=ios，也不认 --sysroot。
#  - QEMU 9.2 的 ./configure 结尾会立即 meson setup，交叉到 iOS 时
#    报 "Executables ... are not runnable"（meson 生成交叉文件缺
#    can_run_host_bins=false + 正确 host_machine）。
#  - 策略：允许 configure 走到 meson 阶段失败 → 修补它生成的
#    config-meson.cross → 手动 re-run meson setup + ninja 完成构建。
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

QEMU_CONFIGURE_ARGS=(
  --python="$PYTHON"
  --target-list=aarch64-softmmu
  --enable-tcg
  --disable-kvm
  --disable-werror
  --disable-gtk
  --disable-sdl
  --disable-vnc
  --disable-curl
  --disable-spice
  --disable-pixman
  --disable-slirp
  --disable-docs
  --disable-guest-agent
  --cross-prefix=aarch64-apple-ios
  --extra-cflags="--target=arm64-apple-ios17.0 --sysroot=${SDK}"
  --extra-cxxflags="--target=arm64-apple-ios17.0 --sysroot=${SDK}"
  --extra-ldflags="--target=arm64-apple-ios17.0 --sysroot=${SDK}"
  --prefix="$OUT"
)

echo "### QEMU configure（iOS arm64 交叉编译，允许 meson 阶段失败）"
if CC="${CC_BIN}" CXX="${CXX_BIN}" ./configure "${QEMU_CONFIGURE_ARGS[@]}"; then
  echo "configure 成功"
else
  echo "### configure 在 meson 阶段失败（预期），检查生成的交叉文件"
fi

# 修补 QEMU 生成的 config-meson.cross：补 can_run_host_bins=false + 正确 host_machine
# （QEMU 生成在 build 子目录；configure 开头会自动 cd 到 build/）
BUILD_DIR="$PWD/build"
CF=""
for cand in "$BUILD_DIR/config-meson.cross" "$PWD/config-meson.cross"; do
  [[ -f "$cand" ]] && { CF="$cand"; break; }
done
if [[ -z "$CF" ]]; then
  echo "ERROR: 找不到 QEMU 生成的 config-meson.cross"
  exit 1
fi
echo "### 增强 meson 交叉文件: $CF"
cat >> "$CF" <<EOF

# --- DebianTerminal iOS 目标补丁（覆盖同架构误判 + 禁止运行宿主可执行文件）---
[properties]
can_run_host_bins = false

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
EOF

# 手动 re-run meson setup（跳过已成功的 configure 阶段，直接补 meson）
echo "### 重新执行 meson setup"
cd "$BUILD_DIR"
# QEMU 用 meson 子模块；优先 venv 里的 meson，否则系统
MESON=""
if [[ -x "$VENV/bin/meson" ]]; then MESON="$VENV/bin/meson"; fi
if [[ -z "$MESON" ]] && command -v meson >/dev/null 2>&1; then MESON="$(command -v meson)"; fi
if [[ -z "$MESON" ]]; then
  echo "ERROR: 找不到 meson，安装到 venv"
  "$VENV/bin/python" -m pip install --quiet meson ninja
  MESON="$VENV/bin/meson"
fi
"$MESON" setup --reconfigure . 2>&1 | tail -20

echo "### make"
cd "$QEMU_SRC"
make -j"$(sysctl -n hw.ncpu)"

echo "QEMU iOS 构建完成: $OUT"
ls -la "$OUT"/bin 2>/dev/null || echo "  (产物路径见 build 日志)"
# 静态库模式：QEMU 会产出 .a，需要把对应 .o/.a 链接进 App
ls -la "$OUT"/lib 2>/dev/null | head -5 || true
