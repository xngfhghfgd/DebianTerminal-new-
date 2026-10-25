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
#      1. 交叉编译 zlib + libffi + glib 为 iOS 静态库 + 生成 .pc 文件
#         （pcre2 子项目禁用 JIT：iOS 无 RWX 可执行内存，SLJIT JIT 不可用）
#      2. ./configure --skip-meson（只生成 host 端配置）
#      3. 手动生成 meson 交叉文件（can_run_host_bins=false + pkg-config 包装脚本）
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
IOS_TARGET="--target=arm64-apple-ios17.0 --sysroot=${SDK}"

# 共用 Python venv（glib 与 QEMU 构建都用 meson/ninja）
PY="$(brew --prefix)/opt/python@3.12/bin/python3.12"
VENV="$PWD/.qemu-pyvenv"
rm -rf "$VENV"
"$PY" -m venv "$VENV"
"$VENV/bin/python" -m pip install --quiet "meson>=1.5.0" ninja tomli distlib
MESON="$VENV/bin/meson"
NINJA="$VENV/bin/ninja"
export PYTHON="$VENV/bin/python"

mkdir -p "$GLIB_OUT"
IOS_PC_DIR="$GLIB_OUT/ios-pc"   # iOS 库的 .pc 文件集中目录

# ---------- Step 1a: 交叉编译 zlib + libffi for iOS（glib 依赖） ----------
echo "### 交叉编译 zlib + libffi for iOS arm64"
ZLIB_SRC="${ZLIB_SRC:-zlib-src}"
LIBFFI_SRC="${LIBFFI_SRC:-libffi-src}"
LIBFFI_VERSION="${LIBFFI_VERSION:-3.4.7}"
mkdir -p "$IOS_PC_DIR"

# --- zlib (CMake) ---
if [[ ! -d "$ZLIB_SRC" ]]; then
  curl -sSL --retry 3 -o zlib.tar.gz "https://github.com/madler/zlib/releases/download/v1.3.1/zlib-1.3.1.tar.gz"
  tar xf zlib.tar.gz
  rm -f zlib.tar.gz
  # 解压出的顶层目录可能是 zlib-1.3.1 或 zlib
  if [[ -d "zlib-1.3.1" ]]; then mv zlib-1.3.1 "$ZLIB_SRC"; else mv zlib "$ZLIB_SRC"; fi
fi
cmake -S "$ZLIB_SRC" -B "$GLIB_OUT/zlib-build" -G Ninja \
  -DCMAKE_SYSTEM_NAME=Darwin \
  -DCMAKE_SYSTEM_PROCESSOR=arm64 \
  -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
  -DCMAKE_OSX_SYSROOT="$SDK" \
  -DCMAKE_C_FLAGS="$IOS_TARGET" \
  -DCMAKE_CXX_FLAGS="$IOS_TARGET" \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$GLIB_OUT/zlib-prefix" \
  -DZLIB_STATIC=ON -DZLIB_ENABLE_TESTS=OFF -DMINIZIP=OFF
cmake --build "$GLIB_OUT/zlib-build" -j"$(sysctl -n hw.ncpu)"
cmake --install "$GLIB_OUT/zlib-build"
echo "### zlib for iOS 完成: $GLIB_OUT/zlib-prefix"

# --- libffi (autoconf) ---
if [[ ! -d "$LIBFFI_SRC" ]]; then
  curl -sSL --retry 3 -L -o libffi.tar.gz "https://github.com/libffi/libffi/releases/download/v${LIBFFI_VERSION}/libffi-${LIBFFI_VERSION}.tar.gz"
  tar xf libffi.tar.gz
  rm -f libffi.tar.gz
  # 解压出的顶层目录可能是 libffi-3.4.7 或 libffi
  if [[ -d "libffi-${LIBFFI_VERSION}" ]]; then mv "libffi-${LIBFFI_VERSION}" "$LIBFFI_SRC"; else mv libffi "$LIBFFI_SRC"; fi
fi
mkdir -p "$GLIB_OUT/libffi-build"
( cd "$LIBFFI_SRC" \
  && CC="$CC_BIN" CXX="$CXX_BIN" ./configure \
    --host=aarch64-apple-ios \
    --prefix="$GLIB_OUT/libffi-prefix" \
    --disable-docs \
    --enable-shared=no --enable-static \
    CFLAGS="$IOS_TARGET" LDFLAGS="$IOS_TARGET" \
  && make -j"$(sysctl -n hw.ncpu)" \
  && make install )
echo "### libffi for iOS 完成: $GLIB_OUT/libffi-prefix"

# 生成 zlib + libffi 的 .pc 文件（集中放入 iOS .pc 目录）
cat > "$IOS_PC_DIR/zlib.pc" <<PC
prefix=$GLIB_OUT/zlib-prefix
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include
Name: zlib
Description: zlib compression library (iOS cross)
Version: 1.3.1
Libs: -L\${libdir} -lz
Cflags: -I\${includedir}
PC
cat > "$IOS_PC_DIR/libffi.pc" <<PC
prefix=$GLIB_OUT/libffi-prefix
exec_prefix=\${prefix}
libdir=\${exec_prefix}/lib
includedir=\${prefix}/include
Name: libffi
Description: libffi foreign-function interface (iOS cross)
Version: ${LIBFFI_VERSION}
Libs: -L\${libdir} -lffi
Cflags: -I\${includedir}
PC
echo "### .pc 文件就绪: $IOS_PC_DIR"
ls "$IOS_PC_DIR"

# ---------- Step 1b: 交叉编译 glib for iOS ----------
echo "### 交叉编译 glib $GLIB_VERSION for iOS arm64"
if [[ ! -d "$GLIB_SRC" ]]; then
  curl -sSL -o glib.tar.xz "https://download.gnome.org/sources/glib/2.84/glib-${GLIB_VERSION}.tar.xz"
  tar xf glib.tar.xz
  rm glib.tar.xz
  mv "glib-${GLIB_VERSION}" "$GLIB_SRC"
fi
# 为 glib 生成 meson 交叉文件（指向 iOS clang + pkg-config 找到 zlib/libffi）
PKG_WRAPPER_GLIB="$GLIB_OUT/pkg-config-glib"
cat > "$PKG_WRAPPER_GLIB" <<GW
#!/bin/sh
# 只搜索 iOS 库的 .pc（glib 构建期）
export PKG_CONFIG_PATH="${IOS_PC_DIR}"
exec pkg-config "\$@"
GW
chmod +x "$PKG_WRAPPER_GLIB"

cat > "$GLIB_OUT/meson-ios-cross.txt" <<GLEOF
[binaries]
c = ['${CC_BIN}', '--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
ar = ['ar']
strip = ['strip']
pkg-config = ['${PKG_WRAPPER_GLIB}']

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

# 切到 glib 源码目录再 meson setup（source dir = 当前目录）
cd "$GLIB_SRC"
# --force-fallback-for=pcre2: 强制用 glib 自带 subproject pcre2（iOS 静态），
# 避免 meson 通过 cmake 找到 homebrew 的 macOS pcre2 dylib 导致链接架构不匹配
"$MESON" setup "$GLIB_OUT/build" \
  --cross-file "$GLIB_OUT/meson-ios-cross.txt" \
  --force-fallback-for=pcre2 \
  -D prefix="$GLIB_OUT/prefix" \
  -D libdir=lib \
  -D default_library=static \
  -D man=false \
  -D tests=false \
  -D pcre2:jit=disabled \
  -D pcre2:grep=false
"$NINJA" -C "$GLIB_OUT/build" -j"$(sysctl -n hw.ncpu)"
DESTDIR="" "$NINJA" -C "$GLIB_OUT/build" install || true
GLIB_PC_DIR="$GLIB_OUT/prefix/lib/pkgconfig"
echo "### glib for iOS 构建完成: $GLIB_OUT"
ls -la "$GLIB_PC_DIR" | head -8 || true

# 合并 iOS .pc 目录：glib + gobject + gio + zlib + libffi
COMBINED_PC="$GLIB_OUT/combined-pc"
mkdir -p "$COMBINED_PC"
cp -f "$GLIB_PC_DIR"/*.pc "$COMBINED_PC"/ 2>/dev/null || true
cp -f "$IOS_PC_DIR"/*.pc "$COMBINED_PC"/ 2>/dev/null || true
ls "$COMBINED_PC"

# 让 pkg-config 找到 glib 的 .pc 文件（host 端 glib 会干扰，用包装脚本固化搜索路径）
export PKG_CONFIG_PATH="$COMBINED_PC"
# 不设 PKG_CONFIG_SYSROOT_DIR：glib 前缀是 /Users/runner 绝对路径，
# sysroot 会让 meson 把 -I 前缀改到 SDK 下导致 glib.h 找不到。

# 生成 pkg-config 包装脚本（meson 交叉文件只接受可执行文件路径）
PKG_WRAPPER="$GLIB_OUT/pkg-config-ios"
cat > "$PKG_WRAPPER" <<WRAP
#!/bin/sh
# 只搜索 iOS 库的 .pc（QEMU 构建期）
export PKG_CONFIG_PATH="${COMBINED_PC}"
exec pkg-config "\$@"
WRAP
chmod +x "$PKG_WRAPPER"
echo "### pkg-config 包装脚本: $PKG_WRAPPER"

cd "$QEMU_SRC"

# ---------- Step 2: QEMU configure（skip-meson，只生成 host 配置） ----------
echo "### 使用 Python: $PY ($($PY --version 2>&1))"

# 修补 QEMU osdep.h：iOS 上 pthread_jit_write_protect_np 不可用，
# 该 API 只在启用 JIT 时有意义；本构建 TCG+TCTI 解释器不需要 JIT。
# 用 sed 将两处调用替换为空操作（保守、不碰逻辑）。
OSDEP="$QEMU_SRC/include/qemu/osdep.h"
if grep -q "pthread_jit_write_protect_np" "$OSDEP" 2>/dev/null; then
  # 将 pthread_jit_write_protect_np(true) 和 (false) 替换为空语句
  sed -i.bak 's/^[[:space:]]*pthread_jit_write_protect_np(true);/    \/\/ no-op on iOS (JIT write protect unavailable)/' "$OSDEP"
  sed -i.bak 's/^[[:space:]]*pthread_jit_write_protect_np(false);/    \/\/ no-op on iOS (JIT write protect unavailable)/' "$OSDEP"
  echo "### osdep.h 已修补：pthread_jit_write_protect_np -> noop (iOS)"
fi

# 修补 QEMU block/file-posix.c：__APPLE__ 块内用 fstatfs/struct statfs 设置磁盘
# 传输大小提示，但 iOS SDK 上该 API 声明不完整（incomplete type / undeclared）。
# 这段只是性能优化提示，非必需。保守做法：将整个 APPLE 块替换为 no-op。
FP="$QEMU_SRC/block/file-posix.c"
if grep -q "fstatfs" "$FP" 2>/dev/null; then
  python3 - "$FP" <<'PYFIX'
import sys, re
path = sys.argv[1]
src = open(path).read()
# 找到 "#if defined(__APPLE__) && (__MACH__)" 块并替换为 no-op
pattern = re.compile(
    r"#if defined\(__APPLE__\) && \(__MACH__\)\n"
    r"    struct statfs buf;\n\n"
    r"    if \(!fstatfs\(s->fd, &buf\)\) \{\n"
    r"        bs->bl\.opt_transfer = buf\.f_iosize;\n"
    r"        bs->bl\.pdiscard_alignment = buf\.f_bsize;\n"
    r"    \}\n"
    r"#endif"
)
new = ("#if defined(__APPLE__) && (__MACH__)\n"
       "    /* iOS: fstatfs/statfs 在 iOS SDK 上声明不完整，跳过磁盘传输大小提示 */\n"
       "    (void)s;\n"
       "#endif")
m = pattern.search(src)
if m:
    src = src[:m.start()] + new + src[m.end():]
    open(path, 'w').write(src)
    print("### file-posix.c 已修补：__APPLE__ fstatfs 块 -> no-op (iOS)")
else:
    # fallback: 直接注释掉两行 statfs 使用（若上面正则不匹配）
    src = src.replace('struct statfs buf;', '/* iOS: no-op */')
    src = src.replace('if (!fstatfs(s->fd, &buf)) {', 'if (0) { /* iOS: fstatfs unavailable */')
    src = src.replace('bs->bl.opt_transfer = buf.f_iosize;', '')
    src = src.replace('bs->bl.pdiscard_alignment = buf.f_bsize;', '')
    open(path, 'w').write(src)
    print("### file-posix.c 已修补(fallback)：fstatfs 行注释 (iOS)")
PYFIX
fi

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
  --extra-cflags="$IOS_TARGET"
  --extra-cxxflags="$IOS_TARGET"
  --extra-ldflags="$IOS_TARGET -L${GLIB_PC_DIR} -L${GLIB_OUT}/libffi-prefix/lib -L${GLIB_OUT}/zlib-prefix/lib -I${GLIB_OUT}/prefix/include/glib-2.0 -I${GLIB_OUT}/prefix/lib/glib-2.0/include -I${GLIB_OUT}/libffi-prefix/include"
  --prefix="$OUT"
)

echo "### QEMU configure（iOS arm64 交叉编译，--skip-meson）"
if CC="${CC_BIN}" CXX="${CXX_BIN}" PKG_CONFIG_PATH="$COMBINED_PC" ./configure "${QEMU_CONFIGURE_ARGS[@]}"; then
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
# 生成 wrapper：宿主端 pkg-config + PKG_CONFIG_PATH 指向 iOS 的 .pc（含 glib/zlib/libffi/pcre2）
PKG_WRAPPER="$GLIB_OUT/pkg-config-qemu"
cat > "$PKG_WRAPPER" <<WRAP
#!/bin/sh
# host 端 pkg-config，只搜索 iOS 库的 .pc（QEMU 构建期）
export PKG_CONFIG_PATH="${COMBINED_PC}"
exec pkg-config "\$@"
WRAP
chmod +x "$PKG_WRAPPER"
cat > "$CF" <<EOF
# 自动生成：DebianTerminal iOS aarch64 交叉编译（macOS host -> iOS）
[binaries]
c = [$CC_QUOTED, '--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
cpp = [$CXX_QUOTED, '--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
objc = [$CC_QUOTED, '--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
objcpp = [$CXX_QUOTED, '--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
ar = ['ar']
strip = ['strip']
pkg-config = ['$PKG_WRAPPER']

[built-in options]
c_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
cpp_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
c_link_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
cpp_link_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
objc_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']
objcpp_args = ['--target=arm64-apple-ios17.0', '--sysroot=${SDK}']

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
echo "### meson cross file written: $CF (pkg-config -> $PKG_WRAPPER)"

# ---------- Step 4: 手动 meson setup + ninja ----------
echo "### 手动执行 meson setup"
cd "$BUILD_DIR"
# wrapper 自带 PKG_CONFIG_PATH，无需 export
# 诊断：确认 pkg-config 能解析 glib-2.0 的 Cflags / Libs
echo "### glib-2.0.pc 内容："
cat "$COMBINED_PC/glib-2.0.pc" 2>/dev/null || echo "  (缺失 glib-2.0.pc)"
echo "### pkg-config --cflags glib-2.0:"
PKG_CONFIG_PATH="$COMBINED_PC" pkg-config --cflags glib-2.0 2>&1 || echo "  (pkg-config 解析失败)"
echo "### pkg-config --libs glib-2.0:"
PKG_CONFIG_PATH="$COMBINED_PC" pkg-config --libs glib-2.0 2>&1 || echo "  (pkg-config 解析失败)"
"$MESON" setup --reconfigure --cross-file "$CF" --backend ninja . "$QEMU_SRC" \
  -Dcurl=disabled \
  -Dslirp=disabled \
  -Dvnc=disabled \
  -Dgtk=disabled \
  -Dsdl=disabled \
  -Dcoreaudio=disabled \
  -Ddbus_display=disabled \
  -Dspice=disabled \
  -Dspice_protocol=disabled \
  -Dvde=disabled \
  -Dgnutls=disabled \
  -Dpixman=disabled \
  -Dlibpng=disabled \
  -Dlibusb=disabled \
  -Dzstd=disabled \
  -Dlzo=disabled
"$NINJA" -C . -j"$(sysctl -n hw.ncpu)"

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
  echo "WARNING: qemu-system-aarch64 not found at $QEMU_BIN - listing build dir"
  find "$BUILD_DIR" -name "qemu-system-*" -type f 2>/dev/null | head
fi

# 同步 QEMU 所需静态库（glib/zlib/libffi）到 OUT/lib
mkdir -p "$OUT/lib"
find "$GLIB_OUT/prefix/lib" -name "*.a" -exec cp -f {} "$OUT/lib/" \; 2>/dev/null || true
find "$GLIB_OUT/libffi-prefix/lib" -name "*.a" -exec cp -f {} "$OUT/lib/" \; 2>/dev/null || true
find "$GLIB_OUT/zlib-prefix/lib" -name "*.a" -exec cp -f {} "$OUT/lib/" \; 2>/dev/null || true
echo "QEMU iOS 构建完成: $OUT"
ls -la "$OUT"/bin 2>/dev/null || true
ls -la "$OUT"/lib 2>/dev/null | head -5 || true
