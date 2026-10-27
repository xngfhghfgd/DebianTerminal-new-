import Foundation
import Darwin

/// 行式异步序列：从 `FileHandle` 逐字节读取并按换行切分成 `String`。
///
/// Foundation 的 `FileHandle` 没有内置的按行异步迭代器，故在此实现
/// 一个最小的 `AsyncSequence`，供 `for await line in ...` 使用。
struct AsyncLineSequence: AsyncSequence {
    var fileHandle: FileHandle

    struct LineIterator: AsyncIteratorProtocol {
        var buffer: [UInt8] = []
        let handle: FileHandle

        mutating func next() async -> String? {
            do {
                while true {
                    let data = try handle.availableData
                    if data.isEmpty {
                        // EOF：把残存 buffer 作为最后一行返回（若非空）
                        if buffer.isEmpty { return nil }
                        let line = String(decoding: buffer, as: UTF8.self)
                        buffer.removeAll()
                        return line
                    }
                    // 处理本块数据：按 \n 切行，残段留 buffer
                    for byte in data {
                        if byte == 0x0A {
                            let line = String(decoding: buffer, as: UTF8.self)
                            buffer.removeAll()
                            return line
                        }
                        buffer.append(byte)
                    }
                    // 本块无换行，回到 while 继续读
                }
            } catch {
                // 读错误（如 pipe 关闭）：结束迭代
                if !buffer.isEmpty {
                    let line = String(decoding: buffer, as: UTF8.self)
                    buffer.removeAll()
                    return line
                }
                return nil
            }
        }
    }

    func makeAsyncIterator() -> LineIterator {
        LineIterator(handle: fileHandle)
    }
}

/// 虚拟机生命周期管理：启动 / 停止 / 重启 / 强制停止 / 状态检测 / 资源释放。
///
/// POC 说明：
/// - QEMU 以独立进程方式由 App spawn（`posix_spawn`），串口 `chardev` 双向管道。
/// - 默认解释器（TCTI）模式保证无 JIT 也能跑；JIT 可用时 QEMU 自动切 TCG。
/// - 本文件只管理一个 QEMU 实例，**避免重复启动**。
/// - 运行行为（实际启动 QEMU / 读串口）属于阶段 B–F 实机验证；此处只保证
///   构建可编译，且资源定位逻辑正确。
final class VMManager: @unchecked Sendable {
    private var process: QEMUProcess?
    private let lock = NSLock()

    struct QEMUProcess {
        let pid: pid_t
        /// 读 QEMU stdout 的读端（App 侧读端）。
        let outPipe: FileHandle
        /// 写 QEMU stdin 的写端（App 侧写端）。
        let inPipe: FileHandle
        /// QEMU 持有的对端 fd（防止泄漏；进程退出后可关闭）。
        let outPipeOwner: Int32
        let inPipeOwner: Int32
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

    /// 启动虚拟机。返回（输出异步行序列，输入写端 `FileHandle`）。
    @discardableResult
    func start(config: VMConfig) async throws -> (AsyncLineSequence, FileHandle) {
        lock.lock()
        defer { lock.unlock() }
        if process != nil {
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

        // 双向 chardev 管道（保存对端 fd，防泄漏）
        let (outRead, outWrite) = try makePipe()
        let (inRead, inWrite) = try makePipe()

        // posix_spawn QEMU：
        //   QEMU stdout -> outWrite（QEMU 写端），App 读 outRead
        //   QEMU stdin  <- inRead（QEMU 读端），App 写 inWrite
        let pid = try spawnQEMU(qemuPath: qemuURL.path,
                                 args: args,
                                 stdoutFD: outWrite,
                                 stdinFD: inRead)
        // QEMU 已持有 outWrite/inRead 端，关闭 App 侧冗余引用
        close(outWrite)
        close(inRead)

        let outPipe = FileHandle(fileDescriptor: outRead)
        let inPipe = FileHandle(fileDescriptor: inWrite)

        process = QEMUProcess(pid: pid,
                              outPipe: outPipe,
                              inPipe: inPipe,
                              outPipeOwner: outRead,
                              inPipeOwner: inWrite)

        let outStream = AsyncLineSequence(fileHandle: outPipe)
        return (outStream, inPipe)
    }

    /// 用 `posix_spawn` 启动 QEMU 进程。
    /// - 参数：qemuPath（绝对路径）、args（含可执行文件在首元素）、
    ///   stdoutFD（子进程 stdout 重定向的 fd）、stdinFD（子进程 stdin 重定向的 fd）。
    /// - 返回子进程 pid；失败抛 `VMError.spawnFailed`。
    private func spawnQEMU(qemuPath: String,
                           args: [String],
                           stdoutFD: Int32,
                           stdinFD: Int32) throws -> pid_t {
        // posix_spawn_file_actions_t 在 iOS 以不透明 struct（≈ UnsafeMutableRawPointer）导入。
        // 分配原始内存并用 assumingMemoryBound 桥接为 C API 期望的 optional 指针。
        let mem = UnsafeMutableRawPointer.allocate(byteCount: 32, alignment: 8)
        defer { mem.deallocate() }
        let actions = mem.assumingMemoryBound(to: posix_spawn_file_actions_t?.self)
        posix_spawn_file_actions_init(actions)
        posix_spawn_file_actions_addclose(actions, 2)
        posix_spawn_file_actions_adddup2(actions, stdoutFD, 1)
        posix_spawn_file_actions_adddup2(actions, stdinFD, 0)

        var pid: pid_t = 0
        let cArgs = args.map { strdup($0) }
        defer { cArgs.forEach { if let p = $0 { free(p) } } }
        var argv = cArgs + [nil]
        let argc = argv.count

        let ret = qemuPath.withCString { pathPtr -> Int32 in
            withUnsafeMutablePointer(to: &pid) { pidPtr -> Int32 in
                withUnsafeMutablePointer(to: &argv) { argvPtr -> Int32 in
                    argvPtr.withMemoryRebound(
                        to: UnsafeMutablePointer<CChar>?.self,
                        capacity: argc
                    ) { basePtr in
                        posix_spawn(pidPtr, pathPtr, actions, nil, basePtr, environ)
                    }
                }
            }
        }

        guard ret == 0 else { throw VMError.spawnFailed }
        return pid
    }

    func stop() async {
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        guard let p = p else { return }
        kill(p.pid, SIGTERM)
        waitpid(p.pid, nil, 0)
        close(p.outPipeOwner)
        close(p.inPipeOwner)
    }

    func forceStop() async {
        lock.lock()
        let p = process
        process = nil
        lock.unlock()
        guard let p = p else { return }
        kill(p.pid, SIGKILL)
        waitpid(p.pid, nil, 0)
        close(p.outPipeOwner)
        close(p.inPipeOwner)
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
            let sub = String(a.dropFirst("Documents/".count))
            let target = docs.appendingPathComponent(sub)
            // 磁盘镜像可能随附在 App bundle Resources（slim 模式下从 bundle 释放到 Documents）
            if !FileManager.default.fileExists(atPath: target.path),
               let inBundle = Bundle.main.url(forResource: sub, withExtension: nil),
               (inBundle.path.hasSuffix(".img") || inBundle.path.hasSuffix(".qcow2")) {
                try? FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                do {
                    if FileManager.default.fileExists(atPath: target.path) {
                        try FileManager.default.removeItem(at: target)
                    }
                    try FileManager.default.copyItem(at: inBundle, to: target)
                    return target.path
                } catch {
                    // 复制失败则回退到 Documents 原路径（可能缺失，QEMU 启动会报 IO 错误）
                }
            }
            return target.path
        }
        if Bundle.main.url(forResource: a, withExtension: nil) != nil {
            return Bundle.main.url(forResource: a, withExtension: nil)!.path
        }
        return a
    }

    /// 创建 pipe，返回 (读端 fd, 写端 fd)。
    private func makePipe() throws -> (Int32, Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw VMError.ioError("pipe() 失败") }
        return (fds[0], fds[1])
    }
}
