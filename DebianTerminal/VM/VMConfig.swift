import Foundation

/// 虚拟机配置：CPU、内存、磁盘、内核、启动参数、网络、JIT。
/// 统一在此管理，**不写死在多个源文件**。
struct VMConfig: Codable, Equatable {
    var cpuCores: Int = 2
    var guestMemoryMB: Int = 2048
    var machineType: String = "virt"
    var cpuModel: String = "max"
    var kernelPath: String = "Image"
    var diskPath: String = "Documents/Debian/debian12.img"
    var console: String = "ttyAMA0"
    var networkBackend: String = "user"
    /// false = 使用 TCTI 线程解释器（无需 JIT）；true = 允许 TCG JIT（需检测通过）
    var allowJIT: Bool = false
    var append: String = "root=/dev/vda rw console=ttyAMA0"
    var nographic: Bool = true
    var qemuBinary: String = "qemu-system-aarch64"

    static func load() -> VMConfig {
        guard let data = UserDefaults.standard.data(forKey: "vmconfig"),
              let cfg = try? JSONDecoder().decode(VMConfig.self, from: data)
        else { return VMConfig() }
        return cfg
    }

    func save() {
        let data = try? JSONEncoder().encode(self)
        UserDefaults.standard.set(data, forKey: "vmconfig")
    }

    /// 生成 QEMU 命令行（候选模板，**非最终验证配置**）。
    func qemuArguments() -> [String] {
        var args: [String] = [
            "-machine", machineType,
            "-cpu", cpuModel,
            "-smp", String(cpuCores),
            "-m", String(guestMemoryMB),
            "-kernel", kernelPath,
            "-drive", "file=\(diskPath),if=virtio,format=raw",
            "-append", append,
            "-netdev", "user,id=n0",
            "-device", "virtio-net-device,netdev=n0",
            "-serial", "mon:stdio"
        ]
        if nographic { args.append("-nographic") }
        return args
    }

    var allowedMemoryOptions: [Int] { [1024, 2048, 4096] }
    var allowedCpuOptions: [Int] { [1, 2, 4] }
}
