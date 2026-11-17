import Foundation
import SwiftUI
import UIKit

final class DataBox { var data = Data() }

/// 一条 ADB 逻辑流（shell、sync、logcat 等）。
@MainActor
final class ADBStream {
    let id: UInt32
    var remoteId: UInt32 = 0
    let transport: ADBTransport
    let maxData: Int
    var onData: ((Data) -> Void)?
    var onClose: (() -> Void)?
    private(set) var closed = false
    private var okayCount = 0
    private var okayWaiter: CheckedContinuation<Void, Never>?
    private var closeWaiters: [CheckedContinuation<Void, Never>] = []

    init(id: UInt32, transport: ADBTransport, maxData: Int) {
        self.id = id
        self.transport = transport
        self.maxData = maxData
    }

    func awaitOkay() async {
        if okayCount > 0 { okayCount -= 1; return }
        if closed { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            okayWaiter = c
        }
    }

    func gotOkay() {
        if let w = okayWaiter {
            okayWaiter = nil
            w.resume()
        } else {
            okayCount += 1
        }
    }

    func markClosed() {
        guard !closed else { return }
        closed = true
        okayWaiter?.resume()
        okayWaiter = nil
        let ws = closeWaiters
        closeWaiters = []
        ws.forEach { $0.resume() }
        onClose?()
    }

    func waitClosed() async {
        if closed { return }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            closeWaiters.append(c)
        }
    }

    /// 按设备 maxdata 分片发送，每片等待对端 OKAY（流控）。
    func write(_ data: Data) async {
        var off = 0
        while off < data.count && !closed {
            let end = min(off + maxData, data.count)
            try? await transport.sendMessage(ADB.WRTE, id, remoteId, Data(data[off..<end]))
            await awaitOkay()
            off = end
        }
    }

    func sendClose() {
        guard !closed else { return }
        let t = transport, i = id, r = remoteId
        Task { try? await t.sendMessage(ADB.CLSE, i, r) }
        markClosed()
    }
}

@MainActor
final class ADBClient: ObservableObject {
    @Published var output = ""
    @Published var status = "未连接"
    @Published var connected = false
    @Published var logOutput = ""
    @Published var logRunning = false
    @Published var toolStatus = ""
    @Published var screenshot: UIImage?
    @Published var deviceInfo: [(String, String)] = []

    private var transport: ADBTransport?
    private var connectTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private var streams: [UInt32: ADBStream] = [:]
    private var nextId: UInt32 = 1
    private var deviceMaxData = 4096
    private var shell: ADBStream?
    private var logStream: ADBStream?

    // MARK: - 连接

    func connect(host: String, port: String) {
        guard let p = UInt16(port), !host.isEmpty else {
            status = "请填写正确的 IP 和端口"
            return
        }
        disconnect()
        status = "连接中…"
        connectTask = Task { await self.run(host: host, port: p) }
    }

    func disconnect() {
        connectTask?.cancel()
        readTask?.cancel()
        closeAllStreams()
        transport?.cancel()
        transport = nil
        connected = false
        logRunning = false
        status = "未连接"
    }

    private func closeAllStreams() {
        for s in streams.values {
            s.onClose = nil
            s.markClosed()
        }
        streams = [:]
        shell = nil
        logStream = nil
    }

    private func run(host: String, port: UInt16) async {
        let t = ADBTransport(host: host, port: port)
        transport = t
        do {
            let key = try ADBKey.loadOrCreate()
            try await t.start()
            try await t.sendMessage(ADB.CNXN, 0x0100_0000, 256 * 1024, Data("host::ADBTerm\0".utf8))

            var sentSignature = false
            var banner = ""
            var maxData = 4096
            handshake: while true {
                let m = try await t.readMessage()
                switch m.command {
                case ADB.CNXN:
                    banner = String(decoding: m.data, as: UTF8.self)
                    maxData = Int(m.arg1)
                    break handshake
                case ADB.AUTH where m.arg0 == 1:
                    if !sentSignature {
                        let sig = try key.sign(token: m.data)
                        try await t.sendMessage(ADB.AUTH, 2, 0, sig)
                        sentSignature = true
                    } else {
                        status = "请在手机上点“允许 USB 调试”"
                        try await t.sendMessage(ADB.AUTH, 3, 0, key.publicKeyPayload)
                    }
                case ADB.STLS:
                    throw ADBError.tlsRequired
                default:
                    break
                }
            }

            deviceMaxData = max(1024, min(maxData, 64 * 1024))
            connected = true
            status = "已连接 \(host):\(port)"
            append("[已连接] \(banner.prefix(120))\n")

            readTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let m = try await t.readMessage()
                        await self?.dispatch(m, t)
                    }
                } catch {
                    await self?.finish(error)
                }
            }
            await openShell()
        } catch {
            if !Task.isCancelled {
                status = "失败：\(error.localizedDescription)"
            }
            t.cancel()
            connected = false
        }
    }

    private func dispatch(_ m: ADBMessage, _ t: ADBTransport) async {
        guard let s = streams[m.arg1] else { return }
        switch m.command {
        case ADB.OKAY:
            if s.remoteId == 0 { s.remoteId = m.arg0 }
            s.gotOkay()
        case ADB.WRTE:
            if s.remoteId == 0 { s.remoteId = m.arg0 }
            s.onData?(m.data)
            try? await t.sendMessage(ADB.OKAY, s.id, m.arg0)
        case ADB.CLSE:
            streams[s.id] = nil
            s.markClosed()
        default:
            break
        }
    }

    private func finish(_ error: Error) {
        guard connected else { return }
        connected = false
        logRunning = false
        closeAllStreams()
        status = "连接断开：\(error.localizedDescription)"
    }

    // MARK: - 流

    func open(_ service: String, onData: @escaping (Data) -> Void,
              onClose: @escaping () -> Void = {}) async -> ADBStream? {
        guard connected, let t = transport else { return nil }
        let s = ADBStream(id: nextId, transport: t, maxData: deviceMaxData)
        nextId += 1
        s.onData = onData
        s.onClose = onClose
        streams[s.id] = s
        do {
            try await t.sendMessage(ADB.OPEN, s.id, 0, Data((service + "\0").utf8))
        } catch {
            streams[s.id] = nil
            return nil
        }
        await s.awaitOkay()
        if s.closed || s.remoteId == 0 {
            streams[s.id] = nil
            return nil
        }
        return s
    }

    func closeStream(_ s: ADBStream) {
        streams[s.id] = nil
        s.sendClose()
    }

    /// 打开一个服务，收集全部输出直到对端关闭。
    func collect(_ service: String) async -> Data? {
        let box = DataBox()
        guard let s = await open(service, onData: { box.data.append($0) }) else { return nil }
        await s.waitClosed()
        return box.data
    }

    // MARK: - 终端

    private func openShell() async {
        shell = await open("shell:", onData: { [weak self] d in
            self?.append(Self.clean(d))
        }, onClose: { [weak self] in
            self?.append("\n[shell 已关闭，再发命令会自动重开]\n")
            self?.shell = nil
        })
    }

    func sendLine(_ line: String) {
        guard connected else { return }
        Task {
            if shell == nil || shell?.closed == true { await openShell() }
            await shell?.write(Data((line + "\n").utf8))
        }
    }

    func clearOutput() { output = "" }

    private func append(_ s: String) {
        output += s
        if output.utf8.count > 200_000 { output = String(output.suffix(150_000)) }
    }

    // MARK: - Logcat

    func startLog() async {
        guard connected, logStream == nil else { return }
        logRunning = true
        logStream = await open("exec:logcat -v time", onData: { [weak self] d in
            self?.appendLog(Self.clean(d))
        }, onClose: { [weak self] in
            self?.logRunning = false
            self?.logStream = nil
        })
        if logStream == nil {
            logRunning = false
            appendLog("[无法启动 logcat]\n")
        }
    }

    func stopLog() {
        if let s = logStream {
            s.onClose = nil
            closeStream(s)
        }
        logStream = nil
        logRunning = false
    }

    private func appendLog(_ s: String) {
        logOutput += s
        if logOutput.utf8.count > 300_000 { logOutput = String(logOutput.suffix(200_000)) }
    }

    // MARK: - 截图

    func takeScreenshot() async {
        guard connected else { toolStatus = "未连接"; return }
        toolStatus = "正在截图…"
        guard let data = await collect("exec:screencap -p"), data.count > 100,
              let img = UIImage(data: data) else {
            toolStatus = "截图失败"
            return
        }
        screenshot = img
        toolStatus = "截图完成（\(data.count / 1024) KB）"
    }

    // MARK: - 安装 APK

    func installAPK(_ url: URL) async {
        guard connected else { toolStatus = "未连接"; return }
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: url) else {
            toolStatus = "读取文件失败"
            return
        }
        let remote = "/data/local/tmp/adbterm.apk"
        toolStatus = "上传中 0%"
        let ok = await push(data, to: remote) { [weak self] p in
            self?.toolStatus = "上传中 \(Int(p * 100))%"
        }
        guard ok else { toolStatus = "上传失败"; return }
        toolStatus = "安装中…"
        let out = await collect("shell:pm install -r \(remote)") ?? Data()
        let text = String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        toolStatus = text.isEmpty ? "安装结束（无输出）" : "安装结果：\(text)"
        _ = await collect("shell:rm \(remote)")
    }

    /// ADB sync 协议：SEND → DATA… → DONE → 等 OKAY。
    func push(_ data: Data, to path: String, progress: @escaping (Double) -> Void) async -> Bool {
        let box = DataBox()
        guard let s = await open("sync:", onData: { box.data.append($0) }) else { return false }

        let spec = Data("\(path),33206".utf8)
        var head = Data("SEND".utf8)
        head.appendLE(UInt32(spec.count))
        head.append(spec)
        await s.write(head)

        let chunk = 64 * 1024
        var off = 0
        while off < data.count && !s.closed {
            let end = min(off + chunk, data.count)
            var pkt = Data("DATA".utf8)
            pkt.appendLE(UInt32(end - off))
            pkt.append(data[off..<end])
            await s.write(pkt)
            off = end
            progress(Double(off) / Double(max(data.count, 1)))
        }

        var done = Data("DONE".utf8)
        done.appendLE(UInt32(Date().timeIntervalSince1970))
        await s.write(done)

        for _ in 0..<300 {
            if box.data.count >= 8 || s.closed { break }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        let ok = box.data.count >= 4 && String(decoding: box.data.prefix(4), as: UTF8.self) == "OKAY"

        var quit = Data("QUIT".utf8)
        quit.appendLE(0)
        await s.write(quit)
        closeStream(s)
        return ok
    }

    // MARK: - 输出清理

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    private static func clean(_ d: Data) -> String {
        var s = String(decoding: d, as: UTF8.self)
        s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "")
        let range = NSRange(s.startIndex..., in: s)
        return ansi.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}
