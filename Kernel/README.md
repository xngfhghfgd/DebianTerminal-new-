# Linux Kernel（ARM64 virt）

## 获取方式

采用 `virt_defconfig` 为基线，确保 QEMU `virt` 机器所需驱动编译进内核（非模块）：

- `CONFIG_ARM64=y`
- `CONFIG_SERIAL_AMBA_PL011=y`（PL011 UART，console=ttyAMA0）
- `CONFIG_VIRTIO_BLK=y`、`CONFIG_VIRTIO_NET=y`
- `CONFIG_EXT4_FS=y`
- `CONFIG_DEVTMPFS`、`CONFIG_PROC_FS`、`CONFIG_SYSFS`、`CONFIG_TMPFS`

参考：[kernel.org qemu-arm64 howto](https://cdn.kernel.org/pub/linux/kernel/people/will/docs/qemu/qemu-arm64-howto.html)

## 构建（在 Linux 容器中，可放 CI）

```bash
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- defconfig # 基线
# 或直接用 virt_defconfig:
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- virt_defconfig
make ARCH=arm64 CROSS_COMPILE=aarch64-linux-gnu- -j8
# 产物: arch/arm64/boot/Image
```

## 固定版本

见 `VERSIONS.txt`。
