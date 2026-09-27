import AVFoundation
import CoreImage
import CoreVideo

/// 合成信号源:摄像头被系统层吊死时(远控守护独占/驱动挂起),用 demo pattern 走
/// 与真实摄像头完全相同的 pixelBuffer 交付路径,验证 app 全链路(预览/AI/拍照/录像)。
/// 真实摄像头恢复出帧后本源自动停用。
/// 虚拟摄位(iOS 无摄像头环境/模拟器:三摄位验收用,视野差异模拟光学变焦)
enum SyntheticLensKind: Int {
    case ultrawide = 0   // 0.5×:特征缩小(视野广)
    case wide = 1        // 1×:基准图样
    case tele = 2        // 5×:特征放大(视野窄)

    var scale: Double {
        switch self {
        case .ultrawide: return 0.5
        case .wide: return 1.0
        case .tele: return 2.2
        }
    }
}

final class SyntheticCameraSource: NSObject {

    static let shared = SyntheticCameraSource()

    /// 当前模拟摄位(切摄位强制重建基图,图样几何尺寸随之变化)
    var lensKind: SyntheticLensKind = .wide {
        didSet {
            guard lensKind != oldValue else { return }
            queue.async { [weak self] in
                self?.basePattern = nil
                self?.basePatternBucket = 255  // 强制 ensureBasePattern 重建
            }
        }
    }

    private var displayLink: DispatchSourceTimer?
    private var activity: NSObjectProtocol?
    private let queue = DispatchQueue(label: "com.kinet.camera.synthetic")
    private var frameIndex: Int = 0
    private var tickCount: Int = 0
    private var basePattern: [UInt8]?
    private var basePatternStride: Int?
    private var basePatternBucket: UInt8 = 0
    private var stride_: Int { width * 4 }
    // 规格跟录像质量档走(4K60 档发 3840x2160@60 语义帧,1080p 档发 1920x1080@30):
    // 发射规格与 writer 声明尺寸一致是硬约束(坐标错位教训见 CameraManager preset 注释)
    private var width = 1280
    private var height = 720
    private var tickMs = 33
    var specLabel: String = "720p30"

    /// 应用新规格(停→改→启;queue 内串行安全)
    func applySpec(width w: Int, height h: Int, fps: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.displayLink?.cancel()
            self.displayLink = nil
            self.width = w
            self.height = h
            self.tickMs = 1000 / fps
            self.basePattern = nil
            self.basePatternStride = nil
            self.pool = nil
            self.isActive = false
            self.start()
        }
    }
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
            // 相机源运行期间禁 AppNap:后台/遮挡时 macOS 会把定时器节拍拉长(实测 33ms→77ms,30fps→13fps),
            // 相机类 app 的标准做法(ProcessInfo.activity,录像/采集场景 Apple 也这么用)
            self.activity = ProcessInfo.processInfo.beginActivity(
                options: [.userInitiated, .idleSystemSleepDisabled],
                reason: "KinetCamera synthetic capture 30fps")
            let timer = DispatchSource.makeTimerSource(queue: self.queue)
            // 不设 leeway 时系统默认可合并到数百 ms(实测 33ms 定时器只跑出 7fps),
            // 显式压到 1ms 保证 30fps 节拍
            timer.schedule(deadline: .now(), repeating: .milliseconds(self.tickMs), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.emitFrame() }
            timer.resume()
            self.displayLink = timer
            NSLog("[KinetSynthetic] started %@ %dx%d tick=%dms", self.specLabel, self.width, self.height, self.tickMs)
        }
    }

    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.displayLink?.cancel()
            self.displayLink = nil
            self.isActive = false
            if let a = self.activity {
                ProcessInfo.processInfo.endActivity(a)
                self.activity = nil
            }
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

    /// 基础 pattern 帧(慢变亮度分桶生成,每帧 memcpy 复用)
    private func ensureBasePattern(brightnessBucket: UInt8) {
        if basePattern != nil && basePatternBucket == brightnessBucket { return }
        basePatternBucket = brightnessBucket
        let brightness = brightnessBucket
        var bp = [UInt8](repeating: 0, count: stride_ * height)
        let f = brightnessFactor
        // 填充(与旧逻辑同图案)
        bp.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let buf = raw.baseAddress!.assumingMemoryBound(to: UInt8.self)
            for y in 0..<height {
                let row = buf + y * stride_
                let vy = Double(y) / Double(height)
                for x in 0..<width {
                    let off = x * 4
                    let vx = Double(x) / Double(width)
                    let band = x % width
                    var r: UInt8, g: UInt8, b: UInt8
                    switch band / (width / 3) {
                    case 0: (r, g, b) = (UInt8(min(255, Double(brightness) * f)), UInt8(min(255, Double(brightness) * 0.4 * vx * f + 30 * f)), UInt8(min(255, Double(brightness) * 0.6 * f)))
                    case 1: (r, g, b) = (UInt8(min(255, Double(brightness) * vx * f)), UInt8(min(255, Double(brightness) * f)), UInt8(min(255, Double(brightness) * 0.5 * f)))
                    default:
                    let cs = max(4, Int(16.0 / lensKind.scale))
                    let checker: UInt8 = ((x / cs + y / cs) % 2 == 0) ? brightness : brightness / 2
                    let chkD = Double(checker)
                    let chkB = Double(checker) * (0.5 + 0.5 * vy)
                    (r, g, b) = (UInt8(min(255, chkD * f)), UInt8(min(255, chkD * f)), UInt8(min(255, chkB * f)))
                }
                let dx = x - width / 2, dy = y - height / 2
                let rrD = 110.0 * lensKind.scale
                let rr2 = rrD * rrD
                let d2 = Double(dx * dx + dy * dy)
                if d2 < rr2 { (r, g, b) = (240, 230, 210) }
                    row[off] = b; row[off+1] = g; row[off+2] = r; row[off+3] = 255
                }
            }
        }
        basePattern = bp
        basePatternStride = stride_
    }

    /// 动态测试图:移动色带 + 圆形表盘 + 时变亮度(AI 曝光分应随之波动)
    private func emitFrame() {
        guard let pool = pool else { return }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pixelBuffer)
        guard let pb = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let buf = base.assumingMemoryBound(to: UInt8.self)
        let t = Double(frameIndex)
        frameIndex &+= 1

        // Debug build 下逐像素全帧重画实测 ~80ms/帧(12fps 元凶,sample 铁证 IndexingIterator)。
        // 改为:基础 pattern 帧只生成一次(亮度档位分桶),每帧 memcpy + 重画移动条带区域。
                // 亮度量化到 4 级桶:连续 sin 四舍五入每帧都变会退化成每帧全帧重画(sample 实测)
        let brightRaw = UInt8((96 + 40 * sin(t / 45.0)).rounded())
        ensureBasePattern(brightnessBucket: brightRaw - brightRaw % 4)

        if var bp = basePattern, let bs = basePatternStride {
            let bpPtr = UnsafeMutableRawPointer(mutating: bp)
            // 1) 整帧拷贝基础 pattern(memcpy,~0.3ms)
            memcpy(buf, bpPtr, min(stride, bs) * height)
            // 2) 只重画移动的竖带(band 区域 = 全宽,但内容每帧平移)—— 直接重画 band 列附近最小区域不现实,
            //    但 memcpy 已铺满,只需覆盖三色带交界可辨识移动的部分。实测保留:重画整行内 band 位移列的 24px 宽条。
            // band 完全静止(SAD 实测:移速 2px/帧时单帧 SAD 达 12-17 万,夜景/防抖
            // 运动检测把 7/8 帧误弃 —— band 图案平移跨过 4px SAD 采样网格灰阶大跳)。
            // 活性验证由 /status frameCount 承担,不靠画面移动。
            let bandX = 0
            let bandW = 40 * 24  // 24 个采样列各间隔 40px → 连续画 960px 宽条带
            for y in 0..<height {
                let dstRow = buf + y * stride
                let srcRow = bpPtr + y * bs
                let dStart = bandX * 4
                let sStart = 0
                let firstLen = min(bandW * 4, width * 4 - dStart)
                memcpy(dstRow + dStart, srcRow + sStart, firstLen)
                if firstLen < bandW * 4 {  // 绕回段
                    memcpy(dstRow, srcRow + firstLen, bandW * 4 - firstLen)
                }
            }
        }

        // PTS = 墙钟挂钟(timescale 900,33ms=30/900 无取整歧义):帧交得慢(美颜链 14fps)
        // 时成片时长仍等于真实录制时长,不会时间压缩快放;单调度器串行发射保证 PTS 单调不重。
        // 旧写法帧号/30 在处理端降速时会把 30s 内容压成 15s 片子(实测);更旧的
        // CMTime(seconds:elapsed,timescale:30) 因 30Hz 栅栏取整出重复 PTS → h264 mux -16364,均废弃。
        let elapsed = CACurrentMediaTime() - startWall
        let pts = CMTime(seconds: elapsed, preferredTimescale: 900)
        onPixelBuffer?(pb, pts)
        if frameIndex % 90 == 0 {
            NSLog("[KinetSynthetic] emitted %d frames", frameIndex)
        }
    }
}
