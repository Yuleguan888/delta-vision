// DeltaVision A机 App —— 两种推流模式
// 模式1(推荐): 扩展推流, 调起系统广播选择器选 StreamExt, 后台稳定
// 模式2(备选): 应用内推流, 免扩展, TrollStore 下扩展不被系统识别时用这个
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
    var body: some View {
        VStack(spacing: 22) {
            Text("Delta Vision A机").font(.title2).padding(.top, 40)
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
                RPScreenRecorder.shared().stopRecording { _ in }
                InAppStreamer.shared.stop()
                msg = "已停止"
            }.buttonStyle(PrimaryBtn())
            Spacer()
        }
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
    // ===== 改成你的中继地址 =====
    private let url = URL(string: "ws://192.168.0.254:8900/stream?role=streamer")!
    private var task: URLSessionWebSocketTask?
    private let queue = DispatchQueue(label: "inapp.send", qos: .userInitiated)
    private var n = 0

    func start() {
        let s = URLSession(configuration: .default)
        task = s.webSocketTask(with: url)
        task?.resume()
        RPScreenRecorder.shared().startCapture(handler: { [weak self] buf, type, _ in
            guard type == .video, let self,
                  let jpeg = self.jpeg(from: buf, scale: 0.4, quality: 0.5) else { return }
            self.queue.async {
                self.task?.send(.data(jpeg)) { _ in }
            }
            self.n += 1
            if self.n % 300 == 0 { print("[InApp] 已推 \(self.n) 帧") }
        }, completionHandler: { err in
            if let err { print("[InApp] startCapture 失败: \(err)") }
        })
    }

    func stop() {
        RPScreenRecorder.shared().stopCapture { _ in }
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
