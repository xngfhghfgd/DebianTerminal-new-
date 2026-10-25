import SwiftUI
import Combine

/// 设置页：CPU 核数 / 内存 / 磁盘位置 / 内核位置 / 启动参数 / 网络 / JIT。
struct SettingsView: View {
    @EnvironmentObject var appState: AppState
    @State private var cfg = VMConfig()
    @State private var jit = JITStatus.unknown

    var body: some View {
        Form {
            Section("CPU") {
                Picker("核数", selection: $cfg.cpuCores) {
                    ForEach(cfg.allowedCpuOptions, id: \.self) { Text("\($0)") }
                }
            }
            Section("内存") {
                Picker("Guest 内存", selection: $cfg.guestMemoryMB) {
                    ForEach(cfg.allowedMemoryOptions, id: \.self) { Text("\($0) MB") }
                }
            }
            Section("磁盘 / 内核") {
                LabeledContent("磁盘镜像", value: cfg.diskPath)
                LabeledContent("内核", value: cfg.kernelPath)
                LabeledContent("QEMU", value: cfg.qemuBinary)
            }
            Section("启动参数") {
                TextField("append", text: $cfg.append)
                Toggle("网络 (user)", isOn: .constant(true))
                    .disabled(true)
                Toggle("允许 JIT（需检测通过）", isOn: $cfg.allowJIT)
                LabeledContent("JIT 状态", value: jit.rawValue)
            }
            Section {
                Button("保存设置") {
                    cfg.save()
                    appState.settings = cfg
                    appState.detectJIT()
                    jit = appState.jitStatus
                }
            }
        }
        .navigationTitle("Settings")
        .onAppear {
            cfg = appState.settings
            jit = appState.jitStatus
        }
    }
}
