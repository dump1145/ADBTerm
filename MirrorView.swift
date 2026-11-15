import SwiftUI
import UIKit

final class MirrorUIView: UIView {
    weak var mirror: MirrorClient?
    private var ids: [ObjectIdentifier: Int] = [:]

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        backgroundColor = .black
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func attach(_ layer: CALayer) {
        layer.frame = bounds
        self.layer.addSublayer(layer)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        for l in layer.sublayers ?? [] { l.frame = bounds }
    }

    /// 触摸点 → 视频帧像素坐标（视频按等比缩放居中显示）。
    private func map(_ p: CGPoint) -> (Int, Int)? {
        guard let size = mirror?.videoSize, size.width > 0, size.height > 0,
              bounds.width > 0, bounds.height > 0 else { return nil }
        let fit = min(bounds.width / size.width, bounds.height / size.height)
        let fill = max(bounds.width / size.width, bounds.height / size.height)
        let scale = (mirror?.scaleMode == 1) ? fill : fit
        let vw = size.width * scale
        let vh = size.height * scale
        let ox = (bounds.width - vw) / 2
        let oy = (bounds.height - vh) / 2
        let x = (p.x - ox) / scale
        let y = (p.y - oy) / scale
        return (Int(x.rounded()), Int(y.rounded()))
    }

    private func nextId() -> Int {
        var i = 0
        while ids.values.contains(i) { i += 1 }
        return i
    }

    private func emit(_ action: UInt8, _ t: UITouch, id: Int) {
        guard let (x, y) = map(t.location(in: self)) else { return }
        mirror?.touch(action: action, id: id, x: x, y: y)
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            let id = nextId()
            ids[ObjectIdentifier(t)] = id
            emit(0, t, id: id)
        }
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if let id = ids[ObjectIdentifier(t)] { emit(2, t, id: id) }
        }
    }

    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?) {
        for t in touches {
            if let id = ids.removeValue(forKey: ObjectIdentifier(t)) { emit(1, t, id: id) }
        }
    }

    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?) {
        touchesEnded(touches, with: event)
    }
}

struct MirrorSurface: UIViewRepresentable {
    @ObservedObject var mirror: MirrorClient

    func makeUIView(context: Context) -> MirrorUIView {
        let v = MirrorUIView()
        v.mirror = mirror
        v.attach(mirror.renderer.layer)
        return v
    }

    func updateUIView(_ uiView: MirrorUIView, context: Context) {
        uiView.mirror = mirror
    }
}


struct MirrorView: View {
    @ObservedObject var adb: ADBClient
    @ObservedObject var mirror: MirrorClient

    @State private var immersive = false
    @State private var showOptions = false
    @State private var textDraft = ""

    var body: some View {
        VStack(spacing: 8) {
            if !immersive {
                topBar
            }

            MirrorSurface(mirror: mirror)
                .background(Color.black)
                .cornerRadius(immersive ? 0 : 12)
                .overlay(alignment: .topTrailing) {
                    if immersive {
                        Button {
                            immersive = false
                        } label: {
                            Image(systemName: "arrow.down.right.and.arrow.up.left")
                                .padding(10)
                                .background(.black.opacity(0.55))
                                .foregroundColor(.white)
                                .clipShape(Circle())
                        }
                        .padding(12)
                    }
                }

            if !immersive {
                controlBar
                keyBar
            }
        }
        .sheet(isPresented: $showOptions) {
            optionsSheet
        }
    }

    // MARK: - 顶部

    private var topBar: some View {
        HStack(spacing: 10) {
            Button(mirror.running ? "停止" : "开始镜像") {
                if mirror.running {
                    mirror.stop()
                } else {
                    Task { await mirror.start(adb: adb) }
                }
            }
            .buttonStyle(.borderedProminent)
            .tint(mirror.running ? .red : .green)
            .disabled(!adb.connected)

            Text(mirror.status)
                .font(.footnote)
                .foregroundColor(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                immersive = true
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
            }
            .disabled(!mirror.running)

            Button {
                showOptions = true
            } label: {
                Image(systemName: "slider.horizontal.3")
            }
        }
    }

    // MARK: - 控制条

    private var controlBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                chip("返回", "chevron.backward") { mirror.key(4) }
                chip("主页", "circle") { mirror.key(3) }
                chip("多任务", "square.on.square") { mirror.key(187) }
                chip("电源", "power") { mirror.key(26) }
                chip("旋转", "rotate.right") { mirror.rotateDevice() }
                chip("通知栏", "bell") { mirror.openNotificationPanel() }
                chip("快捷设置", "switch.2") { mirror.openSettingsPanel() }
                chip(mirror.turnScreenOff ? "亮屏" : "熄屏", "moon") {
                    mirror.turnScreenOff.toggle()
                    mirror.screenPower(!mirror.turnScreenOff)
                }
            }
        }
        .disabled(!mirror.running)
    }

    private var keyBar: some View {
        HStack(spacing: 8) {
            chip("音量-", "speaker.minus") { mirror.volume(up: false) }
            chip("音量+", "speaker.plus") { mirror.volume(up: true) }
            Button {
                showOptions = true
            } label: {
                Label("输入文字", systemImage: "keyboard")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(Color(.secondarySystemGroupedBackground))
                    .cornerRadius(10)
            }
        }
        .disabled(!mirror.running)
    }

    private func chip(_ title: String, _ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(10)
        }
    }

    // MARK: - 选项

    private var optionsSheet: some View {
        NavigationStack {
            Form {
                Section("画质") {
                    HStack {
                        Text("码率")
                        Slider(value: $mirror.bitrateMbps, in: 1...16, step: 1)
                        Text("\(Int(mirror.bitrateMbps)) Mbps")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 70, alignment: .trailing)
                    }
                    Picker("帧率", selection: $mirror.fps) {
                        Text("30 fps").tag(30)
                        Text("60 fps").tag(60)
                    }
                    Picker("分辨率上限", selection: $mirror.quality) {
                        Text("720p").tag(0)
                        Text("1280p").tag(1)
                        Text("1920p").tag(2)
                    }
                    Text("修改画质后需重新点“开始镜像”生效")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }

                Section("显示") {
                    Picker("画面比例", selection: $mirror.scaleMode) {
                        Text("等比完整").tag(0)
                        Text("铺满裁切").tag(1)
                    }
                    .pickerStyle(.segmented)
                    Toggle("镜像时让设备熄屏", isOn: $mirror.turnScreenOff)
                    if mirror.running {
                        Button(mirror.turnScreenOff ? "立即熄屏" : "立即亮屏") {
                            mirror.screenPower(!mirror.turnScreenOff)
                        }
                    }
                }

                Section("输入文字") {
                    TextField("要打进设备当前输入框的文字", text: $textDraft, axis: .vertical)
                        .lineLimit(3...6)
                    Button("发送到设备") {
                        mirror.injectText(textDraft)
                        textDraft = ""
                    }
                    .disabled(textDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } footer: {
                    Text("需设备已处于可输入状态（输入框已聚焦）；含中文时按 UTF-8 直接注入。")
                        .font(.footnote)
                }
            }
            .navigationTitle("镜像选项")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { showOptions = false }
                }
            }
        }
    }
}
