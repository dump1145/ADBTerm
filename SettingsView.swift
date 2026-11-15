import SwiftUI

/// 设置 / 关于 / 无线调试开关（对应甲壳虫的“全局设置”“关于”“反馈和支持”）。
struct SettingsView: View {
    @ObservedObject var adb: ADBClient
    @Environment(\.dismiss) private var dismiss

    @AppStorage("files.showHidden") private var showHidden = false
    @AppStorage("term.clearOnRun") private var clearOnRun = false

    @State private var tcpPort = "未开启"
    @State private var message = ""
    @State private var busy = false

    private var version: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "\(v) (\(b))"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("文件与终端") {
                    Toggle("显示以 . 开头的文件和文件夹", isOn: $showHidden)
                    Toggle("运行命令前清空输出", isOn: $clearOnRun)
                }

                Section {
                    LabeledContent("当前无线调试端口", value: tcpPort)
                    Button {
                        enableWireless()
                    } label: {
                        Label("开启无线调试（5555）", systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(busy || !adb.connected)
                } header: {
                    Text("无线调试")
                } footer: {
                    Text("执行 setprop service.adb.tcp.port 5555 并重启 adbd。多数设备需要 root 或系统权限，失败属正常现象；成功后可用本机 IP:5555 连接。\n\nAndroid 11+ 的“无线调试（配对）”走 TLS，本版暂不支持，请改用 adb tcpip。")
                        .font(.footnote)
                }

                Section("关于") {
                    LabeledContent("版本", value: version)
                    LabeledContent("协议", value: "ADB over TCP（明文 5555）")
                    LabeledContent("投屏内核", value: "scrcpy 4.0（Apache-2.0）")
                }

                Section("反馈") {
                    Button {
                        openMail()
                    } label: {
                        Label("邮件反馈", systemImage: "envelope")
                    }
                    Button {
                        message = "本工程为个人自用版本，无应用内购买或账号体系。"
                    } label: {
                        Label("许可与说明", systemImage: "doc.text")
                    }
                }

                if !message.isEmpty {
                    Section { Text(message).font(.footnote).foregroundColor(.secondary) }
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
            .task { await refresh() }
        }
    }

    private func refresh() async {
        guard adb.connected else { tcpPort = "未连接"; return }
        let out = await adb.shellText("getprop service.adb.tcp.port")
        tcpPort = out.isEmpty ? "未开启" : out
    }

    private func enableWireless() {
        busy = true
        Task {
            _ = await adb.shellText("setprop service.adb.tcp.port 5555; stop adbd; start adbd; echo $?")
            message = "已尝试开启，请用本机 IP:5555 连接；若端口仍为空说明设备无权限。"
            busy = false
            await refresh()
        }
    }

    private func openMail() {
        let subject = "ADBTerm 反馈"
        let body = "版本：\(version)\n问题描述："
        let url = "mailto:?subject=\(subject.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")&body=\(body.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")"
        if let u = URL(string: url) { UIApplication.shared.open(u) }
    }
}
