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
  --skip-meson
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

# --skip-meson 跳过了 configure 内部的 meson 调用，config-meson.cross 未被生成。
# 这里手动生成一份正确的 meson 交叉文件（iOS aarch64 目标），再 meson setup。
cd "$QEMU_SRC"
BUILD_DIR="$PWD/build"
mkdir -p "$BUILD_DIR"
CF="$BUILD_DIR/config-meson.cross"
echo "### 生成 meson 交叉文件: $CF"
# meson 交叉文件的 binaries 需要带引号的路径；用 printf 预生成避免 bash 扩展问题
CC_QUOTED="'$CC_BIN'"
CXX_QUOTED="'$CXX_BIN'"
cat > "$CF" <<EOF
# 自动生成：DebianTerminal iOS aarch64 交叉编译（macOS host -> iOS）
[binaries]
c = [$CC_QUOTED, '--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
cpp = [$CXX_QUOTED, '--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
objc = [$CC_QUOTED, '--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
objcpp = [$CXX_QUOTED, '--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
ar = ['ar']
strip = ['strip']

[built-in options]
c_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
cpp_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
c_link_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
cpp_link_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
objc_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
objcpp_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']

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

# 手动 meson setup（--skip-meson 跳过了 configure 内部的 meson，现在补齐）
echo "### 手动执行 meson setup"
cd "$BUILD_DIR"
MESON=""
if [[ -x "$VENV/bin/meson" ]]; then MESON="$VENV/bin/meson"; fi
if [[ -z "$MESON" ]] && command -v meson >/dev/null 2>&1; then MESON="$(command -v meson)"; fi
if [[ -z "$MESON" ]]; then
  "$VENV/bin/python" -m pip install --quiet "meson>=1.5.0"
  MESON="$VENV/bin/meson"
fi
NINJA=""
if [[ -x "$VENV/bin/ninja" ]]; then NINJA="$VENV/bin/ninja"; fi
if [[ -z "$NINJA" ]] && command -v ninja >/dev/null 2>&1; then NINJA="$(command -v ninja)"; fi
if [[ -z "$NINJA" ]]; then
  "$VENV/bin/python" -m pip install --quiet ninja
  NINJA="$VENV/bin/ninja"
fi
echo "  meson: $MESON"
echo "  ninja: $NINJA"
"$MESON" setup --reconfigure --cross-file "$CF" --backend ninja . "$QEMU_SRC"
"$NINJA" -C . -j"$(sysctl -n hw.ncpu)"

echo "### 安装产物到 $OUT"
mkdir -p "$OUT"
"$NINJA" -C . install DESTDIR="" || true

echo "QEMU iOS 构建完成"
ls -la "$OUT"/bin 2>/dev/null || echo "  (产物路径见 build 日志)"
ls -la "$OUT"/lib 2>/dev/null | head -5 || true
