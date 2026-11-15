import SwiftUI

struct FilesView: View {
    @ObservedObject var adb: ADBClient
    @State private var path = "/sdcard"
    @State private var entries: [FileEntry] = []
    @State private var loading = false
    @State private var message = ""
    @State private var shareURL: URL?
    @State private var picking = false
    @State private var deleting: FileEntry?
    @State private var renaming: FileEntry?
    @State private var renameText = ""
    @State private var newFolder = false
    @State private var folderName = ""
    @AppStorage("files.showHidden") private var showHidden = false
    @State private var sort = 0

    private var shown: [FileEntry] {
        var list = showHidden ? entries : entries.filter { !$0.name.hasPrefix(".") }
        switch sort {
        case 1: list.sort { $0.size > $1.size }
        case 2: list.sort { $0.mtime > $1.mtime }
        default:
            list.sort {
                if $0.isDir != $1.isDir { return $0.isDir }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
        return list
    }

    private let shortcuts = ["/sdcard", "/sdcard/Download", "/sdcard/DCIM", "/data/local/tmp", "/"]

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Button { up() } label: { Image(systemName: "arrow.up.left") }
                    .disabled(path == "/")
                Text(path)
                    .font(.system(.footnote, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }
                Menu {
                    Picker("排序", selection: $sort) {
                        Text("名称").tag(0)
                        Text("大小").tag(1)
                        Text("时间").tag(2)
                    }
                    Toggle("显示隐藏文件", isOn: $showHidden)
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }
                Button { newFolder = true } label: { Image(systemName: "folder.badge.plus") }
                Button { picking = true } label: { Image(systemName: "square.and.arrow.up") }
            }
            .disabled(!adb.connected)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(shortcuts, id: \.self) { p in
                        Button(p) { path = p; Task { await reload() } }
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                }
            }

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

            List(shown) { e in
                Button { open(e) } label: {
                    HStack(spacing: 10) {
                        Image(systemName: e.isDir ? "folder.fill" : (e.isLink ? "link" : "doc"))
                            .foregroundColor(e.isDir ? .blue : .secondary)
                            .frame(width: 24)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(e.name).foregroundColor(.primary)
                            Text(detail(e)).font(.caption).foregroundColor(.secondary)
                        }
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { deleting = e } label: {
                        Label("删除", systemImage: "trash")
                    }
                    Button {
                        renameText = e.name
                        renaming = e
                    } label: {
                        Label("重命名", systemImage: "pencil")
                    }
                    .tint(.orange)
                }
            }
            .listStyle(.plain)
            .overlay {
                if loading {
                    ProgressView()
                } else if shown.isEmpty && adb.connected {
                    Text("空目录或无权限").foregroundColor(.secondary)
                }
            }
        }
        .task(id: adb.connected) { if adb.connected { await reload() } }
        .fileImporter(isPresented: $picking, allowedContentTypes: [.data],
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let u = urls.first { upload(u) }
        }
        .alert("删除 \(deleting?.name ?? "")？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("删除", role: .destructive) {
                if let e = deleting { remove(e) }
                deleting = nil
            }
            Button("取消", role: .cancel) { deleting = nil }
        }
        .alert("新建文件夹", isPresented: $newFolder) {
            TextField("名称", text: $folderName)
            Button("创建") { makeFolder() }
            Button("取消", role: .cancel) { folderName = "" }
        }
        .alert("重命名为", isPresented: Binding(
            get: { renaming != nil }, set: { if !$0 { renaming = nil } }
        )) {
            TextField("新名称", text: $renameText)
            Button("确定") { doRename() }
            Button("取消", role: .cancel) { renaming = nil }
        } message: {
            Text(renaming.map { "当前：\($0.name)" } ?? "")
        }
    }

    private func child(_ name: String) -> String {
        path == "/" ? "/" + name : path + "/" + name
    }

    private func detail(_ e: FileEntry) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(e.mtime))
            .formatted(date: .abbreviated, time: .shortened)
        if e.isDir { return date }
        return ByteCountFormatter.string(fromByteCount: Int64(e.size), countStyle: .file) + " · " + date
    }

    private func up() {
        let parent = (path as NSString).deletingLastPathComponent
        path = parent.isEmpty ? "/" : parent
        Task { await reload() }
    }

    private func reload() async {
        guard adb.connected else { return }
        loading = true
        if let list = await adb.listDir(path) {
            entries = list
            message = ""
        } else {
            entries = []
            message = "无法读取该目录"
        }
        loading = false
    }

    private func open(_ e: FileEntry) {
        if e.isDir || e.isLink {
            path = child(e.name)
            Task { await reload() }
            return
        }
        Task {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(e.name)
            message = "下载中…"
            let ok = await adb.pull(child(e.name), to: url) { n in
                message = "下载中 \(n / 1024) KB"
            }
            if ok {
                shareURL = url
                message = "已下载 \(e.name)"
            } else {
                message = "下载失败（可能无权限）"
            }
        }
    }

    private func remove(_ e: FileEntry) {
        Task {
            _ = await adb.shellText("rm -rf \(shq(child(e.name)))")
            await reload()
        }
    }

    private func makeFolder() {
        let name = folderName.trimmingCharacters(in: .whitespaces)
        folderName = ""
        guard !name.isEmpty else { return }
        Task {
            _ = await adb.shellText("mkdir -p \(shq(child(name)))")
            await reload()
        }
    }

    private func doRename() {
        guard let e = renaming else { return }
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        renaming = nil
        renameText = ""
        guard !newName.isEmpty, newName != e.name, !newName.contains("/") else { return }
        Task {
            let ok = await adb.rename(child(e.name), to: child(newName))
            message = ok ? "已重命名" : "重命名失败（可能无权限或目标已存在）"
            await reload()
        }
    }

    private func upload(_ url: URL) {
        Task {
            let access = url.startAccessingSecurityScopedResource()
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            guard let data = try? Data(contentsOf: url) else {
                message = "读取文件失败"
                return
            }
            message = "上传中 0%"
            let ok = await adb.push(data, to: child(url.lastPathComponent)) { p in
                message = "上传中 \(Int(p * 100))%"
            }
            message = ok ? "上传完成" : "上传失败"
            await reload()
        }
    }
}
