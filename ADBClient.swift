import Foundation
import SwiftUI

@MainActor
final class ADBClient: ObservableObject {
    @Published var output = ""
    @Published var status = "未连接"
    @Published var connected = false

    private var transport: ADBTransport?
    private var connectTask: Task<Void, Never>?
    private var readTask: Task<Void, Never>?
    private let localId: UInt32 = 1
    private var remoteId: UInt32 = 0

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
        transport?.cancel()
        transport = nil
        remoteId = 0
        connected = false
        status = "未连接"
    }

    func sendLine(_ line: String) {
        guard connected, remoteId != 0, let t = transport else { return }
        let id = remoteId
        let local = localId
        Task { try? await t.sendMessage(ADB.WRTE, local, id, Data((line + "\n").utf8)) }
    }

    // MARK: - 连接流程

    private func run(host: String, port: UInt16) async {
        let t = ADBTransport(host: host, port: port)
        transport = t
        do {
            let key = try ADBKey.loadOrCreate()
            try await t.start()
            try await t.sendMessage(ADB.CNXN, 0x0100_0000, 256 * 1024, Data("host::ADBTerm\0".utf8))

            var sentSignature = false
            var banner = ""
            handshake: while true {
                let m = try await t.readMessage()
                switch m.command {
                case ADB.CNXN:
                    banner = String(decoding: m.data, as: UTF8.self)
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

            connected = true
            status = "已连接 \(host):\(port)"
            append("[已连接] \(banner.prefix(120))\n")
            try await t.sendMessage(ADB.OPEN, localId, 0, Data("shell:\0".utf8))

            readTask = Task { [weak self] in
                do {
                    while !Task.isCancelled {
                        let m = try await t.readMessage()
                        await self?.handle(m, t)
                    }
                } catch {
                    await self?.finish(error)
                }
            }
        } catch {
            if !Task.isCancelled {
                status = "失败：\(error.localizedDescription)"
            }
            t.cancel()
            connected = false
        }
    }

    private func handle(_ m: ADBMessage, _ t: ADBTransport) async {
        switch m.command {
        case ADB.OKAY:
            if remoteId == 0 { remoteId = m.arg0 }
        case ADB.WRTE:
            if remoteId == 0 { remoteId = m.arg0 }
            append(Self.clean(m.data))
            try? await t.sendMessage(ADB.OKAY, localId, m.arg0)
        case ADB.CLSE:
            append("\n[shell 已关闭]\n")
            status = "shell 已关闭"
            connected = false
            readTask?.cancel()
            transport?.cancel()
        default:
            break
        }
    }

    private func finish(_ error: Error) {
        guard connected else { return }
        connected = false
        status = "连接断开：\(error.localizedDescription)"
    }

    // MARK: - 输出处理

    private func append(_ s: String) {
        output += s
        if output.utf8.count > 200_000 {
            output = String(output.suffix(150_000))
        }
    }

    func clearOutput() { output = "" }

    private static let ansi = try! NSRegularExpression(pattern: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]")

    private static func clean(_ d: Data) -> String {
        var s = String(decoding: d, as: UTF8.self)
        s = s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "")
        let range = NSRange(s.startIndex..., in: s)
        return ansi.stringByReplacingMatches(in: s, range: range, withTemplate: "")
    }
}
