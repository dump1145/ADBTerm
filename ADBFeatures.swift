import Foundation

/// 用单引号包裹，避免路径/包名里的特殊字符被 shell 解释。
func shq(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
}

struct FileEntry: Identifiable, Hashable {
    var id: String { name }
    let name: String
    let mode: UInt32
    let size: UInt32
    let mtime: UInt32
    var isDir: Bool { mode & 0o170000 == 0o040000 }
    var isLink: Bool { mode & 0o170000 == 0o120000 }
}

struct AppInfo: Identifiable, Hashable {
    var id: String { pkg }
    let pkg: String
    let apkPath: String
    var system: Bool
    var disabled: Bool
}

/// 流式解析 sync RECV 的返回：DATA(len)… DONE / FAIL。
final class PullParser {
    var buf = Data()
    var remaining = 0
    var done = false
    var failed = false
    var total = 0
    let handle: FileHandle

    init(handle: FileHandle) { self.handle = handle }

    func feed(_ d: Data) {
        buf.append(d)
        while true {
            if remaining > 0 {
                let n = min(remaining, buf.count)
                if n == 0 { return }
                handle.write(Data(buf.prefix(n)))
                buf.removeFirst(n)
                remaining -= n
                total += n
                continue
            }
            guard buf.count >= 8 else { return }
            let tag = String(decoding: buf.prefix(4), as: UTF8.self)
            let len = Int(buf.le32(4))
            if tag == "DATA" {
                buf.removeFirst(8)
                remaining = len
            } else if tag == "DONE" {
                done = true
                buf.removeAll()
                return
            } else {
                failed = true
                return
            }
        }
    }
}

extension ADBClient {
    /// 执行 shell 命令并返回文本输出。
    func shellText(_ cmd: String) async -> String {
        guard let d = await collect("shell:" + cmd) else { return "" }
        return String(decoding: d, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - 设备信息

    func refreshInfo() async {
        guard connected else { return }
        let script = "echo brand=$(getprop ro.product.brand);echo model=$(getprop ro.product.model);"
            + "echo android=$(getprop ro.build.version.release);echo sdk=$(getprop ro.build.version.sdk);"
            + "echo abi=$(getprop ro.product.cpu.abi);echo size=$(wm size | tail -n1);"
            + "echo density=$(wm density | tail -n1);echo battery=$(dumpsys battery | grep -m1 level);"
            + "echo mem=$(head -n1 /proc/meminfo);echo disk=$(df -h /data | tail -n1)"
        guard let d = await collect("shell:" + script) else { return }
        let names = ["brand": "品牌", "model": "型号", "android": "Android", "sdk": "SDK",
                     "abi": "CPU 架构", "size": "分辨率", "density": "屏幕密度",
                     "battery": "电量", "mem": "内存", "disk": "存储"]
        var items: [(String, String)] = []
        for line in String(decoding: d, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let i = line.firstIndex(of: "=") else { continue }
            let k = String(line[..<i])
            let v = String(line[line.index(after: i)...]).trimmingCharacters(in: .whitespaces)
            if let n = names[k], !v.isEmpty { items.append((n, v)) }
        }
        deviceInfo = items
    }

    // MARK: - 应用

    func loadApps() async -> [AppInfo] {
        func pkgs(_ text: String) -> [String] {
            text.split(whereSeparator: \.isNewline).compactMap { line in
                let l = line.trimmingCharacters(in: .whitespaces)
                return l.hasPrefix("package:") ? String(l.dropFirst(8)) : nil
            }
        }
        let all = await shellText("pm list packages -f")
        let user = Set(pkgs(await shellText("pm list packages -3")))
        let disabled = Set(pkgs(await shellText("pm list packages -d")))
        var result: [AppInfo] = []
        for entry in pkgs(all) {
            guard let eq = entry.lastIndex(of: "=") else { continue }
            let path = String(entry[..<eq])
            let pkg = String(entry[entry.index(after: eq)...])
            result.append(AppInfo(pkg: pkg, apkPath: path,
                                  system: !user.contains(pkg), disabled: disabled.contains(pkg)))
        }
        return result.sorted { $0.pkg < $1.pkg }
    }

    // MARK: - 文件（sync 协议）

    func listDir(_ path: String) async -> [FileEntry]? {
        let box = DataBox()
        guard let s = await open("sync:", onData: { box.data.append($0) }) else { return nil }
        let p = Data(path.utf8)
        var req = Data("LIST".utf8)
        req.appendLE(UInt32(p.count))
        req.append(p)
        await s.write(req)

        var entries: [FileEntry] = []
        var pos = 0
        var finished = false
        var failed = false
        var idle = 0
        while !finished && !failed && idle < 600 {
            var progressed = false
            while true {
                let d = box.data
                guard d.count - pos >= 4 else { break }
                let tag = String(decoding: d.subdata(in: pos..<(pos + 4)), as: UTF8.self)
                if tag == "DONE" { finished = true; break }
                if tag != "DENT" { failed = true; break }
                guard d.count - pos >= 20 else { break }
                let mode = d.le32(pos + 4)
                let size = d.le32(pos + 8)
                let mtime = d.le32(pos + 12)
                let nlen = Int(d.le32(pos + 16))
                guard d.count - pos >= 20 + nlen else { break }
                let name = String(decoding: d.subdata(in: (pos + 20)..<(pos + 20 + nlen)), as: UTF8.self)
                pos += 20 + nlen
                progressed = true
                if name != "." && name != ".." {
                    entries.append(FileEntry(name: name, mode: mode, size: size, mtime: mtime))
                }
            }
            if finished || failed || s.closed { break }
            if !progressed {
                idle += 1
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        closeStream(s)
        if failed { return nil }
        return entries.sorted {
            if $0.isDir != $1.isDir { return $0.isDir }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func pull(_ remote: String, to url: URL, progress: @escaping (Int) -> Void) async -> Bool {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        guard let h = try? FileHandle(forWritingTo: url) else { return false }
        defer { try? h.close() }
        let parser = PullParser(handle: h)
        guard let s = await open("sync:", onData: { d in
            parser.feed(d)
            progress(parser.total)
        }) else { return false }
        let p = Data(remote.utf8)
        var req = Data("RECV".utf8)
        req.appendLE(UInt32(p.count))
        req.append(p)
        await s.write(req)
        while !parser.done && !parser.failed && !s.closed {
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        closeStream(s)
        return parser.done
    }

    /// sync STAT：取单个路径的属性（权限、大小、mtime），失败返回 nil。
    func stat(_ remote: String) async -> FileEntry? {
        let box = DataBox()
        guard let s = await open("sync:", onData: { box.data.append($0) }) else { return nil }
        let p = Data(remote.utf8)
        var req = Data("STAT".utf8)
        req.appendLE(UInt32(p.count))
        req.append(p)
        await s.write(req)
        var waited = 0
        while box.data.count < 16 && waited < 40 && !s.closed {
            try? await Task.sleep(nanoseconds: 100_000_000)
            waited += 1
        }
        closeStream(s)
        guard box.data.count >= 16 else { return nil }
        return FileEntry(name: (remote as NSString).lastPathComponent,
                         mode: box.data.le32(4),
                         size: box.data.le32(8),
                         mtime: box.data.le32(12))
    }

    /// 重命名 / 移动（shell mv，带引号转义）
    func rename(_ from: String, to: String) async -> Bool {
        let out = await shellText("mv -f \(shq(from)) \(shq(to)) && echo OK")
        return out.contains("OK")
    }
}
