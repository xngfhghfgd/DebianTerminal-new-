# QEMU iOS 构建

> QEMU 编译为静态库链接进 App（参考 UTM 的 `Platform/QEMU` 方案），或输出独立 `qemu-system-aarch64` 二进制。默认**解释器（TCTI）模式**保证无 JIT 也能跑。

## 版本固定

- QEMU 基线版本：见 `VERSIONS.txt`
- 解释器：`ktemkin/qemu` 的 `tcg/aarch64-tcti` 分支

## 构建（macOS Runner，iOS SDK 交叉编译）

```bash
SDK=$(xcrun --sdk iphoneos --show-sdk-path)
CC=clang CXX=clang++ ./configure \
  --host=aarch64-apple-ios12.0 \
  --sysroot="$SDK" \
  --target-list=aarch64-softmmu \
  --enable-tcg \
  --disable-kvm \
  --disable-werror \
  --disable-glib \
  --enable-static --disable-system \
  --prefix="$PWD/build"
make -j8
```

## 关键约束

- iOS 无 KVM → 必须 TCG / 解释器。
- 默认解释器模式（无 JIT）：QEMU 用 `-machine virt,tcti=on`。
- 有 JIT 时自动 TCG（性能更好）。
- 不得假设 macOS 上编译成功就等于 iOS 可运行；必须 iOS SDK 交叉编译 + 真机验证。
