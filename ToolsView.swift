import SwiftUI

private let panelBG = Color(red: 0.07, green: 0.08, blue: 0.10)

private enum ToolsSheet: String, Identifiable {
    case screen, process, settings
    var id: String { rawValue }
}

struct ToolsView: View {
    @ObservedObject var adb: ADBClient
    @State private var picking = false
    @State private var sheet: ToolsSheet?
    @State private var rebootMessage = ""

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                if !adb.deviceInfo.isEmpty {
                    VStack(spacing: 0) {
                        ForEach(Array(adb.deviceInfo.enumerated()), id: \.offset) { _, item in
                            HStack(alignment: .top) {
                                Text(item.0)
                                    .foregroundColor(.secondary)
                                    .frame(width: 72, alignment: .leading)
                                Text(item.1)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .font(.subheadline)
                            .padding(.vertical, 6)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                }
                HStack(spacing: 12) {
                    toolButton("截图", "camera.viewfinder") { Task { await adb.takeScreenshot() } }
                    toolButton("安装 APK", "square.and.arrow.down") { picking = true }
                }
                HStack(spacing: 12) {
                    toolButton("屏幕参数", "rectangle.on.rectangle") { sheet = .screen }
                    toolButton("进程管理", "list.bullet.rectangle") { sheet = .process }
                    toolButton("设置", "gearshape") { sheet = .settings }
                }
                Menu {
                    Button("重启设备") { reboot("reboot") }
                    Button("重启到 Recovery") { reboot("reboot recovery") }
                    Button("重启到 Bootloader") { reboot("reboot bootloader") }
                    Button("关机") { reboot("reboot -p") }
                } label: {
                    HStack {
                        Image(systemName: "power")
                        Text("重启 / 关机")
                        Spacer()
                        Image(systemName: "chevron.down").font(.caption)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(12)
                }
                .disabled(!adb.connected)
                if !adb.toolStatus.isEmpty {
                    Text(adb.toolStatus)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                if let img = adb.screenshot {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .cornerRadius(12)
                        .frame(maxHeight: 520)
                    ShareLink(item: Image(uiImage: img),
                              preview: SharePreview("截图", image: Image(uiImage: img))) {
                        Label("保存 / 分享", systemImage: "square.and.arrow.up")
                    }
                }
            }
            .padding(.top, 4)
        }
        .task(id: adb.connected) { await adb.refreshInfo() }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first {
                Task { await adb.installAPK(u) }
            }
        }
        .sheet(item: $sheet) { which in
            switch which {
            case .screen: ScreenToolsView(adb: adb)
            case .process: ProcessView(adb: adb)
            case .settings: SettingsView(adb: adb)
            }
        }
    }

    private func reboot(_ cmd: String) {
        Task {
            adb.toolStatus = "执行：\(cmd)"
            _ = await adb.shellText(cmd)
            adb.toolStatus = "已发送 \(cmd)；设备会断开"
        }
    }

    private func toolButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.title2)
                Text(title).font(.subheadline)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
        .disabled(!adb.connected)
    }
}

struct LogView: View {
    @ObservedObject var adb: ADBClient

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button(adb.logRunning ? "停止" : "开始") {
                    if adb.logRunning { adb.stopLog() } else { Task { await adb.startLog() } }
                }
                .buttonStyle(.borderedProminent)
                .tint(adb.logRunning ? .red : .green)
                .disabled(!adb.connected)
                Button("清空") { adb.logOutput = "" }
                    .buttonStyle(.bordered)
                Spacer()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    Text(adb.logOutput.isEmpty ? "点“开始”查看 logcat…" : adb.logOutput)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundColor(adb.logOutput.isEmpty ? Color(white: 0.45) : Color(white: 0.9))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                        .padding(12)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .background(panelBG)
                .cornerRadius(12)
                .onChange(of: adb.logOutput) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }
        }
    }
}
