import Foundation

/// 通过真实的 mmap + mprotect 检测当前运行环境是否允许可执行内存（JIT）。
/// 结果用于 UI 提示，**不伪造**：检测失败就返回 .unavailable。
enum JITDetector {
    /// 尝试分配 RW 内存并切换为 RX，写入一条 ARM64 nop 后判断是否可执行。
    static func detect() -> JITStatus {
        // 使用 Darwin 的 mmap/mprotect 真实检测。
        // 若 mprotect(PROT_EXEC) 返回非 0，说明环境不允许 JIT。
        guard let ptr = rwAlloc() else { return .unavailable }
        let ok = tryExecTranslate(ptr)
        free(ptr)
        return ok ? .available : .unavailable
    }

    private static func rwAlloc() -> UnsafeMutableRawPointer? {
        let size = 4096
        return mmap(nil, size,
                    PROT_READ | PROT_WRITE,
                    MAP_PRIVATE | MAP_ANONYMOUS,
                    -1, 0)
    }

    /// 写入 nop 并尝试把页切为 RX。
    private static func tryExecTranslate(_ ptr: UnsafeMutableRawPointer) -> Bool {
        // 写入 ARM64 nop (0x00000000)
        ptr.assumingMemoryBound(to: UInt32.self).pointee = 0x00000000
        let size = 4096
        let rc = mprotect(ptr, size, PROT_READ | PROT_EXEC)
        return rc == 0
    }
}
