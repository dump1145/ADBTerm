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
    ]),
    QuickGroup(title: "系统", icon: "gearshape", items: [
        ("重启设备", "reboot"),
        ("重启到 Fastboot", "reboot bootloader"),
        ("重启到 Recovery", "reboot recovery"),
        ("关机", "reboot -p"),
        ("运行时长", "uptime"),
        ("进程列表", "ps -A | head -n 20")
    ]),
    QuickGroup(title: "网络", icon: "wifi", items: [
        ("IP 地址", "ip addr show wlan0 | grep inet"),
        ("无线调试端口", "getprop service.adb.tcp.port"),
        ("Wi-Fi 状态", "dumpsys wifi | grep -m1 mNetworkInfo"),
        ("当前前台 App", "dumpsys activity activities | grep mResumedActivity")
    ])
]

private enum HomeSheet: String, Identifiable {
    case screen, process, settings
    var id: String { rawValue }
}

struct ContentView: View {
    @StateObject private var adb = ADBClient()
    @StateObject private var store = DeviceStore()
    @StateObject private var mirror = MirrorClient()
    @State private var editing: Device?
    @State private var input = ""
    @State private var history: [String] = []
    @State private var historyIndex: Int?
    @State private var tab = -1
    @State private var sheet: HomeSheet?

    var body: some View {
        NavigationSplitView {
            sidebar
        } detail: {
            mainArea
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

    private var mainArea: some View {
        VStack(spacing: 10) {
            statusBar
            if tab < 0 {
                dashboard
            } else {
                HStack(spacing: 8) {
                    Button { tab = -1 } label: {
                        Label("返回", systemImage: "chevron.left").font(.subheadline)
                    }
                    Text(sectionTitle).font(.headline).lineLimit(1)
                    Spacer()
                }
                sectionContent
            }
        }
        .padding(12)
        .background(Color(.systemGroupedBackground))
        .navigationTitle(store.selected?.title ?? "未选择设备")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $sheet) { which in
            switch which {
            case .screen: ScreenToolsView(adb: adb)
            case .process: ProcessView(adb: adb)
            case .settings: SettingsView(adb: adb)
            }
        }
    }

    private var sectionTitle: String {
        switch tab {
        case 0: return "终端"
        case 1: return "Logcat"
        case 2: return "工具"
        case 3: return "应用管理"
        case 4: return "文件管理"
        case 5: return "屏幕镜像"
        default: return ""
        }
    }

    @ViewBuilder
    private var sectionContent: some View {
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
        default:
            outputView
            quickBar
            inputBar
        }
    }

    // MARK: - 首页

    private var dashboard: some View {
        ScrollView {
            VStack(spacing: 12) {
                deviceCard
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                          spacing: 10) {
                    tile("终端", "terminal") { tab = 0 }
                    tile("文件管理", "folder") { tab = 4 }
                    tile("应用管理", "square.grid.2x2") { tab = 3 }
                    tile("屏幕", "rectangle.on.rectangle") { sheet = .screen }
                    tile("进程", "list.bullet.rectangle") { sheet = .process }
                    tile("Logcat", "text.alignleft") { tab = 1 }
                    tile("镜像", "airplayvideo") { tab = 5 }
                    tile("工具", "wrench.and.screwdriver") { tab = 2 }
                    tile("设置", "gearshape") { sheet = .settings }
                }
            }
        }
        .task(id: adb.connected) { if adb.connected { await adb.refreshInfo() } }
    }

    private var deviceCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: "iphone").font(.title2).foregroundColor(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text(store.selected?.title ?? "未选择设备").font(.headline)
                    Text(adb.connected ? "已连接 \(store.selected?.host ?? ""):\(store.selected?.port ?? "")" : "未连接")
                        .font(.caption)
                        .foregroundColor(adb.connected ? .green : .secondary)
                }
                Spacer()
            }
            if adb.deviceInfo.isEmpty {
                Text(adb.connected ? "正在读取设备信息…" : "连接后可查看型号、系统版本、分辨率、电量等")
                    .font(.footnote)
                    .foregroundColor(.secondary)
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)],
                          alignment: .leading, spacing: 8) {
                    ForEach(Array(adb.deviceInfo.prefix(8).enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.0).font(.caption2).foregroundColor(.secondary)
                            Text(item.1).font(.caption).lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    private func tile(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 8) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
        }
        .disabled(!adb.connected && title != "设置")
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

    @StateObject private var discovery = ADBDiscovery()
    @State private var scanning = false

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
                Section {
                    Button {
                        scanning = true
                        discovery.start()
                    } label: {
                        Label("扫描局域网内的设备", systemImage: "antenna.radiowaves.left.and.right")
                    }
                } footer: {
                    Text("只对已开启无线调试的手机有效；扫描走 mDNS，需允许“本地网络”。")
                        .font(.footnote)
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
            .sheet(isPresented: $scanning) {
                DiscoverySheet(discovery: discovery) { found in
                    device.host = found.host
                    device.port = String(found.port)
                    if device.name.isEmpty { device.name = found.name }
                    scanning = false
                }
                .onDisappear { discovery.stop() }
            }
        }
    }
}
