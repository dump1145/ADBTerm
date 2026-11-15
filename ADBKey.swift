import Foundation
import Security

enum ADBKeyError: Error, LocalizedError {
    case generate, sign, parse
    var errorDescription: String? {
        switch self {
        case .generate: return "生成 RSA 密钥失败"
        case .sign: return "签名失败"
        case .parse: return "解析公钥失败"
        }
    }
}

/// ADB 使用的 RSA 2048 密钥：用于 AUTH 签名，以及发送 Android 专用格式的公钥。
final class ADBKey {
    private let privateKey: SecKey
    /// AUTH_RSAPUBLICKEY 的负载：base64(Android 公钥结构) + " 名称\0"
    let publicKeyPayload: Data

    private init(privateKey: SecKey) throws {
        self.privateKey = privateKey
        guard let pub = SecKeyCopyPublicKey(privateKey),
              let der = SecKeyCopyExternalRepresentation(pub, nil) as Data? else {
            throw ADBKeyError.parse
        }
        self.publicKeyPayload = try ADBKey.androidPublicKey(fromPKCS1: [UInt8](der))
    }

    private static func keyURL() -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("adb_key.der")
    }

    static func loadOrCreate() throws -> ADBKey {
        let url = keyURL()
        if let data = try? Data(contentsOf: url) {
            let attrs: [CFString: Any] = [
                kSecAttrKeyType: kSecAttrKeyTypeRSA,
                kSecAttrKeyClass: kSecAttrKeyClassPrivate
            ]
            var err: Unmanaged<CFError>?
            if let key = SecKeyCreateWithData(data as CFData, attrs as CFDictionary, &err) {
                return try ADBKey(privateKey: key)
            }
        }
        let params: [CFString: Any] = [
            kSecAttrKeyType: kSecAttrKeyTypeRSA,
            kSecAttrKeySizeInBits: 2048
        ]
        var err: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(params as CFDictionary, &err),
              let ext = SecKeyCopyExternalRepresentation(key, &err) as Data? else {
            throw ADBKeyError.generate
        }
        try ext.write(to: url, options: .atomic)
        return try ADBKey(privateKey: key)
    }

    /// ADB 的 token 本身就是 20 字节的 SHA1 摘要，所以按“已哈希”的方式做 PKCS#1 v1.5 签名。
    func sign(token: Data) throws -> Data {
        var err: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            privateKey, .rsaSignatureDigestPKCS1v15SHA1, token as CFData, &err
        ) as Data? else {
            throw ADBKeyError.sign
        }
        return sig
    }

    // MARK: - Android 公钥格式

    /// struct RSAPublicKey { u32 len=64; u32 n0inv; u32 n[64]; u32 rr[64]; i32 exponent; }（小端）
    static func androidPublicKey(fromPKCS1 der: [UInt8]) throws -> Data {
        var i = 0
        func byte() throws -> UInt8 {
            guard i < der.count else { throw ADBKeyError.parse }
            let b = der[i]
            i += 1
            return b
        }
        func length() throws -> Int {
            let b = try byte()
            if b < 0x80 { return Int(b) }
            var l = 0
            for _ in 0..<Int(b & 0x7f) { l = (l << 8) | Int(try byte()) }
            return l
        }
        func integer() throws -> [UInt8] {
            guard try byte() == 0x02 else { throw ADBKeyError.parse }
            let l = try length()
            guard i + l <= der.count else { throw ADBKeyError.parse }
            let v = Array(der[i..<(i + l)])
            i += l
            return v
        }

        guard try byte() == 0x30 else { throw ADBKeyError.parse }
        _ = try length()
        var n = try integer()
        let eBytes = try integer()
        while n.first == 0 { n.removeFirst() }
        guard n.count == 256 else { throw ADBKeyError.parse }
        var e: UInt32 = 0
        for b in eBytes { e = (e << 8) | UInt32(b) }

        // 大端字节 -> 小端 32 位字数组
        var words = [UInt32](repeating: 0, count: 64)
        for w in 0..<64 {
            let off = 256 - 4 * (w + 1)
            let b0 = UInt32(n[off]) << 24
            let b1 = UInt32(n[off + 1]) << 16
            let b2 = UInt32(n[off + 2]) << 8
            let b3 = UInt32(n[off + 3])
            words[w] = b0 | b1 | b2 | b3
        }

        // n0inv = -(n^-1) mod 2^32（牛顿迭代）
        let x = words[0]
        var inv = x
        for _ in 0..<5 { inv = inv &* (2 &- x &* inv) }
        let n0inv = 0 &- inv

        // rr = 2^4096 mod n（连续 4096 次“翻倍后取模”）
        var r = [UInt32](repeating: 0, count: 64)
        r[0] = 1
        for _ in 0..<4096 {
            var carry: UInt32 = 0
            for k in 0..<64 {
                let next = r[k] >> 31
                r[k] = (r[k] << 1) | carry
                carry = next
            }
            if carry != 0 || geq(r, words) {
                var borrow: UInt64 = 0
                for k in 0..<64 {
                    let diff = UInt64(r[k]) &- UInt64(words[k]) &- borrow
                    r[k] = UInt32(truncatingIfNeeded: diff)
                    borrow = (diff >> 63) & 1
                }
            }
        }

        var out = Data()
        func put(_ v: UInt32) {
            out.append(contentsOf: [
                UInt8(v & 0xff), UInt8((v >> 8) & 0xff),
                UInt8((v >> 16) & 0xff), UInt8((v >> 24) & 0xff)
            ])
        }
        put(64)
        put(n0inv)
        words.forEach(put)
        r.forEach(put)
        put(e)

        var payload = Data((out.base64EncodedString() + " ADBTerm@iOS").utf8)
        payload.append(0)
        return payload
    }

    private static func geq(_ a: [UInt32], _ b: [UInt32]) -> Bool {
        var k = a.count - 1
        while k >= 0 {
            if a[k] != b[k] { return a[k] > b[k] }
            k -= 1
        }
        return true
    }
}
