import SwiftUI

private let panelBG = Color(red: 0.07, green: 0.08, blue: 0.10)

struct ToolsView: View {
    @ObservedObject var adb: ADBClient
    @State private var picking = false

    // 显示 / 动画 / 墓碑
    @State private var display = DisplaySettings()
    @State private var anims = AnimationSettings()
    @State private var freezer = ""
    @State private var editResolution = false
    @State private var resolutionInput = ""
    @State private var editDensity = false
    @State private var densityInput = ""
    @State private var editAnim: AnimKey?
    @State private var animInput = ""

    // 屏幕录制
    @State private var recordSeconds = 15
    @State private var recording = false
    @State private var recordURL: URL?

    // 高级重启
    @State private var pendingReboot: SystemRebootMode?

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                deviceInfoCard
                screenCard
                displayCard
                animationCard
                systemCard
                screenshotCard
            }
            .padding(.vertical, 4)
        }
        .task(id: adb.connected) { if adb.connected { await reload() } }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first {
                Task { await adb.installAPK(u) }
            }
        }
    }

    // MARK: - 设备信息

    private var deviceInfoCard: some View {
        Group {
            if !adb.deviceInfo.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(adb.deviceInfo.enumerated()), id: \.offset) { _, item in
                        HStack(alignment: .top) {
                            Text(item.0).foregroundColor(.secondary).frame(width: 72, alignment: .leading)
                            Text(item.1).frame(maxWidth: .infinity, alignment: .leading)
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
        }
    }

    // MARK: - 屏幕（截图 / 熄屏点亮 / 录制）

    private var screenCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("屏幕", icon: "display")
            HStack(spacing: 10) {
                smallButton("截图", "camera.viewfinder") { Task { await adb.takeScreenshot() } }
                smallButton("熄屏", "moon") { Task { await adb.screenPower(false) } }
                smallButton("点亮", "sun.max") { Task { await adb.screenPower(true) } }
                smallButton("安装 APK", "square.and.arrow.down") { picking = true }
            }
            Divider()
            HStack {
                Text("录制时长").font(.subheadline)
                Picker("", selection: $recordSeconds) {
                    ForEach([10, 15, 30, 60], id: \.self) { Text("\($0)s").tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 200)
            }
            Button {
                Task { await record() }
            } label: {
                Label(recording ? "正在录制…" : "开始屏幕录制", systemImage: "record.circle")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(recording ? .red : .blue)
            .disabled(!adb.connected || recording)
            if let u = recordURL {
                ShareLink(item: u) {
                    Label("保存 / 分享录屏", systemImage: "square.and.arrow.up")
                }
            }
        }
        .card
    }

    // MARK: - 显示（分辨率 / DPI）

    private var displayCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("显示", icon: "rectangle.on.rectangle.angled")
            infoRow("当前分辨率", display.sizeOverride.isEmpty ? display.size : "\(display.sizeOverride)（覆盖）")
            HStack(spacing: 8) {
                Button("修改分辨率") {
                    resolutionInput = display.sizeOverride.isEmpty ? display.size : display.sizeOverride
                    editResolution = true
                }
                .buttonStyle(.bordered)
                Button("恢复默认") {
                    Task { adb.toolStatus = await adb.setResolution("reset"); await reload() }
                }
                .buttonStyle(.bordered)
            }
            .disabled(!adb.connected)

            Divider()
            infoRow("当前 DPI", display.densityOverride.isEmpty ? display.density : "\(display.densityOverride)（覆盖）")
            HStack(spacing: 8) {
                Button("修改 DPI") {
                    densityInput = display.densityOverride.isEmpty ? display.density : display.densityOverride
                    editDensity = true
                }
                .buttonStyle(.bordered)
                Button("恢复默认") {
                    Task { adb.toolStatus = await adb.setDensity("reset"); await reload() }
                }
                .buttonStyle(.bordered)
            }
            .disabled(!adb.connected)
        }
        .card
        .alert("修改分辨率", isPresented: $editResolution) {
            TextField("例如 1080x1920 或 reset", text: $resolutionInput)
            Button("应用") {
                Task { adb.toolStatus = await adb.setResolution(resolutionInput); await reload() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前物理分辨率：\(display.size)")
        }
        .alert("修改 DPI", isPresented: $editDensity) {
            TextField("例如 320 或 reset", text: $densityInput)
                .keyboardType(.numbersAndPunctuation)
            Button("应用") {
                Task { adb.toolStatus = await adb.setDensity(densityInput); await reload() }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text("当前物理 DPI：\(display.density)")
        }
    }

    // MARK: - 动画速度

    private var animationCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("动画速度", icon: "waveform.path.ecg")
            animRow("窗口动画", value: anims.window) { animInput = anims.window.isEmpty ? "1" : anims.window; editAnim = .window }
            HStack(spacing: 6) {
                animPreset("0×", "0", .window)
                animPreset("0.5×", "0.5", .window)
                animPreset("1×", "1", .window)
                animPreset("1.5×", "1.5", .window)
                animPreset("2×", "2", .window)
            }
            Divider()
            animRow("切换动画", value: anims.transition) { animInput = anims.transition.isEmpty ? "1" : anims.transition; editAnim = .transition }
            HStack(spacing: 6) {
                animPreset("0×", "0", .transition)
                animPreset("0.5×", "0.5", .transition)
                animPreset("1×", "1", .transition)
                animPreset("2×", "2", .transition)
            }
            Divider()
            animRow("动画时长", value: anims.animator) { animInput = anims.animator.isEmpty ? "1" : anims.animator; editAnim = .animator }
            HStack(spacing: 6) {
                animPreset("0×", "0", .animator)
                animPreset("0.5×", "0.5", .animator)
                animPreset("1×", "1", .animator)
                animPreset("2×", "2", .animator)
            }
        }
        .card
        .alert("自定义动画倍率", isPresented: Binding(
            get: { editAnim != nil }, set: { if !$0 { editAnim = nil } }
        )) {
            TextField("例如 0.7", text: $animInput)
                .keyboardType(.numbersAndPunctuation)
            Button("应用") {
                if let key = editAnim, !animInput.isEmpty {
                    Task { adb.toolStatus = await adb.setAnimation(key, value: animInput); await reload() }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 系统（墓碑 / 高级重启）

    private var systemCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("系统", icon: "gearshape.2")
            Toggle("墓碑模式（冻结后台应用）", isOn: Binding(
                get: { freezer == "enabled" },
                set: { on in
                    Task { adb.toolStatus = await adb.setFreezer(on); await reload() }
                }
            ))
            .disabled(!adb.connected)
            Text("开启后后台应用会被冻结，可延长续航；当前值：\(freezer.isEmpty ? "未知" : freezer)")
                .font(.caption)
                .foregroundColor(.secondary)

            Divider()
            Text("高级重启").font(.subheadline)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(SystemRebootMode.allCases) { m in
                    Button { pendingReboot = m } label: {
                        Text(m.rawValue).frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .card
        .confirmationDialog("确认重启到该模式？设备将断开连接。", isPresented: Binding(
            get: { pendingReboot != nil }, set: { if !$0 { pendingReboot = nil } }
        ), titleVisibility: .visible) {
            if let m = pendingReboot {
                Button(m.rawValue, role: .destructive) {
                    Task { adb.toolStatus = await adb.reboot(m) }
                }
            }
            Button("取消", role: .cancel) {}
        }
    }

    // MARK: - 截图预览

    private var screenshotCard: some View {
        Group {
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
                    Label("保存 / 分享截图", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    // MARK: - 辅助视图

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.headline)
    }

    private func infoRow(_ key: String, _ value: String) -> some View {
        HStack(alignment: .top) {
            Text(key).foregroundColor(.secondary).frame(width: 76, alignment: .leading)
            Text(value.isEmpty ? "—" : value)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
        }
        .font(.subheadline)
    }

    private func smallButton(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 5) {
                Image(systemName: icon).font(.title3)
                Text(title).font(.caption)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(10)
        }
        .disabled(!adb.connected)
    }

    private func animRow(_ label: String, value: String, custom: @escaping () -> Void) -> some View {
        HStack {
            Text(label).font(.subheadline)
            Text(value.isEmpty ? "—" : value + "×")
                .font(.caption.monospacedDigit())
                .foregroundColor(.secondary)
            Spacer()
            Button("自定义", action: custom)
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(!adb.connected)
        }
    }

    private func animPreset(_ title: String, _ value: String, _ key: AnimKey) -> some View {
        Button {
            Task { adb.toolStatus = await adb.setAnimation(key, value: value); await reload() }
        } label: {
            Text(title).font(.caption).frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!adb.connected)
    }

    // MARK: - 动作

    private func reload() async {
        guard adb.connected else { return }
        display = await adb.readDisplay()
        anims = await adb.readAnimations()
        freezer = await adb.readFreezer()
    }

    private func record() async {
        guard adb.connected else { return }
        recording = true
        recordURL = nil
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("ADBTerm-录屏-\(Int(Date().timeIntervalSince1970)).mp4")
        let ok = await adb.recordScreen(seconds: recordSeconds, to: url) { n in
            adb.toolStatus = "导出中 \(n / 1024) KB"
        }
        recording = false
        if ok {
            recordURL = url
            adb.toolStatus = "录屏完成"
        } else {
            adb.toolStatus = "录屏失败（设备可能不支持 screenrecord）"
        }
    }
}

// MARK: - 视图修饰

private extension View {
    var card: some View {
        self
            .padding(12)
            .background(Color(.secondarySystemGroupedBackground))
            .cornerRadius(12)
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
