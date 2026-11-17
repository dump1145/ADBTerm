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
        let scale = min(bounds.width / size.width, bounds.height / size.height)
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
    @State private var showKeyboard = false

    var body: some View {
        ZStack(alignment: .topTrailing) {
            VStack(spacing: 8) {
                if !immersive { controlBar }
                MirrorSurface(mirror: mirror)
                    .background(Color.black)
                    .cornerRadius(immersive ? 0 : 12)
                if !immersive { keyPads }
            }
            if immersive {
                Button { immersive = false } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.white.opacity(0.85))
                        .padding(8)
                }
            }
        }
        .sheet(isPresented: $showKeyboard) { MirrorKeyboardSheet(mirror: mirror) }
    }

    // MARK: 顶部控制栏

    private var controlBar: some View {
        VStack(spacing: 8) {
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

                if mirror.running {
                    Button("重启") {
                        mirror.stop()
                        Task { await mirror.start(adb: adb) }
                    }
                    .buttonStyle(.bordered)
                    .disabled(!adb.connected)
                }

                Spacer()

                Button { showKeyboard = true } label: {
                    Image(systemName: "keyboard")
                }
                .buttonStyle(.bordered)
                .disabled(!mirror.running)

                Button { immersive = true } label: {
                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.bordered)
                .disabled(!mirror.running)
            }
            HStack(spacing: 10) {
                Picker("清晰度", selection: $mirror.quality) {
                    Text("流畅").tag(0)
                    Text("标准").tag(1)
                    Text("高清").tag(2)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 210)
                Text(mirror.status)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.secondarySystemGroupedBackground))
        .cornerRadius(12)
    }

    // MARK: 按键区

    private var keyPads: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    navButton("chevron.backward", "返回", 4)
                    navButton("circle", "主页", 3)
                    navButton("square.on.square", "多任务", 187)
                    navButton("power", "电源", 26)
                    navButton("line.3.horizontal", "菜单", 82)
                }
                HStack(spacing: 8) {
                    navButton("speaker.slash", "静音", 164)
                    navButton("speaker.wave.1", "音量-", 25)
                    navButton("speaker.wave.3", "音量+", 24)
                    navButton("magnifyingglass", "搜索", 84)
                    navButton("delete.left", "删除", 67)
                    Button { mirror.rotate() } label: {
                        Label("旋转", systemImage: "rotate.right")
                            .font(.subheadline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 10)
                            .background(Color(.secondarySystemGroupedBackground))
                            .cornerRadius(10)
                    }
                    .disabled(!mirror.running)
                }
            }
        }
    }

    private func navButton(_ icon: String, _ title: String, _ code: UInt32) -> some View {
        Button { mirror.key(code) } label: {
            Label(title, systemImage: icon)
                .font(.subheadline)
                .frame(width: 78)
                .padding(.vertical, 10)
                .background(Color(.secondarySystemGroupedBackground))
                .cornerRadius(10)
        }
        .disabled(!mirror.running)
    }
}

/// 远控键盘输入：发送文字到手机当前焦点输入框。
struct MirrorKeyboardSheet: View {
    @ObservedObject var mirror: MirrorClient
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("先在手机上点开要输入的输入框，再在这里输入并发送。单次最多 300 字节。")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextEditor(text: $text)
                    .font(.system(size: 16))
                    .frame(minHeight: 120)
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.3))
                    )
                HStack(spacing: 10) {
                    Button("发送回车") {
                        mirror.injectText(text)
                        mirror.key(66)
                        text = ""
                    }
                    .buttonStyle(.bordered)
                    Button("发送") {
                        mirror.injectText(text)
                        text = ""
                    }
                    .buttonStyle(.borderedProminent)
                    Spacer()
                }
                .disabled(!mirror.running)
                Spacer()
            }
            .padding(16)
            .navigationTitle("键盘输入")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
    }
}
