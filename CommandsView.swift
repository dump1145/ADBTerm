import SwiftUI

/// 快捷命令页：自定义命令的增删改、执行，以及可点击回填的历史记录。
struct CommandsView: View {
    @ObservedObject var adb: ADBClient
    @ObservedObject var store: CommandStore
    @State private var showEditor = false
    @State private var draft = QuickCommand(title: "", script: "")
    @State private var message = ""

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Text("快捷命令").font(.headline)
                Spacer()
                EditButton()
                Button {
                    draft = QuickCommand(title: "", script: "")
                    showEditor = true
                } label: {
                    Image(systemName: "plus")
                }
            }
            if !message.isEmpty {
                Text(message)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            List {
                Section("命令（点按执行）") {
                    ForEach(store.commands) { c in
                        Button { run(c) } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.title).font(.subheadline)
                                Text(c.script)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { store.delete(c) } label: {
                                Label("删除", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .leading) {
                            Button { draft = c; showEditor = true } label: {
                                Label("编辑", systemImage: "pencil")
                            }
                            .tint(.orange)
                        }
                    }
                    .onMove { store.commands.move(fromOffsets: $0, toOffset: $1) }
                }
                Section {
                    ForEach(store.history, id: \.self) { h in
                        Button { adb.sendLine(h); message = "已发送：\(h)" } label: {
                            Text(h)
                                .font(.caption)
                                .lineLimit(1)
                        }
                    }
                    .onDelete { store.history.remove(atOffsets: $0) }
                } header: {
                    HStack {
                        Text("历史记录（点按回填终端）")
                        Spacer()
                        if !store.history.isEmpty {
                            Button("清空") { store.clearHistory() }
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
        .sheet(isPresented: $showEditor) { editorSheet }
    }

    private func run(_ c: QuickCommand) {
        guard adb.connected else { message = "未连接设备"; return }
        adb.sendLine(c.script)
        store.addHistory(c.script)
        message = "已执行：\(c.title)"
    }

    private var editorSheet: some View {
        NavigationStack {
            Form {
                Section("名称") {
                    TextField("例如 电池信息", text: $draft.title)
                }
                Section("命令") {
                    TextField("shell 命令", text: $draft.script)
                        .autocorrectionDisabled()
                        .textInputAutocapitalization(.never)
                    Text("直接写命令，无需 adb shell 前缀，例如：dumpsys battery")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            .navigationTitle("快捷命令")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { showEditor = false }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("保存") {
                        let t = draft.title.trimmingCharacters(in: .whitespaces)
                        let s = draft.script.trimmingCharacters(in: .whitespaces)
                        if !t.isEmpty && !s.isEmpty {
                            store.save(QuickCommand(id: draft.id, title: t, script: s))
                        }
                        showEditor = false
                    }
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty
                              || draft.script.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
    }
}
