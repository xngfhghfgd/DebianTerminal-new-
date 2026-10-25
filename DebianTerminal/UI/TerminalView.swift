import SwiftUI
import UIKit

/// 终端视图：显示 QEMU 串口输出，支持输入命令、复制/粘贴、滚动、字体调整。
/// POC 阶段优先 Serial Console（QEMU 串口），后续可扩展完整 TTY。
struct TerminalView: View {
    @Binding var log: String
    var input: (String) -> Void

    @State private var command = ""
    @State private var fontSize: CGFloat = 14
    @State private var showFontMenu = false

    var body: some View {
        VStack(spacing: 0) {
            // 输出区
            ScrollViewReader { proxy in
                ScrollView {
                    Text(log.isEmpty ? "等待 QEMU 输出…" : log)
                        .font(.system(.body, design: .monospaced))
                        .font(.system(size: fontSize, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                        .id("end")
                }
                .onChange(of: log) { _ in proxy.scrollTo("end", anchor: .bottom) }
                .background(Color.black)
            }
            // 工具条
            HStack {
                TextField("命令…", text: $command)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(send)
                Button("↩︎", action: send).buttonStyle(.bordered)
                Menu {
                    Button("放大") { fontSize = min(fontSize + 2, 32) }
                    Button("缩小") { fontSize = max(fontSize - 2, 8) }
                    Button("复制") { UIPasteboard.general.string = log }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
            }
            .padding(8)
        }
    }

    private func send() {
        let cmd = command
        guard !cmd.isEmpty else { return }
        input(cmd + "\n")
        command = ""
    }
}
