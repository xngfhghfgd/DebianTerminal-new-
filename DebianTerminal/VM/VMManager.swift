import Foundation

/// 虚拟机生命周期管理：启动 / 停止 / 重启 / 强制停止 / 状态检测 / 资源释放。
///
/// POC 说明：
/// - QEMU 以独立进程方式由 App spawn（`posix_spawn`），串口 `std:chardev` 双向管道。
/// - 默认解释器（TCTI）模式保证无 JIT 也能跑；JIT 可用时 QEMU 自动切 TCG。
/// - 本文件只管理一个 QEMU 实例，**避免重复启动**。
final class VMManager: @unchecked Sendable {
    private var process: QEMUProcess?
    private let lock = NSLock()

    struct QEMUProcess {
        let pid: pid_t
        let outPipe: FileHandle
        let inPipe: FileHandle
    }

    enum VMError: LocalizedError {
        case qemuNotFound(String)
        case spawnFailed
        case alreadyRunning
        case ioError(String)

        var errorDescription: String? {
            switch self {
            case .qemuNotFound(let p): return "找不到 QEMU 二进制：\(p)"
            case .spawnFailed: return "spawn QEMU 失败"
            case .alreadyRunning: return "虚拟机已在运行"
            case .ioError(let m): return "IO 错误：\(m)"
            }
        }
    }

    /// 启动虚拟机。返回（输出流 AsyncLineSequence，输入流）。
    @discardableResult
    func start(config: VMConfig) async throws -> (AsyncLineStream<String>, FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        if let p = process {
            _ = p
            throw VMError.alreadyRunning
        }

        guard let qemuURL = locateQEMU() else {
            throw VMError.qemuNotFound(config.qemuBinary)
        }

        // 解析参数（绝对路径替换）
        var args = [qemuURL.absoluteString]
        for a in config.qemuArguments() {
            args.append(resolveAsset(a, config: config))
        }

        // 解释器模式开关：无 JIT 时强制 TCTI（若 QEMU 支持）。
        // 有 JIT 时用默认 TCG。
        if !JITDetector.detect().isAvailable {
            args.append(contentsOf: ["-machine", "virt,tcti=on"])
        }

        // 双向 chardev 管道
        let inPipe = try makePipe()
        let outPipe = try makePipe()

        // posix_spawn QEMU
        var spawn = posix_spawn_file_actions_t()
        posix_spawn_file_actions_init(&spawn)
        posix_spawn_file_actions_addclose(&spawn, 0)
        posix_spawn_file_actions_adddup2(&spawn, outPipe, 1) // stdout -> outPipe
        posix_spawn_file_actions_adddup2(&spawn, inPipe, 0)  // inPipe -> stdin

        var env = [environ!]
        var pid: pid_t = 0
        let cArgs = args.map { $0.withCString() } + [nil]
        var argvBuf: [UnsafeMutablePointer<CChar>?] = cArgs.map { UnsafeMutablePointer(mutating: $0) }
        let rc = withUnsafeMutablePointer(to: &pid) { pidPtr in
            posix_spawn(
                pidPtr, qemuURL.path, &spawn, nil,
                argvBuf.withUnsafeMutableBufferPointer { buf in
                    buf.baseAddress!
                },
                env.withUnsafeMutableBufferPointer { buf in
                    buf.baseAddress!
                }
            )
        }
        posix_spawn_file_actions_destroy(&spawn)

        guard rc == 0 else { throw VMError.spawnFailed }

        process = QEMUProcess(pid: pid, outPipe: outPipe, inPipe: inPipe)

        let outStream = outPipe.lines
        return (outStream, inPipe)
    }

    func stop() async {
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        guard let p = p else { return }
        kill(p.pid, SIGTERM)
        waitpid(p.pid, nil, 0)
    }

    func forceStop() async {
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        guard let p = p else { return }
        kill(p.pid, SIGKILL)
        waitpid(p.pid, nil, 0)
    }

    func isRunning() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let p = process else { return false }
        return kill(p.pid, 0) == 0
    }

    /// 关闭 App 前调用：向 Guest 发关机信号（POC 简化为 SIGTERM QEMU）。
    func shutdownGracefully() async {
        await stop()
    }

    // MARK: - 资源定位

    /// QEMU 二进制：优先 App Bundle 内 resources，其次 Documents。
    private func locateQEMU() -> URL? {
        if let url = Bundle.main.url(forResource: "qemu-system-aarch64", withExtension: nil) {
            return url
        }
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let candidate = docs.appendingPathComponent("qemu-system-aarch64")
        if FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        return nil
    }

    private func resolveAsset(_ a: String, config: VMConfig) -> String {
        // 相对资源名映射到 Bundle / Documents
        if a.hasPrefix("Documents/") {
            let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return docs.appendingPathComponent(String(a.dropFirst("Documents/".count))).path
        }
        if Bundle.main.url(forResource: a, withExtension: nil) != nil {
            return Bundle.main.url(forResource: a, withExtension: nil)!.path
        }
        return a
    }

    private func makePipe() throws -> FileHandle {
        var fds: [int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw VMError.ioError("pipe() 失败") }
        return FileHandle(fileDescriptor: fds[1])
    }
}
