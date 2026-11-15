import Foundation
import AVFoundation
import CoreMedia
import UIKit

// MARK: - 大端读写

extension Data {
    mutating func appendBE16(_ v: UInt16) {
        append(UInt8(v >> 8))
        append(UInt8(v & 0xff))
    }

    mutating func appendBE32(_ v: UInt32) {
        append(UInt8((v >> 24) & 0xff))
        append(UInt8((v >> 16) & 0xff))
        append(UInt8((v >> 8) & 0xff))
        append(UInt8(v & 0xff))
    }

    mutating func appendBE64(_ v: UInt64) {
        appendBE32(UInt32(v >> 32))
        appendBE32(UInt32(v & 0xffff_ffff))
    }

    func be32(_ off: Int) -> UInt32 {
        let b = startIndex + off
        let a0 = UInt32(self[b]) << 24
        let a1 = UInt32(self[b + 1]) << 16
        let a2 = UInt32(self[b + 2]) << 8
        let a3 = UInt32(self[b + 3])
        return a0 | a1 | a2 | a3
    }

    func be64(_ off: Int) -> UInt64 {
        (UInt64(be32(off)) << 32) | UInt64(be32(off + 4))
    }
}

// MARK: - 视频流解析（scrcpy 4.0，forward 隧道）

/// 顺序：1 字节 dummy → 64 字节设备名 → 4 字节编码 ID →
/// 若干个 12 字节头（会话包 / 媒体包）+ 负载。
final class VideoParser {
    private var buf = Data()
    private var stage = 0
    private var payloadSize = 0
    private var payloadIsConfig = false
    private var payloadPTS: Int64 = 0

    var onSession: ((Int, Int) -> Void)?
    var onPacket: ((Data, Bool, Int64) -> Void)?
    var onError: ((String) -> Void)?

    func feed(_ d: Data) {
        buf.append(d)
        while true {
            switch stage {
            case 0:
                guard buf.count >= 1 else { return }
                buf.removeFirst(1)
                stage = 1
            case 1:
                guard buf.count >= 64 else { return }
                buf.removeFirst(64)
                stage = 2
            case 2:
                guard buf.count >= 4 else { return }
                let codec = buf.be32(0)
                buf.removeFirst(4)
                if codec != 0x6832_3634 {
                    onError?("设备返回的不是 H.264 视频流")
                    return
                }
                stage = 3
            case 3:
                guard buf.count >= 12 else { return }
                let first = buf[buf.startIndex]
                if first & 0x80 != 0 {
                    let w = Int(buf.be32(4))
                    let h = Int(buf.be32(8))
                    buf.removeFirst(12)
                    onSession?(w, h)
                } else {
                    let raw = buf.be64(0)
                    payloadIsConfig = (raw >> 62) & 1 == 1
                    payloadPTS = Int64(raw & 0x1fff_ffff_ffff_ffff)
                    payloadSize = Int(buf.be32(8))
                    buf.removeFirst(12)
                    guard payloadSize < 8 * 1024 * 1024 else {
                        onError?("视频数据异常")
                        return
                    }
                    stage = 4
                }
            default:
                guard buf.count >= payloadSize else { return }
                let p = Data(buf.prefix(payloadSize))
                buf.removeFirst(payloadSize)
                onPacket?(p, payloadIsConfig, payloadPTS)
                stage = 3
            }
        }
    }
}

// MARK: - H.264 渲染（Annex B → AVCC → AVSampleBufferDisplayLayer）

final class H264Renderer {
    let layer = AVSampleBufferDisplayLayer()
    private var format: CMVideoFormatDescription?

    init() {
        layer.videoGravity = .resizeAspect
        layer.backgroundColor = UIColor.black.cgColor
    }

    func flush() {
        layer.flushAndRemoveImage()
        format = nil
    }

    static func nalUnits(_ b: [UInt8]) -> [ArraySlice<UInt8>] {
        var starts: [(code: Int, nal: Int)] = []
        var i = 0
        while i + 3 <= b.count {
            if b[i] == 0 && b[i + 1] == 0 {
                if b[i + 2] == 1 {
                    starts.append((i, i + 3))
                    i += 3
                    continue
                }
                if i + 4 <= b.count && b[i + 2] == 0 && b[i + 3] == 1 {
                    starts.append((i, i + 4))
                    i += 4
                    continue
                }
            }
            i += 1
        }
        var out: [ArraySlice<UInt8>] = []
        for (k, s) in starts.enumerated() {
            let end = k + 1 < starts.count ? starts[k + 1].code : b.count
            if s.nal < end { out.append(b[s.nal..<end]) }
        }
        return out
    }

    /// 配置包：包含 SPS + PPS。
    func configure(_ annexB: Data) {
        var sps: [UInt8]?
        var pps: [UInt8]?
        for nal in Self.nalUnits([UInt8](annexB)) {
            guard let h = nal.first else { continue }
            switch h & 0x1f {
            case 7: sps = Array(nal)
            case 8: pps = Array(nal)
            default: break
            }
        }
        guard let s = sps, let p = pps else { return }
        var fd: CMVideoFormatDescription?
        let status: OSStatus = s.withUnsafeBufferPointer { sp in
            p.withUnsafeBufferPointer { pp in
                let ptrs: [UnsafePointer<UInt8>] = [sp.baseAddress!, pp.baseAddress!]
                let sizes: [Int] = [s.count, p.count]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault,
                    parameterSetCount: 2,
                    parameterSetPointers: ptrs,
                    parameterSetSizes: sizes,
                    nalUnitHeaderLength: 4,
                    formatDescriptionOut: &fd
                )
            }
        }
        if status == noErr { format = fd }
    }

    func enqueue(_ annexB: Data, pts: Int64) {
        guard let fmt = format else { return }
        var avcc = Data()
        for nal in Self.nalUnits([UInt8](annexB)) {
            guard let h = nal.first else { continue }
            let t = h & 0x1f
            if t == 7 || t == 8 || t == 9 { continue }
            var len = UInt32(nal.count).bigEndian
            withUnsafeBytes(of: &len) { avcc.append(contentsOf: $0) }
            avcc.append(contentsOf: nal)
        }
        guard !avcc.isEmpty else { return }

        var block: CMBlockBuffer?
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: avcc.count,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
            offsetToData: 0, dataLength: avcc.count, flags: 0, blockBufferOut: &block)
        guard created == kCMBlockBufferNoErr, let blk = block else { return }
        let copied = avcc.withUnsafeBytes { raw -> OSStatus in
            CMBlockBufferReplaceDataBytes(with: raw.baseAddress!, blockBuffer: blk,
                                          offsetIntoDestination: 0, dataLength: avcc.count)
        }
        guard copied == kCMBlockBufferNoErr else { return }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: pts, timescale: 1_000_000),
            decodeTimeStamp: .invalid)
        var size = avcc.count
        var sample: CMSampleBuffer?
        let made = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blk, formatDescription: fmt,
            sampleCount: 1, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard made == noErr, let sb = sample else { return }

        if let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
           CFArrayGetCount(arr) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if layer.status == .failed { layer.flush() }
        layer.enqueue(sb)
    }
}

// MARK: - 镜像控制器

@MainActor
final class MirrorClient: ObservableObject {
    @Published var status = "未启动"
    @Published var running = false
    @Published var videoSize = CGSize.zero
    @Published var quality = 1 {
        didSet { UserDefaults.standard.set(quality, forKey: "mirror.quality") }
    }
    /// 码率（Mbps），对应 scrcpy 的 video_bit_rate
    @Published var bitrateMbps: Double = 4 {
        didSet { UserDefaults.standard.set(bitrateMbps, forKey: "mirror.bitrate") }
    }
    /// 最大帧率，对应 max_fps
    @Published var fps: Int = 30 {
        didSet { UserDefaults.standard.set(fps, forKey: "mirror.fps") }
    }
    /// 镜像时让设备熄屏，对应 turn_screen_off（省电，画面照常推送）
    @Published var turnScreenOff = false {
        didSet { UserDefaults.standard.set(turnScreenOff, forKey: "mirror.offscreen") }
    }
    /// 画面比例：0 等比完整显示，1 铺满裁切
    @Published var scaleMode: Int = 0 {
        didSet { UserDefaults.standard.set(scaleMode, forKey: "mirror.scale") }
    }

    let renderer = H264Renderer()

    private weak var adb: ADBClient?
    private var server: ADBStream?
    private var video: ADBStream?
    private var control: ADBStream?
    private var parser = VideoParser()
    private var serverLog = ""
    private var queue: [Data] = []
    private var draining = false
    private var gen = 0
    /// 视频流意外断开后自动重连的次数（成功连上后归零）
    private var retry = 0

    init() {
        let d = UserDefaults.standard
        if let saved = d.object(forKey: "mirror.quality") as? Int {
            quality = min(max(saved, 0), 2)
        }
        if let b = d.object(forKey: "mirror.bitrate") as? Double { bitrateMbps = min(max(b, 1), 16) }
        if let f = d.object(forKey: "mirror.fps") as? Int { fps = f == 60 ? 60 : 30 }
        turnScreenOff = d.bool(forKey: "mirror.offscreen")
        scaleMode = (d.object(forKey: "mirror.scale") as? Int ?? 0) == 1 ? 1 : 0
    }

    private let qualities: [(maxSize: Int, bitrate: Int)] = [
        (720, 2_000_000), (1280, 4_000_000), (1920, 8_000_000)
    ]

    func start(adb: ADBClient) async {
        guard !running else { return }
        guard adb.connected else { status = "请先连接设备"; return }
        guard let url = Bundle.main.url(forResource: "scrcpy-server", withExtension: "jar"),
              let jar = try? Data(contentsOf: url) else {
            status = "App 内缺少 scrcpy-server.jar（编译时下载失败）"
            return
        }
        self.adb = adb
        running = true
        gen += 1
        let my = gen
        serverLog = ""
        videoSize = .zero
        queue.removeAll()
        draining = false
        renderer.flush()
        parser = VideoParser()
        parser.onSession = { [weak self] w, h in
            self?.videoSize = CGSize(width: w, height: h)
            self?.status = "镜像中 \(w)×\(h)"
        }
        parser.onPacket = { [weak self] data, isConfig, pts in
            if isConfig { self?.renderer.configure(data) } else { self?.renderer.enqueue(data, pts: pts) }
        }
        parser.onError = { [weak self] msg in self?.fail(msg) }

        status = "上传服务端…"
        let remote = "/data/local/tmp/scrcpy-server.jar"
        let ok = await adb.push(jar, to: remote) { _ in }
        guard alive(my) else { return }
        guard ok else { fail("上传 scrcpy-server 失败"); return }

        status = "启动服务端…"
        let scid = String(format: "%08x", UInt32.random(in: 1...0x7fff_ffff))
        let q = qualities[min(max(quality, 0), qualities.count - 1)]
        let rate = Int(min(max(bitrateMbps, 1), 16) * 1_000_000)
        let maxFps = fps == 60 ? 60 : 30
        let cmd = "CLASSPATH=\(remote) app_process / com.genymobile.scrcpy.Server 4.0"
            + " scid=\(scid) log_level=info audio=false tunnel_forward=true cleanup=false"
            + " max_size=\(q.maxSize) video_bit_rate=\(rate) max_fps=\(maxFps)"
            + (turnScreenOff ? " turn_screen_off=true" : "")
        server = await adb.open("shell:" + cmd, onData: { [weak self] d in
            self?.appendLog(d)
        }, onClose: { [weak self] in
            self?.serverExited()
        })
        guard alive(my) else { return }
        guard server != nil else { fail("无法启动服务端"); return }

        status = "连接视频流…"
        let socket = "localabstract:scrcpy_\(scid)"
        for _ in 0..<30 {
            video = await adb.open(socket, onData: { [weak self] d in self?.parser.feed(d) })
            guard alive(my) else { return }
            if video != nil { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard alive(my) else { return }
        }
        guard let v = video else {
            fail("连接 scrcpy 失败：" + lastLog())
            return
        }
        v.onClose = { [weak self] in
            guard let self = self, self.running else { return }
            self.fail("视频流已断开：" + self.lastLog())
        }

        for _ in 0..<10 {
            control = await adb.open(socket, onData: { _ in })
            guard alive(my) else { return }
            if control != nil { break }
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard alive(my) else { return }
        }
        if control == nil { status = "已连接视频，但控制通道失败（只能看，不能操作）" }
        retry = 0
    }

    func stop() {
        guard running else { return }
        teardown()
        status = "已停止"
    }

    private func alive(_ g: Int) -> Bool { running && gen == g }

    private func fail(_ msg: String) {
        teardown()
        status = msg
        // 视频流掉线时自动重试一次；ADB 本身断开则不重试，交给 ADBClient 的重连
        guard retry < 1, let a = adb, a.connected else { return }
        retry += 1
        status = msg + "，正在重连…"
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let self = self, !self.running else { return }
            await self.start(adb: a)
        }
    }

    private func teardown() {
        running = false
        gen += 1
        for s in [control, video, server] {
            if let s = s {
                s.onClose = nil
                adb?.closeStream(s)
            }
        }
        control = nil
        video = nil
        server = nil
        queue.removeAll()
        draining = false
        videoSize = .zero
        renderer.flush()
    }

    private func serverExited() {
        guard running else { return }
        fail("服务端已退出：" + lastLog())
    }

    private func appendLog(_ d: Data) {
        serverLog += String(decoding: d, as: UTF8.self).replacingOccurrences(of: "\r", with: "")
        if serverLog.count > 2000 { serverLog = String(serverLog.suffix(1500)) }
    }

    private func lastLog() -> String {
        let line = serverLog.split(whereSeparator: \.isNewline).last.map(String.init) ?? ""
        return line.isEmpty ? "（无输出）" : line
    }

    // MARK: 控制消息

    private func send(_ d: Data) {
        guard running, control != nil else { return }
        queue.append(d)
        guard !draining else { return }
        draining = true
        Task {
            while !queue.isEmpty, let c = control {
                var batch = Data()
                for m in queue { batch.append(m) }
                queue.removeAll()
                await c.write(batch)
            }
            draining = false
        }
    }

    /// action: 0 按下，1 抬起，2 移动。x、y 为视频帧像素坐标。
    func touch(action: UInt8, id: Int, x: Int, y: Int) {
        let w = Int(videoSize.width)
        let h = Int(videoSize.height)
        guard w > 0, h > 0, w < 65536, h < 65536 else { return }
        var d = Data([2, action])
        d.appendBE64(UInt64(bitPattern: Int64(id)))
        d.appendBE32(UInt32(max(0, min(x, w - 1))))
        d.appendBE32(UInt32(max(0, min(y, h - 1))))
        d.appendBE16(UInt16(w))
        d.appendBE16(UInt16(h))
        d.appendBE16(action == 1 ? 0 : 0xffff)
        d.appendBE32(0)
        d.appendBE32(0)
        send(d)
    }

    func key(_ keycode: UInt32) {
        for action in [UInt8(0), UInt8(1)] {
            var d = Data([0, action])
            d.appendBE32(keycode)
            d.appendBE32(0)
            d.appendBE32(0)
            send(d)
        }
    }

    // MARK: 扩展控制（对应甲壳虫“远程控制”里的旋屏、通知栏、熄屏、文字输入）

    /// 旋转设备（控制消息 type 11，scrcpy 2.x 起支持）
    func rotateDevice() { send(Data([11])) }

    /// 展开通知栏 / 快捷设置面板（type 5 / 6）
    func openNotificationPanel() { send(Data([5])) }
    func openSettingsPanel() { send(Data([6])) }

    /// 屏幕电源：mode 0 熄灭，1 正常（type 10 + mode）
    func screenPower(_ on: Bool) {
        var d = Data([10])
        d.append(on ? 1 : 0)
        send(d)
    }

    /// 文本注入：把一段文字直接打进设备当前焦点输入框（type 1 + UTF-8）
    func injectText(_ text: String) {
        let s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return }
        var d = Data([1])
        d.append(contentsOf: Array(s.utf8))
        send(d)
    }

    func volume(up: Bool) { key(up ? 24 : 25) }
}
