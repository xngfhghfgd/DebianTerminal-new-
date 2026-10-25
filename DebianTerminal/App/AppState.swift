import Foundation
import SwiftUI
import Combine

/// 顶层 App 状态：聚合 VM 状态、配置、JIT 状态，驱动 UI。
@MainActor
final class AppState: ObservableObject {
    @Published var vmState: VMState = .stopped
    @Published var jitStatus: JITStatus = .unknown
    @Published var settings = VMConfig()
    @Published var terminalLog: String = ""
    @Published var statusMessage: String = ""
    /// 当前虚拟机标准输入句柄（写命令用）。
    var writeHandle: FileHandle?

    private let manager = VMManager()

    func refreshSettings() {
        settings = VMConfig.load()
    }

    func detectJIT() {
        jitStatus = JITDetector.detect()
    }

    func start() {
        guard vmState == .stopped || vmState == .crashed else { return }
        detectJIT()
        guard jitStatus.isAvailable else {
            statusMessage = "JIT 不可用，无法启动 QEMU。详见 docs/JIT.md。"
            vmState = .crashed
            return
        }
        vmState = .starting
        statusMessage = "正在启动 Debian 虚拟机…"
        terminalLog = ""

        Task { [weak self] in
            do {
                let (outStream, inStream) = try await self!.manager.start(config: self!.settings)
                self!.writeHandle = inStream
                // 读串口输出
                let outTask = Task {
                    for await line in outStream.lines {
                        await MainActor.run {
                            self?.terminalLog += line + "\n"
                        }
                    }
                }
                await outTask.value
                self?.vmState = .stopped
                self?.statusMessage = "虚拟机已停止。"
                _ = inStream
            } catch {
                await MainActor.run {
                    self?.vmState = .crashed
                    self?.statusMessage = "启动失败：\(error.localizedDescription)"
                }
            }
        }
    }

    func stop() {
        vmState = .stopping
        statusMessage = "正在停止…"
        Task {
            await manager.stop()
            await MainActor.run {
                self.vmState = .stopped
                self.statusMessage = "已停止。"
            }
        }
    }

    func restart() {
        stop()
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) { [weak self] in
            self?.start()
        }
    }
}
