import SwiftUI

struct ContentView: View {
    @StateObject private var adb = ADBClient()
    @AppStorage("adb.host") private var host = ""
    @AppStorage("adb.port") private var port = "5555"
    @State private var input = ""

    private let quick = [
        "getprop ro.product.model",
        "getprop ro.build.version.release",
        "pm list packages -3",
        "dumpsys battery",
        "screencap -p /sdcard/s.png"
    ]

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                TextField("设备 IP", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numbersAndPunctuation)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                TextField("端口", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.numberPad)
                    .frame(width: 70)
                Button(adb.connected ? "断开" : "连接") {
                    if adb.connected {
                        adb.disconnect()
                    } else {
                        adb.connect(host: host.trimmingCharacters(in: .whitespaces), port: port)
                    }
                }
                .buttonStyle(.borderedProminent)
            }

            Text(adb.status)
                .font(.caption)
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)

            ScrollViewReader { proxy in
                ScrollView {
                    Text(adb.output)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .textSelection(.enabled)
                    Color.clear.frame(height: 1).id("bottom")
                }
                .padding(6)
                .background(Color(.secondarySystemBackground))
                .cornerRadius(8)
                .onChange(of: adb.output) { _ in
                    proxy.scrollTo("bottom", anchor: .bottom)
                }
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack {
                    ForEach(quick, id: \.self) { cmd in
                        Button(cmd) { adb.sendLine(cmd) }
                            .font(.caption)
                            .buttonStyle(.bordered)
                    }
                    Button("清屏") { adb.clearOutput() }
                        .font(.caption)
                        .buttonStyle(.bordered)
                }
            }

            HStack {
                TextField("输入 shell 命令", text: $input)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
                    .textInputAutocapitalization(.never)
                    .onSubmit(send)
                Button("发送", action: send)
                    .buttonStyle(.borderedProminent)
                    .disabled(!adb.connected)
            }
        }
        .padding()
    }

    private func send() {
        guard !input.isEmpty else { return }
        adb.sendLine(input)
        input = ""
    }
}
