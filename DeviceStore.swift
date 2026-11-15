import Foundation

struct Device: Identifiable, Codable, Hashable {
    var id = UUID()
    var name = ""
    var host = ""
    var port = "5555"

    var title: String { name.isEmpty ? host : name }
}

@MainActor
final class DeviceStore: ObservableObject {
    @Published var devices: [Device] = [] {
        didSet { persist() }
    }
    @Published var selectedID: UUID? {
        didSet { UserDefaults.standard.set(selectedID?.uuidString, forKey: "adb.selected") }
    }

    init() {
        if let data = UserDefaults.standard.data(forKey: "adb.devices"),
           let list = try? JSONDecoder().decode([Device].self, from: data) {
            devices = list
        } else if let old = UserDefaults.standard.string(forKey: "adb.host"), !old.isEmpty {
            // 从 v1 迁移
            let port = UserDefaults.standard.string(forKey: "adb.port") ?? "5555"
            devices = [Device(name: "我的设备", host: old, port: port)]
        }
        if let s = UserDefaults.standard.string(forKey: "adb.selected"), let id = UUID(uuidString: s),
           devices.contains(where: { $0.id == id }) {
            selectedID = id
        } else {
            selectedID = devices.first?.id
        }
    }

    var selected: Device? { devices.first { $0.id == selectedID } }

    func save(_ d: Device) {
        if let i = devices.firstIndex(where: { $0.id == d.id }) {
            devices[i] = d
        } else {
            devices.append(d)
            selectedID = d.id
        }
    }

    func delete(_ d: Device) {
        devices.removeAll { $0.id == d.id }
        if selectedID == d.id { selectedID = devices.first?.id }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(devices) {
            UserDefaults.standard.set(data, forKey: "adb.devices")
        }
    }
}
