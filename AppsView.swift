import SwiftUI

private enum AppAction: String {
    case launch = "启动", stop = "强行停止", clear = "清除数据"
    case toggle = "禁用 / 启用", uninstall = "卸载", export = "导出 APK"
    case permissions = "权限管理"
}

struct AppsView: View {
    @ObservedObject var adb: ADBClient
    @State private var apps: [AppInfo] = []
    @State private var query = ""
    @State private var filter = 0
    @State private var loading = false
    @State private var message = ""
    @State private var selected: AppInfo?
    @State private var pending: (AppInfo, AppAction)?
    @State private var showConfirm = false
    @State private var shareURL: URL?
    @State private var permTarget: AppInfo?

    private var shown: [AppInfo] {
        apps.filter { a in
            (filter == 2 || a.system == (filter == 1))
                && (query.isEmpty || a.pkg.localizedCaseInsensitiveContains(query))
        }
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Picker("", selection: $filter) {
                    Text("用户").tag(0)
                    Text("系统").tag(1)
                    Text("全部").tag(2)
                }
                .pickerStyle(.segmented)
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                    .disabled(!adb.connected || loading)
            }
            TextField("搜索包名", text: $query)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let u = shareURL {
                ShareLink(item: u) {
                    Label("保存 / 分享 \(u.lastPathComponent)", systemImage: "square.and.arrow.up")
                }
            }
            List(shown) { a in
                Button { selected = a } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(a.pkg).font(.subheadline).foregroundColor(.primary)
                            if a.disabled {
                                Text("已禁用").font(.caption).foregroundColor(.orange)
                            }
                        }
                        Spacer()
                        Image(systemName: "ellipsis.circle").foregroundColor(.secondary)
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if loading { ProgressView() }
            }
        }
        .task(id: adb.connected) { if adb.connected { await reload() } }
        .confirmationDialog(selected?.pkg ?? "", isPresented: Binding(
            get: { selected != nil }, set: { if !$0 { selected = nil } }
        ), titleVisibility: .visible, presenting: selected) { a in
            Button("启动") { perform(a, .launch) }
            Button("强行停止") { perform(a, .stop) }
            Button(a.disabled ? "启用" : "禁用") { ask(a, .toggle) }
            Button("清除数据", role: .destructive) { ask(a, .clear) }
            Button(a.system ? "卸载（仅当前用户）" : "卸载", role: .destructive) { ask(a, .uninstall) }
            Button("导出 APK") { perform(a, .export) }
            Button("权限管理") { permTarget = a }
            Button("取消", role: .cancel) {}
        }
        .sheet(item: $permTarget) { a in
            PermissionsView(adb: adb, pkg: a.pkg)
        }
        .alert("确认\(pending?.1.rawValue ?? "")？", isPresented: $showConfirm) {
            Button("确认", role: .destructive) {
                if let p = pending { perform(p.0, p.1) }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(pending?.0.pkg ?? "")
        }
    }

    private func ask(_ a: AppInfo, _ act: AppAction) {
        pending = (a, act)
        showConfirm = true
    }

    private func reload() async {
        guard adb.connected else { return }
        loading = true
        apps = await adb.loadApps()
        loading = false
    }

    private func perform(_ a: AppInfo, _ act: AppAction) {
        Task {
            message = "执行中…"
            let pkg = shq(a.pkg)
            switch act {
            case .launch:
                _ = await adb.shellText("monkey -p \(pkg) -c android.intent.category.LAUNCHER 1")
                message = "已发送启动指令"
            case .stop:
                _ = await adb.shellText("am force-stop \(pkg)")
                message = "已强行停止 \(a.pkg)"
            case .clear:
                message = "清除数据：" + (await adb.shellText("pm clear \(pkg)"))
            case .toggle:
                let cmd = a.disabled ? "pm enable \(pkg)" : "pm disable-user --user 0 \(pkg)"
                message = await adb.shellText(cmd)
                await reload()
            case .uninstall:
                let cmd = a.system ? "pm uninstall --user 0 \(pkg)" : "pm uninstall \(pkg)"
                message = "卸载：" + (await adb.shellText(cmd))
                await reload()
            case .export:
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(a.pkg).apk")
                let ok = await adb.pull(a.apkPath, to: url) { n in
                    message = "导出中 \(n / 1024) KB"
                }
                if ok {
                    shareURL = url
                    message = "已导出 \(a.pkg).apk"
                } else {
                    message = "导出失败"
                }
            case .permissions:
                permTarget = a
            }
        }
    }
}
