// iOS 真机推流骨架 —— Broadcast Upload Extension
// 作用: 用系统录屏(ReplayKit)抓游戏画面, 每帧压 JPEG, 走 WS 推到中继服务
// 免越狱、不碰游戏进程, 全设备通用(游戏机为 iPad/iPhone 均可)
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

    // ===== 改成你的中继地址 =====
    // 副机是电脑: 填电脑局域网IP(如 ws://192.168.1.x:8900/stream?role=streamer)
    // 副机是这台手机: 填手机局域网IP(当前 192.168.0.254)
    // 两地跨网: 填 VPS 公网IP/域名
    private let serverURL = URL(string: "ws://192.168.0.254:8900/stream?role=streamer")!

    override func broadcastStarted(withSetupInfo setupInfo: [String: NSObject]?) {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = 600
        session = URLSession(configuration: config)
        task = session?.webSocketTask(with: serverURL)
        task?.resume()
    }

    override func processSampleBuffer(_ sampleBuffer: CMSampleBuffer,
                                      with sampleBufferType: RPSampleBufferType) {
        guard sampleBufferType == .video,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // 压到 0.4x 尺寸降带宽: 处理小图再放大像素, 识别够用
        guard let jpeg = jpegData(from: pixelBuffer, scale: 0.4, quality: 0.5) else { return }
        queue.async { [weak self] in
            self?.task?.send(.data(jpeg)) { _ in }
        }
        frameCount += 1
        if frameCount % 300 == 0 {
            print("[StreamExt] 已推 \(frameCount) 帧")
        }
    }

    override func broadcastFinished() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        session = nil
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
