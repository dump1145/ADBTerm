import SwiftUI

/// 屏幕参数与显示控制：DPI、分辨率、旋转、熄屏/唤醒、保持唤醒。
struct ScreenToolsView: View {
    @ObservedObject var adb: ADBClient
    @Environment(\.dismiss) private var dismiss

    @State private var dpi = ""
    @State private var size = ""
    @State private var originalSize = "未知"
    @State private var currentDpi = "未知"
    @State private var message = ""
    @State private var stayOn = false
    @State private var busy = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("原始分辨率", value: originalSize)
                    LabeledContent("当前像素密度", value: currentDpi)
                } footer: {
                    Text("读取自 wm size / wm density，含 Override 值。")
                }

                Section("修改分辨率") {
                    TextField("例如 1080x2400", text: $size)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    HStack {
                        Button("应用") { applySize() }
                            .disabled(busy || !validSize(size))
                        Button("恢复原始", role: .destructive) {
                            run("wm size reset", done: "已恢复原始分辨率")
                        }
                        .disabled(busy)
                    }
                }

                Section("修改屏幕密度") {
                    TextField("例如 420", text: $dpi)
                        .keyboardType(.numberPad)
                    HStack {
                        Button("应用") {
                            let v = dpi.trimmingCharacters(in: .whitespaces)
                            guard let n = Int(v), n >= 72, n <= 900 else {
                                message = "DPI 需在 72~900 之间"
                                return
                            }
                            run("wm density \(n)", done: "已设置为 \(n) dpi")
                        }
                        .disabled(busy || dpi.isEmpty)
                        Button("恢复原始", role: .destructive) {
                            run("wm density reset", done: "已恢复原始密度")
                        }
                        .disabled(busy)
                    }
                }

                Section("显示控制") {
                    Button("屏幕旋转 0°") { rotate(0) }
                    Button("屏幕旋转 90°") { rotate(1) }
                    Button("屏幕旋转 180°") { rotate(2) }
                    Button("屏幕旋转 270°") { rotate(3) }
                    Button("恢复自动旋转") {
                        run("settings put system accelerometer_rotation 1", done: "已恢复自动旋转")
                    }
                    Toggle("保持设备唤醒", isOn: $stayOn)
                        .onChange(of: stayOn) { on in
                            run("svc power stayon \(on ? "true" : "false")",
                                done: on ? "已开启保持唤醒" : "已关闭保持唤醒")
                        }
                    Button("熄屏") { run("input keyevent 223", done: "已熄屏") }
                    Button("唤醒屏幕") { run("input keyevent 224", done: "已唤醒") }
                }

                if !message.isEmpty {
                    Section {
                        Text(message).font(.footnote).foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("屏幕")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
            .task { await refresh() }
        }
    }

    private func validSize(_ s: String) -> Bool {
        let parts = s.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Int(parts[0]), let h = Int(parts[1]) else { return false }
        return w >= 320 && w <= 4320 && h >= 320 && h <= 4320
    }

    private func applySize() {
        let s = size.trimmingCharacters(in: .whitespaces)
        guard validSize(s) else { message = "格式应为 1080x2400"; return }
        run("wm size \(s)", done: "已设置为 \(s)")
    }

    private func rotate(_ r: Int) {
        run("settings put system accelerometer_rotation 0; settings put system user_rotation \(r)",
            done: "已旋转到 \(r * 90)°")
    }

    private func run(_ cmd: String, done: String) {
        busy = true
        Task {
            _ = await adb.shellText(cmd)
            message = done
            busy = false
            await refresh()
        }
    }

    private func refresh() async {
        let out = await adb.shellText("wm size; wm density; svc power stayon")
        let lines = out.split(whereSeparator: \.isNewline).map(String.init)
        var physical = "", override = "", density: [String] = []
        for l in lines {
            if l.contains("Physical size") { physical = l.replacingOccurrences(of: "Physical size:", with: "").trimmingCharacters(in: .whitespaces) }
            if l.contains("Override size") { override = l.replacingOccurrences(of: "Override size:", with: "").trimmingCharacters(in: .whitespaces) }
            if l.contains("density") { density.append(l.trimmingCharacters(in: .whitespaces)) }
        }
        originalSize = override.isEmpty ? physical : "\(override)（原始 \(physical)）"
        currentDpi = density.joined(separator: " / ")
        stayOn = out.lowercased().contains("stayon=true")
    }
}
