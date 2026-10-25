#!/usr/bin/env bash
# 构建 QEMU（iOS arm64 目标，TCG + TCTI 解释器）。
# 在 macOS Runner（Xcode）上运行。
#
# 关键点：
#  - QEMU 的 configure 不支持 --host=ios，也不认 --sysroot。
#  - QEMU 9.2 的 ./configure 结尾会立即 meson setup，交叉到 iOS 时
#    报 "Executables ... are not runnable"（meson 生成交叉文件缺
#    can_run_host_bins=false + 正确 host_machine）。
#  - QEMU 9.x 将 glib 作为硬依赖。iOS 目标需要为 iOS 交叉编译 glib
#    （静态库），并通过 pkg-config 指向它。
#  - 策略（参考 UTM 的 build_dependencies.sh 思路）：
#      1. 交叉编译 glib 为 iOS 静态库 + 生成 .pc 文件
#         （pcre2 子项目禁用 JIT：iOS 无 RWX 可执行内存，SLJIT JIT 不可用）
#      2. ./configure --skip-meson（只生成 host 端配置）
#      3. 手动生成 meson 交叉文件（can_run_host_bins=false）
#      4. 手动 meson setup + ninja 完成构建
set -euo pipefail

SDK="$(xcrun --sdk iphoneos --show-sdk-path)"
QEMU_SRC="${QEMU_SRC:-qemu-src}"
GLIB_SRC="${GLIB_SRC:-glib-src}"
GLIB_VERSION="${GLIB_VERSION:-2.84.4}"
OUT="${OUT:-$PWD/build/qemu-ios}"
GLIB_OUT="$PWD/build/glib-ios"
CC_BIN="$(xcrun --find clang)"
CXX_BIN="$(xcrun --find clang++)"

# 共用 Python venv（glib 与 QEMU 构建都用 meson/ninja）
PY="$(brew --prefix)/opt/python@3.12/bin/python3.12"
VENV="$PWD/.qemu-pyvenv"
rm -rf "$VENV"
"$PY" -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet "meson>=1.5.0" ninja tomli distlib
MESON="$VENV/bin/meson"
NINJA="$VENV/bin/ninja"
export PYTHON="$VENV/bin/python"

# ---------- Step 1: 交叉编译 glib for iOS ----------
echo "### 交叉编译 glib $GLIB_VERSION for iOS arm64"
if [[ ! -d "$GLIB_SRC" ]]; then
  curl -sSL -o glib.tar.xz "https://download.gnome.org/sources/glib/2.84/glib-${GLIB_VERSION}.tar.xz"
  tar xf glib.tar.xz
  rm glib.tar.xz
  mv "glib-${GLIB_VERSION}" "$GLIB_SRC"
fi
mkdir -p "$GLIB_OUT"
cd "$GLIB_SRC"
# 为 glib 生成 meson 交叉文件（指向 iOS clang）
cat > "$GLIB_OUT/meson-ios-cross.txt" <<GLEOF
[binaries]
c = ['${CC_BIN}', '--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
ar = ['ar']
strip = ['strip']

[built-in options]
c_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
c_link_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']

[properties]
can_run_host_bins = false

[host_machine]
system = 'darwin'
subsystem = 'ios'
kernel = 'xnu'
cpu_family = 'aarch64'
cpu = 'aarch64'
endian = 'little'
GLEOF

"$MESON" setup "$GLIB_OUT/build" \
  --cross-file "$GLIB_OUT/meson-ios-cross.txt" \
  -D prefix="$GLIB_OUT/prefix" \
  -D libdir=lib \
  -D default_library=static \
  -D man=false \
  -D tests=false \
  -D pcre2:jit=disabled
"$NINJA" -C "$GLIB_OUT/build" -j"$(sysctl -n hw.ncpu)"
DESTDIR="" "$NINJA" -C "$GLIB_OUT/build" install || true
GLIB_PC_DIR="$GLIB_OUT/prefix/lib/pkgconfig"
echo "### glib for iOS 构建完成: $GLIB_OUT"
ls -la "$GLIB_PC_DIR" | head -5 || true

# 让 pkg-config 找到 glib 的 .pc 文件（host 端 glib 会干扰，指定优先搜索路径）
PKG_CONFIG_PATH="${PKG_CONFIG_PATH:-}"
export PKG_CONFIG_PATH="$GLIB_PC_DIR:$PKG_CONFIG_PATH"
export PKG_CONFIG_SYSROOT_DIR="$SDK"

cd "$QEMU_SRC"

# ---------- Step 2: QEMU configure（skip-meson，只生成 host 配置） ----------
echo "### 使用 Python: $PY ($($PY --version 2>&1))"

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
  --extra-ldflags="--target=arm64-apple-ios17.0 --sysroot=${SDK} -L${GLIB_PC_DIR%/*} -I${GLIB_OUT}/prefix/include/glib-2.0 -I${GLIB_OUT}/prefix/lib/glib-2.0/include"
  --prefix="$OUT"
)

echo "### QEMU configure（iOS arm64 交叉编译，--skip-meson）"
if CC="${CC_BIN}" CXX="${CXX_BIN}" PKG_CONFIG_PATH="$GLIB_PC_DIR" ./configure "${QEMU_CONFIGURE_ARGS[@]}"; then
  echo "configure 成功"
else
  echo "### configure 失败（非 meson 阶段，请检查日志）"
  exit 1
fi

# ---------- Step 3: 手动生成 meson 交叉文件（iOS 目标 + glib pkg-config） ----------
BUILD_DIR="$PWD/build"
mkdir -p "$BUILD_DIR"
CF="$BUILD_DIR/config-meson.cross"
echo "### 生成 meson 交叉文件: $CF"
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
pkg_config = ['PKG_CONFIG_PATH=${GLIB_PC_DIR} pkg-config']

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

# ---------- Step 4: 手动 meson setup + ninja ----------
echo "### 手动执行 meson setup"
cd "$BUILD_DIR"
PKG_CONFIG_PATH="$GLIB_PC_DIR" "$MESON" setup --reconfigure --cross-file "$CF" --backend ninja . "$QEMU_SRC"
PKG_CONFIG_PATH="$GLIB_PC_DIR" "$NINJA" -C . -j"$(sysctl -n hw.ncpu)"

echo "### 安装产物到 $OUT"
mkdir -p "$OUT"
# 不依赖 meson install（DESTDIR 行为因版本而异），直接从 build 目录收集 QEMU 产物
QEMU_BIN="$BUILD_DIR/qemu-system-aarch64"
if [[ -f "$QEMU_BIN" ]]; then
  mkdir -p "$OUT/bin"
  cp "$QEMU_BIN" "$OUT/bin/qemu-system-aarch64-ios"
  echo "QEMU 可执行文件已复制到: $OUT/bin/qemu-system-aarch64-ios"
  file "$OUT/bin/qemu-system-aarch64-ios" 2>/dev/null || true
else
  echo "WARNING: 未找到 $QEMU_BIN，列出 build 目录产物"
  ls -la "$BUILD_DIR" 2>/dev/null | grep -iE "qemu|\.o$|\.a$|\.dylib$" | head -10
  find "$BUILD_DIR" -name "qemu-system-*" -type f 2>/dev/null | head
fi

echo "QEMU iOS 构建完成"
ls -la "$OUT"/bin 2>/dev/null || echo "  (产物路径见 build 日志)"
ls -la "$OUT"/lib 2>/dev/null | head -5 || true
