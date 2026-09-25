import AVFoundation
import CoreImage
import CoreVideo

/// 合成信号源:摄像头被系统层吊死时(远控守护独占/驱动挂起),用 demo pattern 走
/// 与真实摄像头完全相同的 pixelBuffer 交付路径,验证 app 全链路(预览/AI/拍照/录像)。
/// 真实摄像头恢复出帧后本源自动停用。
final class SyntheticCameraSource: NSObject {

    static let shared = SyntheticCameraSource()

    private var displayLink: DispatchSourceTimer?
    private let queue = DispatchQueue(label: "com.kinet.camera.synthetic")
    private var frameIndex = 0
    private let width = 1280
    private let height = 720
    /// PTS 挂墙钟:文件时长=真实录制时长(若用帧序号,实际出帧率低于30fps时时长会虚高)
    private var startWall: CFTimeInterval = 0
    var onPixelBuffer: ((CVPixelBuffer, CMTime) -> Void)?
    private(set) var isActive = false

    private var pool: CVPixelBufferPool?

    /// 全局亮度因子(AE Lock 闭环验证用:0.1-2.0,模拟场景光变化)
    var brightnessFactor: Double = 1.0 {
        didSet { brightnessFactor = max(0.1, min(2.0, brightnessFactor)) }
    }

    func start() {
        queue.async { [weak self] in
            guard let self, self.displayLink == nil else { return }
            self.setupPool()
            self.isActive = true
            self.startWall = CACurrentMediaTime()
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(33))
            timer.setEventHandler { [weak self] in self?.emitFrame() }
            timer.resume()
            self.displayLink = timer
            NSLog("[KinetSynthetic] started 30fps %dx%d", self.width, self.height)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.displayLink?.cancel()
            self.displayLink = nil
            self.isActive = false
            NSLog("[KinetSynthetic] stopped")
        }
    }

    private func setupPool() {
        // 注意:像素属性必须传第三个参数(pixelBufferAttributes)
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
        ]
        var made: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &made)
        guard status == kCVReturnSuccess, let p = made else {
            NSLog("[KinetSynthetic] pool create failed: \(status)")
            return
        }
        pool = p
    }

    /// 动态测试图:移动色带 + 圆形表盘 + 时变亮度(AI 曝光分应随之波动)
    private func emitFrame() {
        guard let pool = pool else { return }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let pb = pixelBuffer else { return }
        let t = Double(frameIndex)
        frameIndex &+= 1

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let buf = base.assumingMemoryBound(to: UInt8.self)
        let brightness = UInt8(96 + 40 * sin(t / 45.0))   // 慢周期亮度起伏
        let bandX = Int(t * 8) % width

        for y in 0..<height {
            let row = buf + y * stride
            let vy = Double(y) / Double(height)
            for x in 0..<width {
                let off = x * 4
                let vx = Double(x) / Double(width)
                // 三色竖带流动 + 灰度渐变,含高频细节(拉普拉斯方差非零,AI 不判全糊)
                let band = (x + bandX) % width
                var r: UInt8
                var g: UInt8
                var b: UInt8
                let f = brightnessFactor
                switch band / (width / 3) {
                case 0: (r, g, b) = (UInt8(min(255, Double(brightness) * f)), UInt8(min(255, Double(brightness) * 0.4 * vx * f + 30 * f)), UInt8(min(255, Double(brightness) * 0.6 * f)))
                case 1: (r, g, b) = (UInt8(min(255, Double(brightness) * vx * f)), UInt8(min(255, Double(brightness) * f)), UInt8(min(255, Double(brightness) * 0.5 * f)))
                default:
                    let checker = ((x / 16 + y / 16) % 2 == 0) ? brightness : brightness / 2
                    (r, g, b) = (UInt8(min(255, Double(checker) * f)), UInt8(min(255, Double(checker) * f)), UInt8(min(255, Double(checker) * (0.5 + 0.5 * vy) * f)))
                }
                // 中心圆盘(构图检测目标)
                let dx = x - width / 2
                let dy = y - height / 2
                if dx * dx + dy * dy < 110 * 110 {
                    (r, g, b) = (240, 230, 210)
                }
                row[off] = b
                row[off + 1] = g
                row[off + 2] = r
                row[off + 3] = 255
            }
        }

        let elapsed = CACurrentMediaTime() - startWall
        let pts = CMTime(seconds: max(elapsed, 0), preferredTimescale: 30)
        onPixelBuffer?(pb, pts)
        if frameIndex % 90 == 0 {
            NSLog("[KinetSynthetic] emitted %d frames", frameIndex)
        }
    }
}
