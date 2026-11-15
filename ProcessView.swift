import SwiftUI

struct DeviceProcess: Identifiable, Hashable {
    let pid: Int
    let user: String
    let name: String
    /// RSS，单位 KB
    let rss: Int
    var id: Int { pid }
    var rssText: String {
        rss >= 1024 ? String(format: "%.1f MB", Double(rss) / 1024) : "\(rss) KB"
    }
}

/// 进程列表与结束进程（对应甲壳虫的“进程管理”）。
struct ProcessView: View {
    @ObservedObject var adb: ADBClient
    @Environment(\.dismiss) private var dismiss

    @State private var procs: [DeviceProcess] = []
    @State private var query = ""
    @State private var loading = false
    @State private var message = ""
    @State private var killing: DeviceProcess?

    private var shown: [DeviceProcess] {
        let base = query.isEmpty
            ? procs
            : procs.filter { $0.name.localizedCaseInsensitiveContains(query) }
        return base.sorted { $0.rss > $1.rss }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(shown) { p in
                        Button {
                            killing = p
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(p.name).font(.subheadline).foregroundColor(.primary)
                                    Text("PID \(p.pid) · \(p.user)").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(p.rssText).font(.caption).foregroundColor(.secondary)
                            }
                        }
                    }
                } footer: {
                    if !message.isEmpty { Text(message).font(.footnote) }
                }
            }
            .searchable(text: $query, prompt: "进程名")
            .navigationTitle("进程管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                        .disabled(loading)
                }
            }
            .overlay { if loading && procs.isEmpty { ProgressView("读取进程中…") } }
            .alert("结束进程？", isPresented: Binding(
                get: { killing != nil }, set: { if !$0 { killing = nil } }
            ), presenting: killing) { p in
                Button("结束 \(p.name)", role: .destructive) { kill(p) }
                Button("取消", role: .cancel) { killing = nil }
            } message: { p in
                Text("PID \(p.pid)。系统进程通常需要 root 权限才能结束。")
            }
            .task { await reload() }
        }
    }

    private func reload() async {
        loading = true
        let out = await adb.shellText("ps -A")
        procs = Self.parse(out)
        message = procs.isEmpty ? "读取失败（设备可能不支持 ps -A）" : "共 \(procs.count) 个进程"
        loading = false
    }

    private func kill(_ p: DeviceProcess) {
        killing = nil
        Task {
            let out = await adb.shellText("kill -9 \(p.pid) 2>&1; echo done")
            message = out.contains("denied") || out.contains("not permitted")
                ? "结束失败：需要 root 或无权限"
                : "已向 \(p.name)（PID \(p.pid)）发送终止信号"
            await reload()
        }
    }

    /// Android 8+ 的 ps -A 输出：
    /// USER PID PPID VSZ RSS WCHAN ADDR S NAME
    static func parse(_ text: String) -> [DeviceProcess] {
        var list: [DeviceProcess] = []
        for line in text.split(whereSeparator: \.isNewline) {
            let cols = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard cols.count >= 9 else { continue }
            guard let pid = Int(cols[1]) else { continue }
            let rss = Int(cols[4]) ?? 0
            let name = cols[8...].joined(separator: " ")
            list.append(DeviceProcess(pid: pid, user: cols[0], name: name, rss: rss))
        }
        return list
    }
}
