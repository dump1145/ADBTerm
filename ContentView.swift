import SwiftUI

private let termBG = Color(red: 0.07, green: 0.08, blue: 0.10)
private let termFG = Color(white: 0.90)

struct QuickGroup: Identifiable {
    let id = UUID()
    let title: String
    let icon: String
    let items: [(String, String)]
}

private let quickGroups: [QuickGroup] = [
    QuickGroup(title: "设备信息", icon: "info.circle", items: [
        ("型号", "getprop ro.product.model"),
        ("安卓版本", "getprop ro.build.version.release"),
        ("电池", "dumpsys battery"),
        ("内存", "head -n 5 /proc/meminfo"),
        ("屏幕分辨率", "wm size"),
        ("屏幕密度", "wm density")
    ]),
    QuickGroup(title: "应用", icon: "square.grid.2x2", items: [
        ("第三方应用", "pm list packages -3"),
        ("全部应用", "pm list packages"),
        ("前台窗口", "dumpsys window | grep mCurrentFocus")
    ]),
    QuickGroup(title: "按键", icon: "hand.tap", items: [
        ("返回", "input keyevent 4"),
        ("主页", "input keyevent 3"),
        ("多任务", "input keyevent 187"),
        ("电源键", "input keyevent 26"),
        ("音量+", "input keyevent 24"),
        ("音量-", "input keyevent 25")
    ]),
    QuickGroup(title: "文件", icon: "folder", items: [
        ("列出 /sdcard", "ls -la /sdcard"),
        ("截图到 /sdcard/s.png", "screencap -p /sdcard/s.png"),
        ("磁盘用量", "df -h")
    ])
]

struct ContentView: View {
    @StateObject private var adb = ADBClient()
    @StateObject private var store = DeviceStore()
    @StateObject private var mirror = MirrorClient()
    @StateObject private var commands = CommandStore()
    @State private var editing: Device?
    @State private var input = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @State private var tab = 0

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            terminal
        }
        .sheet(item: $editing) { dev in
            DeviceEditor(device: dev) { store.save($0) }
        }
        .onChange(of: store.selectedID) { _ in
            mirror.stop()
            adb.disconnect()
        }
        .onChange(of: adb.connected) { c in
            if !c { mirror.stop() }
        }
    }

    // MARK: - 侧边栏

    private var sidebar: some View {
        List(selection: $store.selectedID) {
            Section("设备") {
                ForEach(store.devices) { d in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(d.title).font(.headline)
                        Text("\(d.host):\(d.port)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.vertical, 2)
                    .tag(d.id)
                    .swipeActions {
                        Button(role: .destructive) { store.delete(d) } label: {
                            Label("删除", systemImage: "trash")
                        }
                        Button { editing = d } label: {
                            Label("编辑", systemImage: "pencil")
                        }
                        .tint(.orange)
                    }
                }
            }
        }
        .overlay {
            if store.devices.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "iphone.and.arrow.forward")
                        .font(.largeTitle)
                    Text("点右上角 + 添加设备")
                        .font(.subheadline)
                }
                .foregroundColor(.secondary)
            }
        }
        .navigationTitle("ADBTerm")
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button { editing = Device() } label: { Image(systemName: "plus") }
            }
        }
    }

    // MARK: - 终端

    private var statusColor: Color {
        if adb.connected { return .green }
        if adb.status.hasPrefix("连接中") || adb.status.hasPrefix("请在手机") { return .orange }
        if adb.status.hasPrefix("失败") || adb.status.contains("断开") { return .red }
        return .gray
    }

    private var terminal: some View {
        VStack(spacing: 10) {
            statusBar
            Picker("", selection: $tab) {
                Text("终端").tag(0)
                Text("Logcat").tag(1)
                Text("工具").tag(2)
                Text("应用").tag(3)
                Text("文件").tag(4)
                Text("镜像").tag(5)
                Text("命令").tag(6)
            }
            .pickerStyle(.segmented)
            switch tab {
            case 1:
                LogView(adb: adb)
            case 2:
                ToolsView(adb: adb)
            case 3:
                AppsView(adb: adb)
            case 4:
                FilesView(adb: adb)
            case 5:
                MirrorView(adb: adb, mirror: mirror)
            case 6:
                CommandsView(adb: adb, store: commands)
            default:
                outputView
                quickBar
                inputBar
            }
        }
        .padding(12)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(store.selected?.title ?? "未选择设备")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var statusBar: some View {
        HStack(spacing: 10) {
            Circle().fill(statusColor).frame(width: 10, height: 10)
            Text(adb.status)
                .font(.subheadline)
                .lineLimit(2)
            Spacer()
            Button {
                if adb.connected {
                    adb.disconnect()
                } else if let d = store.selected {
                    adb.connect(host: d.host.trimmingCharacters(in: .whitespaces), port: d.port)
                }
            } label: {
                Text(adb.connected ? "断开" : "连接")
                    .frame(minWidth: 56)
            }
            .buttonStyle(.borderedProminent)
            .tint(adb.connected ? .red : .blue)
            .disabled(store.selected == nil)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private var outputView: some View {
        ScrollViewReader { proxy in
            ScrollView {
                Text(adb.output.isEmpty ? "连接后在这里显示 shell 输出…" : adb.output)
                    .font(.system(size: 14, design: .monospaced))
                    .foregroundColor(adb.output.isEmpty ? Color(white: 0.45) : termFG)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                    .padding(12)
                Color.clear.frame(height: 1).id("bottom")
            }
            .background(termBG)
            .cornerRadius(12)
            .overlay(alignment: .topTrailing) {
                Button { adb.clearOutput() } label: {
                    Image(systemName: "trash")
                        .padding(8)
                        .foregroundColor(Color(white: 0.7))
                }
            }
            .onChange(of: adb.output) { _ in
                proxy.scrollTo("bottom", anchor: .bottom)
            }
        }
    }

    private var quickBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(quickGroups) { g in
                    Menu {
                        ForEach(g.items, id: \.1) { item in
                            Button(item.0) { run(item.1) }
                        }
                    } label: {
                        Label(g.title, systemImage: g.icon)
                            .font(.subheadline)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(10)
                    }
                }
            }
        }
    }

    private var inputBar: some View {
        HStack(spacing: 8) {
            Text("$")
                .font(.system(size: 16, weight: .bold, design: .monospaced))
                .foregroundColor(.green)
            TextField("输入 shell 命令", text: $input)
                .font(.system(size: 16, design: .monospaced))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .onSubmit { run(input) }
            Button { stepHistory(-1) } label: { Image(systemName: "chevron.up") }
                .disabled(history.isEmpty)
            Button { stepHistory(1) } label: { Image(systemName: "chevron.down") }
                .disabled(historyIndex == nil)
            Button { run(input) } label: {
                Image(systemName: "paperplane.fill")
                    .padding(8)
                    .background(adb.connected ? Color.blue : Color.gray)
                    .foregroundColor(.white)
                    .clipShape(Circle())
            }
            .disabled(!adb.connected)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: - 动作

    private func run(_ cmd: String) {
        let c = cmd.trimmingCharacters(in: .whitespaces)
        guard !c.isEmpty, adb.connected else { return }
        adb.sendLine(c)
        if history.last != c { history.append(c) }
        historyIndex = nil
        input = ""
    }

    private func stepHistory(_ delta: Int) {
        guard !history.isEmpty else { return }
        var i = historyIndex ?? history.count
        i += delta
        if i >= history.count {
            historyIndex = nil
            input = ""
        } else {
            i = max(0, i)
            historyIndex = i
            input = history[i]
        }
    }
}

struct DeviceEditor: View {
    @Environment(\.dismiss) private var dismiss
    @State var device: Device
    let onSave: (Device) -> Void

    init(device: Device, onSave: @escaping (Device) -> Void) {
        _device = State(initialValue: device)
        self.onSave = onSave
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("名称（可选）") {
                    TextField("例如：我的手机", text: $device.name)
                }
                Section("地址") {
                    TextField("IP，例如 192.168.1.20", text: $device.host)
                        .keyboardType(.numbersAndPunctuation)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    TextField("端口", text: $device.port)
                        .keyboardType(.numberPad)
                }
            }
            .navigationTitle("设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        onSave(device)
                        dismiss()
                    }
                    .disabled(device.host.trimmingCharacters(in: .whitespaces).isEmpty
                              || UInt16(device.port) == nil)
                }
            }
        }
    }
}
