// DeltaVision A机 App —— 两种推流模式
// 模式1(推荐): 扩展推流, 调起系统广播选择器选 StreamExt, 后台稳定
// 模式2(备选): 应用内推流, 免扩展, TrollStore 下扩展不被系统识别时用这个
// v3: 握手确认后再发帧(ping-pong) + 丢帧式发送队列 + 延迟重连, 修"一帧就断"
import SwiftUI
import ReplayKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

@main
struct DeltaVisionApp: App {
    var body: some Scene { WindowGroup { ContentView() } }
}

struct ContentView: View {
    @State private var msg = "选择一种模式开始推流"
    @State private var urlInput = UserDefaults.standard.string(forKey: "relayURL")
        ?? "ws://192.168.118.237:8900/stream?role=streamer"
    var body: some View {
        VStack(spacing: 16) {
            Text("Delta Vision A机").font(.title2).padding(.top, 30)
            Text("中继地址(改完自动保存):").font(.footnote)
            TextField("ws://IP:8900/stream?role=streamer", text: $urlInput)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 30)
                .onChange(of: urlInput) { newV in
                    UserDefaults.standard.set(newV, forKey: "relayURL")
                }
            Text(msg).font(.footnote).foregroundColor(.secondary)
                .multilineTextAlignment(.center).padding(.horizontal, 30)
            Button("模式1 · 扩展推流") {
                RPScreenRecorder.shared().startRecording { err in
                    msg = err == nil ? "已启动, 切到游戏" : "启动失败: \(err!.localizedDescription)"
                }
            }.buttonStyle(PrimaryBtn())
            Button("模式2 · 应用内推流") {
                msg = "应用内推流中(需在系统弹窗点允许), 切到游戏即可"
                InAppStreamer.shared.start()
            }.buttonStyle(PrimaryBtn())
            Button("停止") {
                RPScreenRecorder.shared().stopRecording { _, _ in }
                InAppStreamer.shared.stop()
                msg = "已停止"
            }.buttonStyle(PrimaryBtn())
            Spacer()
        }
        .onAppear { InAppStreamer.onStatus = { msg = $0 } }
    }
}

struct PrimaryBtn: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.padding(12).frame(minWidth: 220)
            .background(Color.blue.opacity(configuration.isPressed ? 0.6 : 1))
            .foregroundColor(.white).cornerRadius(10)
    }
}

// ---- 模式2: 应用内录屏推流(免扩展) ----
final class InAppStreamer: NSObject {
    static let shared = InAppStreamer()
    static var onStatus: ((String) -> Void)?   // 界面上的状态回显
    // 地址可在 App 界面直接改(存 UserDefaults), 换网络不用重新构建
    private static let defaultURL = "ws://192.168.118.237:8900/stream?role=streamer"
    private var url: URL {
        let s = UserDefaults.standard.string(forKey: "relayURL") ?? InAppStreamer.defaultURL
        return URL(string: s) ?? URL(string: InAppStreamer.defaultURL)!
    }
    private var task: URLSessionWebSocketTask?
    private var session: URLSession?
    private let queue = DispatchQueue(label: "inapp.net", qos: .userInitiated)
    private var n = 0
    private var running = false
    private var connected = false      // 收到服务器 hello 后才为 true
    private var pending: Data?         // 丢帧式: 只留最新一帧
    private var sending = false
    private var reconnectTimer: DispatchWorkItem?
    private var helloFallback: DispatchWorkItem?

    func start() {
        if running { return }
        running = true
        session = URLSession(configuration: .default)
        connect()
        RPScreenRecorder.shared().startCapture(handler: { [weak self] buf, type, _ in
            guard type == .video, let self,
                  let jpeg = self.jpeg(from: buf, scale: 0.4, quality: 0.5) else { return }
            self.queue.async { self.enqueue(jpeg) }
            self.n += 1
            if self.n % 300 == 0 { print("[InApp] 已编码 \(self.n) 帧") }
        }, completionHandler: { err in
            if let err { print("[InApp] startCapture 失败: \(err)") }
        })
    }

    // 握手确认: 等服务端 hello 消息(不用 sendPing, iOS 16 上兼容性差); 3 秒兜底
    private func connect() {
        guard running else { return }
        task?.cancel(with: .goingAway, reason: nil)
        guard let session else { return }
        connected = false
        task = session.webSocketTask(with: url)
        task?.resume()
        waitHello()
        helloFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.connected, self.running else { return }
            self.queue.async {   // 3 秒没收到 hello 也开推, 发帧失败会走重连
                self.connected = true
                self.drain()
            }
        }
        helloFallback = work
        queue.asyncAfter(deadline: .now() + 3, execute: work)
    }

    private func waitHello() {
        guard let task, task === self.task else { return }
        task.receive { [weak self] result in
            guard let self, self.task === task, self.running else { return }
            switch result {
            case .success(let msg):
                if case .string(let s) = msg, s.contains("hello") {
                    self.helloFallback?.cancel()
                    self.queue.async {
                        self.connected = true
                        DispatchQueue.main.async {
                            InAppStreamer.onStatus?("✅ 已连上中继, 推流中(切到游戏)")
                        }
                        self.drain()
                    }
                } else {
                    self.waitHello()   // stats 等其他消息, 继续等 hello
                }
            case .failure(let err):
                print("[InApp] 连接失败: \(err.localizedDescription.prefix(80))")
                self.connected = false
                DispatchQueue.main.async {
                    InAppStreamer.onStatus?("❌ 连不上中继\n1.确认 iPhone 与中继同一网络\n2.设置→隐私与安全→本地网络→允许本App\n3.检查上面填的地址")
                }
                self.scheduleReconnect()
            }
        }
    }

    private func enqueue(_ data: Data) {
        pending = data   // 帧比网速快时丢旧帧, 不发积压
        drain()
    }

    private func drain() {
        guard connected, !sending, let data = pending else { return }
        pending = nil
        sending = true
        task?.send(.data(data)) { [weak self] err in
            guard let self else { return }
            self.sending = false
            if let err {
                self.connected = false
                print("[InApp] 发送失败: \(err.localizedDescription.prefix(60))")
                DispatchQueue.main.async { InAppStreamer.onStatus?("⚠️ 与中继断开, 重连中…") }
                self.scheduleReconnect()
            } else {
                self.queue.async { self.drain() }
            }
        }
    }

    private func scheduleReconnect() {
        reconnectTimer?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.connect() }
        reconnectTimer = work
        queue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    func stop() {
        running = false
        RPScreenRecorder.shared().stopCapture { _ in }
        reconnectTimer?.cancel()
        helloFallback?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }

    private func jpeg(from buffer: CMSampleBuffer, scale: CGFloat, quality: CGFloat) -> Data? {
        guard let pb = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let ci = CIImage(cvPixelBuffer: pb).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        guard let cg = CIContext().createCGImage(ci, from: ci.extent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
