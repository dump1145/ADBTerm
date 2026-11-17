import Foundation
import SwiftUI

// MARK: - 数据模型

/// 屏幕显示参数（含 override）。
struct DisplaySettings {
    var size = ""
    var sizeOverride = ""
    var density = ""
    var densityOverride = ""
}

/// 三种动画缩放倍率。
struct AnimationSettings {
    var window = ""
    var transition = ""
    var animator = ""
}

enum AnimKey {
    case window, transition, animator
}

/// 高级重启目标。
enum SystemRebootMode: String, CaseIterable, Identifiable {
    case normal = "正常重启"
    case recovery = "Recovery"
    case bootloader = "Bootloader"
    case fastboot = "Fastboot"

    var id: String { rawValue }

    var command: String {
        switch self {
        case .normal:     return "reboot"
        case .recovery:   return "reboot recovery"
        case .bootloader: return "reboot bootloader"
        case .fastboot:   return "reboot fastboot"
        }
    }
}

/// 应用运行时权限项。
struct PermissionItem: Identifiable, Hashable {
    var id: String { name }
    let name: String
    var granted: Bool
}

/// 仿照「甲壳虫ADB助手」扩展的系统工具：分辨率 / DPI / 动画 / 墓碑模式 /
/// 屏幕开关 / 高级重启 / 屏幕录制 / 权限管理。全部通过现有 ADB shell 通道实现，
/// 不需要设备 root（墓碑模式、重启等取决于系统是否允许 shell 修改）。
extension ADBClient {

    // MARK: - 分辨率与 DPI

    /// 读取当前分辨率与 DPI，同时识别 Override（用户修改过的值）。
    func readDisplay() async -> DisplaySettings {
        var s = DisplaySettings()
        let sizeText = await shellText("wm size")
        let densityText = await shellText("wm density")

        for raw in sizeText.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Physical size:") {
                s.size = String(line.dropFirst("Physical size:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Override size:") {
                s.sizeOverride = String(line.dropFirst("Override size:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        for raw in densityText.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("Physical density:") {
                s.density = String(line.dropFirst("Physical density:".count)).trimmingCharacters(in: .whitespaces)
            } else if line.hasPrefix("Override density:") {
                s.densityOverride = String(line.dropFirst("Override density:".count)).trimmingCharacters(in: .whitespaces)
            }
        }
        // 部分设备只输出一行纯值，做兜底。
        if s.size.isEmpty { s.size = sizeText.trimmingCharacters(in: .whitespacesAndNewlines) }
        if s.density.isEmpty { s.density = densityText.trimmingCharacters(in: .whitespacesAndNewlines) }
        return s
    }

    /// spec: "reset" 或 "1080x1920"。
    func setResolution(_ spec: String) async -> String {
        let clean = spec.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return "请输入分辨率" }
        let out = await shellText("wm size \(clean)")
        return out.isEmpty ? "已设置分辨率：\(clean)" : out
    }

    /// spec: "reset" 或 "320" / "480"。
    func setDensity(_ spec: String) async -> String {
        let clean = spec.trimmingCharacters(in: .whitespaces)
        guard !clean.isEmpty else { return "请输入 DPI" }
        let out = await shellText("wm density \(clean)")
        return out.isEmpty ? "已设置 DPI：\(clean)" : out
    }

    // MARK: - 动画缩放

    func readAnimations() async -> AnimationSettings {
        let w = await shellText("settings get global window_animation_scale")
        let t = await shellText("settings get global transition_animation_scale")
        let a = await shellText("settings get global animator_duration_scale")
        return AnimationSettings(window: w, transition: t, animator: a)
    }

    func setAnimation(_ key: AnimKey, value: String) async -> String {
        let name: String
        switch key {
        case .window:     name = "window_animation_scale"
        case .transition: name = "transition_animation_scale"
        case .animator:   name = "animator_duration_scale"
        }
        let out = await shellText("settings put global \(name) \(value)")
        return out.isEmpty ? "\(name) = \(value)" : out
    }

    // MARK: - 墓碑模式（后台应用冻结）

    func readFreezer() async -> String {
        await shellText("settings get global cached_apps_freezer")
    }

    func setFreezer(_ on: Bool) async -> String {
        let value = on ? "enabled" : "disabled"
        let out = await shellText("settings put global cached_apps_freezer \(value)")
        return out.isEmpty ? "墓碑模式已\(on ? "开启" : "关闭")" : out
    }

    // MARK: - 屏幕开关 / 高级重启

    /// 224 = KEYCODE_WAKEUP（点亮），223 = KEYCODE_SLEEP（熄屏但不锁屏）。
    func screenPower(_ on: Bool) async {
        _ = await shellText("input keyevent \(on ? 224 : 223)")
    }

    func reboot(_ mode: SystemRebootMode) async -> String {
        let out = await shellText(mode.command)
        return out.isEmpty ? "已发送：\(mode.rawValue)" : out
    }

    // MARK: - 屏幕录制（screenrecord → 拉取到本地）

    func recordScreen(seconds: Int, to url: URL, progress: @escaping (Int) -> Void) async -> Bool {
        guard connected else { toolStatus = "未连接"; return false }
        let sec = max(5, min(seconds, 180))
        let remote = "/data/local/tmp/adbterm-rec.mp4"
        toolStatus = "录制中 \(sec) 秒，请勿锁屏…"
        // screenrecord 写文件到设备；带 --time-limit 会自行退出并关闭 shell 流。
        _ = await collect("shell:screenrecord --time-limit \(sec) \(remote)")
        toolStatus = "导出视频…"
        let ok = await pull(remote, to: url, progress: progress)
        _ = await collect("shell:rm -f \(remote)")
        return ok
    }

    // MARK: - 运行时权限管理

    /// 从 dumpsys package 中解析 runtime permissions 段。
    func permissions(for pkg: String) async -> [PermissionItem] {
        let out = await shellText("dumpsys package \(shq(pkg))")
        var items: [PermissionItem] = []
        var inRuntime = false
        for raw in out.split(whereSeparator: \.isNewline) {
            let line = String(raw).trimmingCharacters(in: .whitespaces)
            if line == "runtime permissions:" { inRuntime = true; continue }
            guard inRuntime else { continue }
            if line.isEmpty { continue }
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            guard name.contains("permission.") else {
                // 遇到下一段（如 "User 0:"）则停止。
                if line.hasSuffix(":") { break }
                continue
            }
            let granted = line.contains("granted=true")
            if !items.contains(where: { $0.name == name }) {
                items.append(PermissionItem(name: name, granted: granted))
            }
        }
        return items.sorted { $0.name < $1.name }
    }

    func setPermission(_ perm: String, granted: Bool, for pkg: String) async -> String {
        let verb = granted ? "grant" : "revoke"
        let out = await shellText("pm \(verb) \(shq(pkg)) \(perm)")
        return out.isEmpty ? "已\(granted ? "授予" : "撤销") \(perm)" : out
    }
}
