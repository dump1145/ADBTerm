import Foundation
import SwiftUI

/// 一条自定义快捷命令（对应参考 APK 的「快捷命令 / 添加命令」）。
struct QuickCommand: Identifiable, Codable, Hashable {
    var id = UUID()
    var title: String
    var script: String
}

/// 持久化保存自定义命令与终端历史。
@MainActor
final class CommandStore: ObservableObject {
    @Published var commands: [QuickCommand] = [] {
        didSet { persist() }
    }
    @Published var history: [String] = [] {
        didSet { persist() }
    }

    private let commandsKey = "adbterm.commands"
    private let historyKey = "adbterm.history"

    init() {
        if let data = UserDefaults.standard.data(forKey: commandsKey),
           let list = try? JSONDecoder().decode([QuickCommand].self, from: data) {
            commands = list
        } else {
            commands = [
                QuickCommand(title: "屏幕分辨率", script: "wm size"),
                QuickCommand(title: "当前 DPI", script: "wm density"),
                QuickCommand(title: "前台应用", script: "dumpsys window | grep mCurrentFocus"),
                QuickCommand(title: "IP 地址", script: "ip addr show wlan0 | grep inet"),
                QuickCommand(title: "重启 adbd", script: "setprop ctl.restart adbd")
            ]
        }
        history = UserDefaults.standard.stringArray(forKey: historyKey) ?? []
    }

    func save(_ c: QuickCommand) {
        if let i = commands.firstIndex(where: { $0.id == c.id }) {
            commands[i] = c
        } else {
            commands.append(c)
        }
    }

    func delete(_ c: QuickCommand) {
        commands.removeAll { $0.id == c.id }
    }

    func addHistory(_ s: String) {
        let t = s.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        history.removeAll { $0 == t }
        history.insert(t, at: 0)
        if history.count > 50 { history = Array(history.prefix(50)) }
    }

    func clearHistory() {
        history = []
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(commands) {
            UserDefaults.standard.set(data, forKey: commandsKey)
        }
        UserDefaults.standard.set(history, forKey: historyKey)
    }
}
