import Foundation
import Network

enum ADB {
    static let CNXN: UInt32 = 0x4e584e43
    static let AUTH: UInt32 = 0x48545541
    static let OPEN: UInt32 = 0x4e45504f
    static let OKAY: UInt32 = 0x59414b4f
    static let WRTE: UInt32 = 0x45545257
    static let CLSE: UInt32 = 0x45534c43
    static let STLS: UInt32 = 0x534c5453
}

enum ADBError: Error, LocalizedError {
    case closed, badMessage, tlsRequired
    var errorDescription: String? {
        switch self {
        case .closed:
            return "连接已关闭"
        case .badMessage:
            return "收到异常的 ADB 数据"
        case .tlsRequired:
            return "设备要求 TLS（Android 11+ 的无线调试端口）。v1 只支持明文 ADB：请先用电脑执行 adb tcpip 5555，再连接 5555 端口。"
        }
    }
}

struct ADBMessage {
    var command: UInt32
    var arg0: UInt32
    var arg1: UInt32
    var data: Data
}

extension Data {
    mutating func appendLE(_ v: UInt32) {
        append(contentsOf: [
            UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
            UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)
        ])
    }

    func le32(_ off: Int) -> UInt32 {
        let b = startIndex + off
        let v0 = UInt32(self[b])
        let v1 = UInt32(self[b + 1]) << 8
        let v2 = UInt32(self[b + 2]) << 16
        let v3 = UInt32(self[b + 3]) << 24
        return v0 | v1 | v2 | v3
    }
}

/// 基于 Network.framework 的 TCP 传输 + ADB 消息收发。
final class ADBTransport: @unchecked Sendable {
    private let conn: NWConnection

    init(host: String, port: UInt16) {
        conn = NWConnection(
            host: NWEndpoint.Host(host),
            port: NWEndpoint.Port(rawValue: port) ?? 5555,
            using: .tcp
        )
    }

    func start() async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            var resumed = false
            conn.stateUpdateHandler = { state in
                guard !resumed else { return }
                switch state {
                case .ready:
                    resumed = true
                    cont.resume()
                case .failed(let e), .waiting(let e):
                    resumed = true
                    cont.resume(throwing: e)
                case .cancelled:
                    resumed = true
                    cont.resume(throwing: ADBError.closed)
                default:
                    break
                }
            }
            conn.start(queue: DispatchQueue(label: "adb.transport"))
        }
    }

    func cancel() { conn.cancel() }

    private func send(_ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            conn.send(content: data, completion: .contentProcessed { err in
                if let err = err { cont.resume(throwing: err) } else { cont.resume() }
            })
        }
    }

    private func receive(exactly n: Int) async throws -> Data {
        var buf = Data()
        while buf.count < n {
            let remaining = n - buf.count
            let chunk: Data = try await withCheckedThrowingContinuation { cont in
                conn.receive(minimumIncompleteLength: 1, maximumLength: remaining) { data, _, isComplete, error in
                    if let error = error {
                        cont.resume(throwing: error)
                    } else if let data = data, !data.isEmpty {
                        cont.resume(returning: data)
                    } else if isComplete {
                        cont.resume(throwing: ADBError.closed)
                    } else {
                        cont.resume(returning: Data())
                    }
                }
            }
            buf.append(chunk)
        }
        return buf
    }

    func sendMessage(_ cmd: UInt32, _ arg0: UInt32, _ arg1: UInt32, _ payload: Data = Data()) async throws {
        var sum: UInt32 = 0
        for b in payload { sum = sum &+ UInt32(b) }
        var msg = Data()
        msg.appendLE(cmd)
        msg.appendLE(arg0)
        msg.appendLE(arg1)
        msg.appendLE(UInt32(payload.count))
        msg.appendLE(sum)
        msg.appendLE(cmd ^ 0xffff_ffff)
        msg.append(payload)
        try await send(msg)
    }

    func readMessage() async throws -> ADBMessage {
        let h = try await receive(exactly: 24)
        let cmd = h.le32(0)
        let len = Int(h.le32(12))
        guard h.le32(20) == (cmd ^ 0xffff_ffff), len <= 1 << 20 else {
            throw ADBError.badMessage
        }
        let body = len > 0 ? try await receive(exactly: len) : Data()
        return ADBMessage(command: cmd, arg0: h.le32(4), arg1: h.le32(8), data: body)
    }
}
