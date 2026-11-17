import SwiftUI

/// 应用运行时权限管理（对应参考 APK 的「权限狗」能力）。
struct PermissionsView: View {
    @ObservedObject var adb: ADBClient
    let pkg: String
    @Environment(\.dismiss) private var dismiss
    @State private var items: [PermissionItem] = []
    @State private var loading = false
    @State private var message = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                Text(pkg)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !message.isEmpty {
                    Text(message)
                        .font(.footnote)
                        .foregroundColor(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                List(items) { p in
                    HStack(spacing: 8) {
                        Text(p.name.replacingOccurrences(of: "android.permission.", with: ""))
                            .font(.caption)
                            .lineLimit(2)
                        Spacer()
                        Button { toggle(p) } label: {
                            Text(p.granted ? "已允许" : "未允许")
                                .font(.caption)
                        }
                        .buttonStyle(.bordered)
                        .tint(p.granted ? .green : .orange)
                    }
                }
                .listStyle(.plain)
                .overlay {
                    if loading { ProgressView() }
                }
            }
            .padding(.horizontal, 12)
            .navigationTitle("权限")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
            .task { await load() }
        }
    }

    private func load() async {
        loading = true
        items = await adb.permissions(for: pkg)
        loading = false
    }

    private func toggle(_ p: PermissionItem) {
        Task {
            message = "处理中…"
            message = await adb.setPermission(p.name, granted: !p.granted, for: pkg)
            await load()
        }
    }
}
