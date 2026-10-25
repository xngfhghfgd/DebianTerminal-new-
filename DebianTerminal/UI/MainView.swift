import SwiftUI
import Combine

/// 主页面：Debian 12 Terminal
struct MainView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        VStack(spacing: 0) {
            statusHeader
            controlBar
            if appState.vmState == .running || appState.vmState == .starting {
                TerminalView(log: $appState.terminalLog, input: { appState.manager_write?.write($0.data(using: .utf8) ?? Data()) })
            } else {
                idleView
            }
        }
        .navigationTitle("Debian 12 Terminal")
        .onAppear {
            appState.refreshSettings()
            appState.detectJIT()
        }
    }

    private var statusHeader: some View {
        HStack {
            Label(appState.vmState.displayName,
                  systemImage: appState.vmState == .running ? "power.circle.fill" : "circle")
                .font(.headline)
            Spacer()
            Text("JIT: \(appState.jitStatus.rawValue)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal)
    }

    private var controlBar: some View {
        HStack {
            Button("Start") { appState.start() }
                .disabled(appState.vmState != .stopped && appState.vmState != .crashed)
            Button("Stop") { appState.stop() }
                .disabled(appState.vmState == .stopped || appState.vmState == .stopping)
            Button("Restart") { appState.restart() }
                .disabled(appState.vmState == .stopped)
            Spacer()
            NavigationLink("Settings") { SettingsView() }
            Menu("Disk") {
                Button("Import Disk") { /* TODO: fileImporter */ }
                Button("Export Disk") { /* TODO: fileExporter */ }
            }
        }
        .buttonStyle(.borderedProminent)
        .padding()
    }

    private var idleView: some View {
        VStack(spacing: 12) {
            if !appState.statusMessage.isEmpty {
                Text(appState.statusMessage).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "terminal")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(appState.jitStatus.isAvailable ? "" : "JIT 不可用时将使用解释器模式（较慢）。")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// 把 manager 的写接口暴露给 AppState（简化：通过共享输入 FileHandle）
extension AppState {
    var manager_write: FileHandle? { writeHandle }
}
