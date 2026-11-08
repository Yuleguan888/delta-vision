// iOS 真机推流骨架 —— Broadcast Upload Extension
// 作用: 用系统录屏(ReplayKit)抓游戏画面, 每帧压 JPEG, 走 WS 推到中继服务
// 免越狱、不碰游戏进程, 全设备通用(游戏机为 iPad/iPhone 均可)
// v3: ping-pong 握手确认 + 丢帧式发送, 修"一帧就断"
//
// 集成步骤(需 Mac + Xcode + Apple 开发者账号):
// 1. Xcode 新建 iOS App 项目
// 2. File -> New -> Target -> Broadcast Upload Extension, 命名为 StreamExt
// 3. 把本文件替换 StreamExt/SampleHandler.swift
// 4. 改下方 serverURL 为中继服务器地址(电脑/服务器局域网IP)
// 5. 真机签名运行 App -> 控制中心长按"屏幕录制" -> 选 StreamExt -> 开始直播
// 6. B机浏览器打开 http://<中继IP>:8900/ 即可看到画面和红点
//
// 扩展 Info.plist 关键项(新建 Target 时自动生成, 确认即可):
//   NSExtensionPointIdentifier = com.apple.broadcast-services-upload
//   RPBroadcastProcessMode = RPBroadcastProcessModeSampleBuffer

import ReplayKit
import CoreImage
import ImageIO
import UniformTypeIdentifiers

class SampleHandler: RPBroadcastSampleHandler {

    private var session: URLSession?
    private var task: URLSessionWebSocketTask?
    private var queue = DispatchQueue(label: "stream.send", qos: .userInitiated)
    private var frameCount = 0
    private var connected = false
    private var pending: Data?
    private var sending = false
    private var reconnectTimer: DispatchWorkItem?
    private var helloFallback: DispatchWorkItem?

    // ===== 改成你的中继地址 =====
    private let serverURL = URL(string: "ws://192.168.118.237:8900/stream?role=streamer")!

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
        connect()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let jpeg = jpegData(from: pixelBuffer, scale: 0.4, quality: 0.5) else { return }
        queue.async { [weak self] in self?.enqueue(jpeg) }
        frameCount += 1
        if frameCount % 300 == 0 { print("[StreamExt] 已编码 \(frameCount) 帧") }
    }

    override func broadcastFinished() {
        reconnectTimer?.cancel()
        helloFallback?.cancel()
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
    }

    // ---- 与服务端 hello 确认握手 + 丢帧式发送 ----
    private func connect() {
        task?.cancel(with: .goingAway, reason: nil)
        guard let session else { return }
        connected = false
        task = session.webSocketTask(with: serverURL)
        task?.resume()
        waitHello()
        helloFallback?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.connected else { return }
            self.queue.async {
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
            guard let self, self.task === task else { return }
            switch result {
            case .success(let msg):
                if case .string(let s) = msg, s.contains("hello"), !self.connected {
                    self.helloFallback?.cancel()
                    self.queue.async {
                        self.connected = true
                        self.drain()
                    }
                }
                self.waitHello()   // 持续消费消息, 防止积压
            case .failure(let err):
                print("[StreamExt] 连接断开: \(err.localizedDescription.prefix(80))")
                self.connected = false
                self.scheduleReconnect()
            }
        }
    }

    private func enqueue(_ data: Data) {
        pending = data
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
                print("[StreamExt] 发送失败: \(err.localizedDescription.prefix(60))")
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

    // CVPixelBuffer -> 缩放 -> JPEG
    private func jpegData(from pixelBuffer: CVPixelBuffer,
                          scale: CGFloat, quality: CGFloat) -> Data? {
        let ci = CIImage(cvPixelBuffer: pixelBuffer)
        let scaled = ci.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let ctx = CIContext(options: [.useSoftwareRenderer: false])
        guard let cg = ctx.createCGImage(scaled, from: scaled.extent) else { return nil }
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, [
            kCGImageDestinationLossyCompressionQuality: quality
        ] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }
}
