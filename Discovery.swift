import Foundation
import SwiftUI
import Darwin

/// 用 Bonjour 在局域网里找开了无线调试的 Android 设备。
/// 监听三类服务：配对端口、无线调试端口、传统 adb 端口。
struct DiscoveredDevice: Identifiable, Hashable {
    var id: String { "\(kind)|\(name)|\(host)|\(port)" }
    let name: String
    let host: String
    let port: Int
    /// "pairing" / "connect" / "legacy"
    let kind: String

    var kindText: String {
        switch kind {
        case "pairing": return "配对端口"
        case "connect": return "无线调试"
        default: return "ADB"
        }
    }

    /// 配对端口本身不能直接当 ADB 用，需要配对码换证书
    var usableWithoutPairing: Bool { kind != "pairing" }
}

final class ADBDiscovery: NSObject, ObservableObject {
    @Published var devices: [DiscoveredDevice] = []
    @Published var hint = ""
    @Published var scanning = false

    private var browsers: [NetServiceBrowser] = []
    private var resolving: [NetService] = []
    private var started = false
    private var stopWork: DispatchWorkItem?

    private static let types = [
        "_adb-tls-connect._tcp.",
        "_adb-tls-pairing._tcp.",
        "_adb._tcp.",
    ]

    func start() {
        if started { return }
        started = true
        scanning = true
        devices = []
        hint = "正在搜索局域网内的 Android 设备…"
        for type in Self.types {
            let b = NetServiceBrowser()
            b.delegate = self
            b.searchForServices(ofType: type, inDomain: "")
            browsers.append(b)
        }
        // 10 秒自动收手，省电也避免占着 mDNS
        let work = DispatchWorkItem { [weak self] in self?.stop() }
        stopWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: work)
    }

    func stop() {
        stopWork?.cancel()
        stopWork = nil
        browsers.forEach { $0.stop() }
        browsers = []
        resolving.forEach { $0.stop() }
        resolving = []
        started = false
        scanning = false
        hint = devices.isEmpty
            ? "没搜到设备。确认手机和 iPhone 在同一 Wi-Fi，且手机已打开无线调试。"
            : "无线调试端口可直接连接；配对端口需要配对码，本版暂不支持。"
    }

    private func upsert(_ d: DiscoveredDevice) {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let i = self.devices.firstIndex(where: { $0.id == d.id }) {
                self.devices[i] = d
            } else if !self.devices.contains(where: { $0.host == d.host && $0.port == d.port }) {
                self.devices.append(d)
            }
            self.hint = "找到 \(self.devices.count) 台设备，点一下填入地址。"
        }
    }

    private func ipv4String(_ data: Data) -> String? {
        var out = [CChar](repeating: 0, count: 64)
        let ok: Bool = data.withUnsafeBytes { (p: UnsafeRawBufferPointer) -> Bool in
            guard let base = p.baseAddress else { return false }
            let sa = base.assumingMemoryBound(to: sockaddr.self)
            let r = getnameinfo(sa, socklen_t(data.count), &out, socklen_t(out.count), nil, 0, NI_NUMERICHOST)
            return r == 0
        }
        guard ok else { return nil }
        let s = String(cString: out)
        return s.isEmpty ? nil : s
    }
}

extension ADBDiscovery: NetServiceBrowserDelegate, NetServiceDelegate {
    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        service.delegate = self
        resolving.append(service)
        service.resolve(withTimeout: 5)
    }

    func netServiceBrowserDidStopSearch(_ browser: NetServiceBrowser) {}

    func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        DispatchQueue.main.async { [weak self] in
            self?.hint = "搜索失败（本地网络权限或 Wi-Fi 状态异常）"
        }
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        guard sender.port > 0 else { return }
        var host = ""
        if let addrs = sender.addresses {
            for a in addrs {
                if let ip = self.ipv4String(a), !ip.isEmpty {
                    host = ip
                    break
                }
            }
        }
        if host.isEmpty, let h = sender.hostName {
            host = h.hasSuffix(".") ? String(h.dropLast()) : h
        }
        guard !host.isEmpty else { return }

        let type = sender.type
        let kind: String
        if type.contains("pairing") {
            kind = "pairing"
        } else if type.contains("connect") {
            kind = "connect"
        } else {
            kind = "legacy"
        }
        let name = sender.name.isEmpty ? host : sender.name
        upsert(DiscoveredDevice(name: name, host: host, port: sender.port, kind: kind))
    }

    func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        resolving.removeAll { $0 === sender }
    }
}

// MARK: - 扫描结果面板

struct DiscoverySheet: View {
    @ObservedObject var discovery: ADBDiscovery
    @Environment(\.dismiss) private var dismiss
    let onPick: (DiscoveredDevice) -> Void

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(discovery.devices) { d in
                        Button {
                            onPick(d)
                            dismiss()
                        } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(d.name).font(.body)
                                    Text("\(d.host):\(d.port)").font(.caption).foregroundColor(.secondary)
                                }
                                Spacer()
                                Text(d.kindText)
                                    .font(.caption2)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 3)
                                    .background(d.usableWithoutPairing
                                                ? Color.green.opacity(0.18)
                                                : Color.orange.opacity(0.18))
                                    .cornerRadius(6)
                            }
                        }
                        .disabled(!d.usableWithoutPairing)
                    }
                } footer: {
                    Text(discovery.hint).font(.footnote)
                }
            }
            .navigationTitle("扫描设备")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { discovery.stop(); dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(discovery.scanning ? "搜索中…" : "重新搜索") { discovery.stop(); discovery.start() }
                        .disabled(discovery.scanning)
                }
            }
            .overlay {
                if discovery.scanning && discovery.devices.isEmpty {
                    ProgressView("搜索中…")
                }
            }
        }
    }
}
