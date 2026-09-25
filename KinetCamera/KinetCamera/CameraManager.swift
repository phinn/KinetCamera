import AVFoundation
import CoreImage
import AppKit

// MARK: - 画中画帧模型
struct PIPDeviceFrame {
    let deviceID: String
    let image: CIImage
}

/// 多摄会话管理:主摄全管线(预览/拍照/美颜录像),其余摄像头各跑一路轻量画中画会话。
final class CameraManager: NSObject, ObservableObject {

    // MARK: - Published 状态(全部只在主线程改)
    @Published var devices: [AVCaptureDevice] = []
    @Published var activeDeviceID: String?
    @Published var isSessionRunning = false
    @Published var isRecording = false
    @Published var recordingSeconds: Double = 0
    @Published var pipDeviceIDs: [String] = []
    @Published var lastError: String?
    @Published var authorizationDenied = false

    // MARK: - 主摄管线
    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "com.kinet.camera.session")
    private let videoDataOutput = AVCaptureVideoDataOutput()
    private let audioDataOutput = AVCaptureAudioDataOutput()
    private let videoQueue = DispatchQueue(label: "com.kinet.camera.video")
    private let audioQueue = DispatchQueue(label: "com.kinet.camera.audio")

    /// 主摄预览帧回调(videoQueue)
    var onFrame: ((CIImage, CMTime) -> Void)?
    /// 画中画帧回调(videoQueue)
    var onPIPFrame: ((String, CIImage) -> Void)?

    // MARK: - 录像器
    private var assetWriter: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var pixelBufferAdaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStartAligned = false
    private var sessionStartPTS = CMTime.zero       // 视频首帧 PTS(会话时间轴原点)
    private var audioPTSShift: CMTime?              // 麦克风时钟 → 会话时间轴 的平移量
    private var recordStartRealtime: Date?
    private var recordTimer: Timer?
    private var movieURL: URL?
    /// 录像实时滤镜(nil = 原片直录)
    var recordFilter: ((CIImage, CMTime) -> CIImage?)?

    /// 最近一帧缓存(videoQueue 写,锁保护)
    private var lastFrameBox: (image: CIImage, time: CMTime)?
    private let frameLock = NSLock()

    private var pipController: PIPController?
    private var streamHealthTimer: Timer?

    /// 诊断:rebuild 后的连接状态(供 automation status 输出)
    var debugConnEnabled = false
    var debugOutputsCount = 0
    var debugFormatDims = ""
    private(set) var framesDelivered = 0
    private(set) var framesDropped = 0
    private(set) var videoFrames = 0
    private(set) var audioFrames = 0
    private(set) var activeMicName = ""

    override init() {
        super.init()
        refreshDevices()
        NotificationCenter.default.addObserver(
            self, selector: #selector(devicesChanged),
            name: .AVCaptureDeviceWasConnected, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(devicesChanged),
            name: .AVCaptureDeviceWasDisconnected, object: nil)
    }

    @objc private func devicesChanged() {
        DispatchQueue.main.async { [weak self] in self?.refreshDevices() }
    }

    // MARK: - 设备枚举 + 权限
    func refreshDevices() {
        assert(Thread.isMainThread)
        var types: [AVCaptureDevice.DeviceType] = [.builtInWideAngleCamera]
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)
        } else {
            // macOS 13:外部摄像头(OBS VirtualCam 等 DAL 插件设备)用 externalUnknown
            types.append(.externalUnknown)
        }
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified)
        var found = discovery.devices
        // 白名单兜底:macOS 14 新增的 DeskView(桌上视角)不在旧 deviceType 白名单里,
        // 但 devices(for:.video) 能枚举到 —— 全量枚举补差集,避免第二路视频源漏网
        let all = AVCaptureDevice.devices(for: .video)
        for d in all where !found.contains(where: { $0.uniqueID == d.uniqueID }) {
            NSLog("[KinetCamera] discovery whitelist missed: %@ (%@)", d.localizedName, d.uniqueID)
            found.append(d)
        }
        devices = found
        if activeDeviceID == nil || !devices.contains(where: { $0.uniqueID == activeDeviceID }) {
            activeDeviceID = devices.first?.uniqueID
        }

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            authorizationDenied = false
            rebuildAndRun()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { [weak self] granted in
                DispatchQueue.main.async {
                    self?.authorizationDenied = !granted
                    if granted { self?.rebuildAndRun() }
                }
            }
        default:
            authorizationDenied = true
        }
        if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
            syncPIP()
        }
    }

    // MARK: - 会话构建/切换
    func rebuildAndRun() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.rebuildSessionLocked()
            if !self.session.isRunning { self.session.startRunning() }
            DispatchQueue.main.async {
                self.isSessionRunning = self.session.isRunning
                self.startStreamHealthCheck()
            }
        }
    }

    /// 流健康检查:授权正常+连接已启用但持续零视频帧 → 硬件流被系统层吊死,
    /// 自动切合成信号源(同一 pixelBuffer 路径);硬件恢复出帧后自动停用。
    private func startStreamHealthCheck() {
        streamHealthTimer?.invalidate()
        guard SyntheticCameraSource.shared.isActive == false else { return }
        let timer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: false) { [weak self] _ in
            guard let self else { return }
            guard self.videoFrames == 0, self.debugConnEnabled, self.isSessionRunning else { return }
            NSLog("[KinetCamera] hardware stream dead (0 frames in 4s) — engaging synthetic source")
            SyntheticCameraSource.shared.onPixelBuffer = { [weak self] pb, pts in
                self?.ingestPixelBuffer(pb, time: pts)
            }
            SyntheticCameraSource.shared.start()
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// 切换主摄(录像中禁止,避免写坏文件)
    func switchDevice(to id: String) {
        guard !isRecording, id != activeDeviceID else { return }
        activeDeviceID = id            // 主线程改 @Published
        rebuildAndRun()
    }

    /// 主摄 ↔ 画中画
    func togglePIP(_ id: String) {
        guard !isRecording else { return }
        if let idx = pipDeviceIDs.firstIndex(of: id) {
            pipDeviceIDs.remove(at: idx)
        } else if id != activeDeviceID {
            pipDeviceIDs.append(id)
            if pipDeviceIDs.count > 3 { pipDeviceIDs.removeFirst() }
        }
        syncPIP()
    }

    /// 同步画中画会话(增删设备 diff)
    func syncPIP() {
        if pipController == nil {
            pipController = PIPController()
            pipController?.onFrame = { [weak self] id, image in
                self?.onPIPFrame?(id, image)
            }
        }
        pipController?.setActive(ids: pipDeviceIDs, devices: devices)
    }

    private func rebuildSessionLocked() {
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)

        guard let mainID = activeDeviceID,
              let mainDevice = devices.first(where: { $0.uniqueID == mainID }),
              let input = try? AVCaptureDeviceInput(device: mainDevice) else {
            DispatchQueue.main.async { self.lastError = "未找到可用摄像头" }
            return
        }
        if session.canAddInput(input) { session.addInput(input) }

        videoDataOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        videoDataOutput.alwaysDiscardsLateVideoFrames = true
        videoDataOutput.setSampleBufferDelegate(self, queue: videoQueue)
        if session.canAddOutput(videoDataOutput) { session.addOutput(videoDataOutput) }
        if let conn = videoDataOutput.connection(with: .video),
           conn.isVideoMirroringSupported {
            conn.isVideoMirrored = mainDevice.position == .front
        }
        debugOutputsCount = session.outputs.count
        debugConnEnabled = videoDataOutput.connection(with: .video)?.isEnabled ?? false
        let dims = CMVideoFormatDescriptionGetDimensions(mainDevice.activeFormat.formatDescription)
        debugFormatDims = "\(dims.width)x\(dims.height)"
        unlockMaxResolutionLocked(mainDevice)

        if let mic = pickRealMicrophone() {
            activeMicName = mic.localizedName
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            if status == .authorized {
                addMicLocked(mic)
            } else if status == .notDetermined {
                // 首次:请求麦克风权限,授权后自动重建会话补上音轨
                AVCaptureDevice.requestAccess(for: .audio) { [weak self] granted in
                    guard granted else { return }
                    self?.sessionQueue.async { [weak self] in
                        guard let self else { return }
                        self.rebuildSessionLocked()  // 会话已 running,配置块提交即生效
                    }
                }
            }
        }
    }

    /// 已授权状态下把麦克风挂进会话(须在 sessionQueue 上调用)
    private func addMicLocked(_ mic: AVCaptureDevice) {
        if session.inputs.contains(where: { ($0 as? AVCaptureDeviceInput)?.device == mic }) { return }
        if let micInput = try? AVCaptureDeviceInput(device: mic) {
            if session.canAddInput(micInput) { session.addInput(micInput) }
            audioDataOutput.setSampleBufferDelegate(self, queue: audioQueue)
            if session.canAddOutput(audioDataOutput) { session.addOutput(audioDataOutput) }
        }
    }

    /// 挑真实麦克风:AVCaptureDevice.default(for:.audio) 会拿到第一个设备,
    /// 本机被 OrayVirtualAudioDevice(远程控制虚拟声卡)占位 → 音轨永远 -91dB 静音。
    /// 规则:名字含虚拟设备特征词的靠后;便携机内置麦克风优先。
    private func pickRealMicrophone() -> AVCaptureDevice? {
        let all = AVCaptureDevice.devices(for: .audio)
        let builtin = all.first {
            let n = $0.localizedName
            return !n.contains("Virtual") && !n.contains("Teams") && !n.contains("Oray")
                && (n.contains("麦克风") || n.contains("Microphone") || n.contains("MacBook"))
        }
        NSLog("[KinetCamera] mics: %@ → picked %@", all.map(\.localizedName).joined(separator: " | "), builtin?.localizedName ?? "default")
        return builtin ?? AVCaptureDevice.default(for: .audio)
    }

    // MARK: - 帧环(夜拍多帧合成 / burst 连拍共用)
    private let frameRingLock = NSLock()
    private var frameRing: [(image: CIImage, time: CMTime)] = []
    private let frameRingCapacity = 60

    private func pushRing(_ image: CIImage, time: CMTime) {
        frameRingLock.lock()
        frameRing.append((image, time))
        if frameRing.count > frameRingCapacity { frameRing.removeFirst(frameRing.count - frameRingCapacity) }
        frameRingLock.unlock()
    }

    /// 最近 N 帧(时间正序);不足返回 nil
    func recentFrames(_ n: Int) -> [(image: CIImage, time: CMTime)]? {
        frameRingLock.lock()
        defer { frameRingLock.unlock() }
        guard frameRing.count >= n else { return nil }
        return Array(frameRing.suffix(n))
    }

    /// 当前帧环长度
    var ringCount: Int {
        frameRingLock.lock(); defer { frameRingLock.unlock() }
        return frameRing.count
    }

    // MARK: - 曝光锁定(软件亮度闭环)
    // macOS AVFoundation 无手动曝光 API(exposureModeCustom/duration/iso 全 unavailable,
    // exposureMode .locked 实测也不支持)——AE Lock 在软件层实现:
    // 锁定瞬间记录画面亮度 → 之后每帧 CIAreaAverage 测均值 → EV 补偿拉回目标亮度。
    @Published var isAELocked = false
    @Published var aeLockTarget: Double = 0
    private var aeSmoothedEV: Double = 0

    func toggleAELock() {
        if isAELocked {
            isAELocked = false
            aeSmoothedEV = 0
            NSLog("[KinetCamera] AE lock released")
        } else {
            guard let frame = takeLatestFrame() else { return }
            let b = AIAnalyzer.quickMean(frame, context: FilterPipeline.shared.renderContext)
            guard b > 0.01 else {
                NSLog("[KinetCamera] AE lock refused: frame too dark (\(b))")
                return
            }
            aeLockTarget = b
            isAELocked = true
            NSLog("[KinetCamera] AE locked @ brightness \(String(format: "%.3f", b)) (software loop)")
        }
    }

    /// 帧级 AE 补偿(videoQueue 调用):返回补偿 EV,0 表示无需
    func aeCompensationEV(for raw: CIImage) -> Double {
        guard isAELocked, aeLockTarget > 0.01 else { return 0 }
        let cur = AIAnalyzer.quickMean(raw, context: FilterPipeline.shared.renderContext)
        guard cur > 0.005 else { return aeSmoothedEV }
        let targetEV = max(-2.0, min(2.0, log2(aeLockTarget / cur)))
        // 平滑逼近,防亮度轻微抖动引起画面呼吸
        aeSmoothedEV += (targetEV - aeSmoothedEV) * 0.35
        return abs(aeSmoothedEV) > 0.02 ? aeSmoothedEV : 0
    }

    /// 配置帧率(不动 activeFormat:实测对内建 FaceTime 相机改格式会让 data output 静默断流)
    private func unlockMaxResolutionLocked(_ device: AVCaptureDevice) {
        do {
            try device.lockForConfiguration()
            let fpsMax = device.activeFormat.videoSupportedFrameRateRanges.map { $0.maxFrameRate }.max() ?? 30.0
            if fpsMax >= 30.0 {
                device.activeVideoMinFrameDuration = CMTime(value: 1, timescale: 30)
                device.activeVideoMaxFrameDuration = CMTime(value: 1, timescale: 30)
            }
            device.unlockForConfiguration()
        } catch {
            NSLog("[KinetCamera] lockForConfiguration failed: \(error)")
        }
    }

    /// 对外保留:已配置过则跳过(仅切换设备场景)
    func unlockMaxResolution() {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard let id = self.activeDeviceID,
                  let device = self.devices.first(where: { $0.uniqueID == id }) else { return }
            self.unlockMaxResolutionLocked(device)
        }
    }
}

// MARK: - 帧代理
extension CameraManager: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        framesDelivered &+= 1
        // ⚠️ 音频判定必须在取 imageBuffer 之前:音频 sample buffer 没有 pixelBuffer,
        //    旧代码 guard 先行把音频帧全部静默吞掉(audioFrames 恒 0,成片无声)
        if output === audioDataOutput {
            audioFrames &+= 1
            writeAudioSample(sampleBuffer)
            return
        }
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let time = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)

        videoFrames &+= 1
        if SyntheticCameraSource.shared.isActive {
            NSLog("[KinetCamera] hardware frames resumed — stopping synthetic source")
            SyntheticCameraSource.shared.stop()
        }
        ingestPixelBuffer(pixelBuffer, time: time)
    }

    /// 视频帧统一入口(硬件源/合成源共用)
    fileprivate func ingestPixelBuffer(_ pixelBuffer: CVPixelBuffer, time: CMTime) {
        var ciImage = CIImage(cvPixelBuffer: pixelBuffer)

        // AE 锁定软件闭环:锁定后把每帧亮度拉回锁定瞬间
        if isAELocked {
            let ev = aeCompensationEV(for: ciImage)
            if ev != 0 {
                ciImage = ciImage.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: ev])
            }
        }

        // 缓存最近帧(拍照源) + 帧环(夜拍/burst 源)
        frameLock.lock()
        lastFrameBox = (ciImage, time)
        frameLock.unlock()
        pushRing(ciImage, time: time)

        if isRecording {
            writeVideoFrame(pixelBuffer, time: time)
        }
        onFrame?(ciImage, time)
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        framesDropped &+= 1
    }
}

// MARK: - 拍照(抓最近实时帧,过完整滤镜链,所见即所得)
extension CameraManager {

    /// 返回 nil 表示当前无帧
    func takeLatestFrame() -> CIImage? {
        frameLock.lock()
        defer { frameLock.unlock() }
        return lastFrameBox?.image
    }

    static func ciToNSImage(_ image: CIImage) -> NSImage? {
        let context = FilterPipeline.shared.renderContext
        guard let cg = context.createCGImage(image, from: image.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: cg.width, height: cg.height))
    }

    static func savePNG(_ nsImage: NSImage) -> URL? {
        let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("KinetCamera", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = dir.appendingPathComponent("KinetCamera-\(formatter.string(from: Date())).png")
        guard let tiff = nsImage.tiffRepresentation,
              let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return nil }
        do {
            try png.write(to: url)
            return url
        } catch { return nil }
    }

    static func saveMOV(_ url: URL) {}
}

// MARK: - 美颜录像(AVAssetWriter,视频帧过实时滤镜链)
extension CameraManager {

    func startRecording() {
        guard !isRecording else { return }
        sessionQueue.async { [weak self] in
            guard let self, !self.isRecording else { return }

            let dir = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("KinetCamera", isDirectory: true)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let url = dir.appendingPathComponent("KinetCamera-\(formatter.string(from: Date())).mov")

            guard let writer = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
                DispatchQueue.main.async { self.lastError = "无法创建录像文件" }
                return
            }
            let dims = self.currentVideoDimensions()
            let vInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: dims.width,
                AVVideoHeightKey: dims.height,
            ])
            vInput.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(
                assetWriterInput: vInput,
                sourcePixelBufferAttributes: [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                    kCVPixelBufferWidthKey as String: dims.width,
                    kCVPixelBufferHeightKey as String: dims.height,
                ])
            writer.add(vInput)

            let aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100,
            ])
            aInput.expectsMediaDataInRealTime = true
            writer.add(aInput)

            self.assetWriter = writer
            self.videoInput = vInput
            self.audioInput = aInput
            self.pixelBufferAdaptor = adaptor
            self.movieURL = url
            self.sessionStartAligned = false
            self.audioPTSShift = nil
            self.recordStartRealtime = Date()
            writer.startWriting()

            DispatchQueue.main.async {
                self.isRecording = true
                self.recordingSeconds = 0
                self.recordTimer?.invalidate()
                self.recordTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                    guard let start = self.recordStartRealtime else { return }
                    self.recordingSeconds = Date().timeIntervalSince(start)
                }
            }
        }
    }

    func stopRecording(completion: ((URL?) -> Void)? = nil) {
        sessionQueue.async { [weak self] in
            guard let self, let writer = self.assetWriter else { return }
            let url = self.movieURL
            DispatchQueue.main.async {
                self.recordTimer?.invalidate()
                self.recordTimer = nil
                self.isRecording = false
            }
            // 会话已对齐过才 mark;未写入任何帧则取消
            if self.sessionStartAligned {
                self.videoInput?.markAsFinished()
                self.audioInput?.markAsFinished()
            }
            writer.finishWriting {
                DispatchQueue.main.async {
                    self.assetWriter = nil
                    self.videoInput = nil
                    self.audioInput = nil
                    self.pixelBufferAdaptor = nil
                    self.sessionStartAligned = false
                    self.audioPTSShift = nil
                    completion?(writer.status == .completed ? url : nil)
                }
            }
        }
    }

    private func currentVideoDimensions() -> (width: Int, height: Int) {
        // 调用方已在 sessionQueue 内,直接读(曾在这里 sessionQueue.sync 自死锁)
        guard let id = activeDeviceID,
              let device = devices.first(where: { $0.uniqueID == id }) else { return (1280, 720) }
        let d = CMVideoFormatDescriptionGetDimensions(device.activeFormat.formatDescription)
        let h = max(Int(d.height), 720) & ~1
        let w = max(Int(d.width), 1280) & ~1
        return (w, h)
    }

    // sessionQueue 上下文调用
    private func writeVideoFrame(_ src: CVPixelBuffer, time: CMTime) {
        guard let writer = assetWriter,
              writer.status == .writing,
              let input = videoInput,
              input.isReadyForMoreMediaData else { return }

        if !sessionStartAligned {
            writer.startSession(atSourceTime: time)   // 只调一次,对齐第一帧 PTS
            sessionStartAligned = true
            sessionStartPTS = time
            audioPTSShift = nil
        }

        var outBuffer: CVPixelBuffer? = src
        if let recordFilter {
            let ci = CIImage(cvPixelBuffer: src)
            if let filtered = recordFilter(ci, time),
               let pool = pixelBufferAdaptor?.pixelBufferPool {
                var maybeBuf: CVPixelBuffer?
                CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybeBuf)
                if let buf = maybeBuf {
                    FilterPipeline.shared.renderContext.render(filtered, to: buf)
                    outBuffer = buf
                }
            }
        }
        if let pb = outBuffer {
            pixelBufferAdaptor?.append(pb, withPresentationTime: time)
        }
    }

    private func writeAudioSample(_ sampleBuffer: CMSampleBuffer) {
        guard sessionStartAligned,                      // 等视频首帧对齐后再写音频
              let input = audioInput,
              input.isReadyForMoreMediaData,
              assetWriter?.status == .writing else { return }

        // 麦克风 PTS 走宿主机时钟(开机秒数),视频(合成源)PTS 从 0 起。
        // 不平移的话 startSession 对齐视频首帧后,音轨被拉成几十万秒。
        // 以首条音频为锚,平移到当前视频时间轴。
        var buf = sampleBuffer
        if audioPTSShift == nil {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            audioPTSShift = CMTimeSubtract(pts, sessionStartPTS)
        }
        if let shift = audioPTSShift {
            var pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            pts = CMTimeSubtract(pts, shift)
            var timing = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sampleBuffer),
                presentationTimeStamp: pts,
                decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer))
            // Swift 导入版签名(inout sampleBufferOut),非 ObjC 返回值版
            var out: CMSampleBuffer?
            if CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleBufferOut: &out) == noErr, let shifted = out {
                buf = shifted
            }
        }
        input.append(buf)
    }
}

// MARK: - 画中画(每设备一套独立 input+output+session)
final class PIPController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {

    var onFrame: ((String, CIImage) -> Void)?
    private var rigs: [String: PIPRig] = [:]
    private let queue = DispatchQueue(label: "com.kinet.camera.pip")

    private final class PIPRig {
        let session: AVCaptureSession
        let output: AVCaptureVideoDataOutput
        let deviceID: String
        init(session: AVCaptureSession, output: AVCaptureVideoDataOutput, deviceID: String) {
            self.session = session
            self.output = output
            self.deviceID = deviceID
        }
    }

    func setActive(ids: [String], devices: [AVCaptureDevice]) {
        queue.async { [weak self] in
            guard let self else { return }
            // 移除不再需要的
            for (id, rig) in self.rigs where !ids.contains(id) {
                rig.session.stopRunning()
                self.rigs.removeValue(forKey: id)
            }
            // 新增
            for id in ids where self.rigs[id] == nil {
                guard let device = devices.first(where: { $0.uniqueID == id }),
                      let input = try? AVCaptureDeviceInput(device: device) else { continue }
                let sess = AVCaptureSession()
                sess.beginConfiguration()
                if sess.canSetSessionPreset(.medium) { sess.sessionPreset = .medium }
                if sess.canAddInput(input) { sess.addInput(input) }
                let output = AVCaptureVideoDataOutput()
                output.videoSettings = [
                    kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
                ]
                output.alwaysDiscardsLateVideoFrames = true
                output.setSampleBufferDelegate(self, queue: self.queue)
                if sess.canAddOutput(output) { sess.addOutput(output) }
                sess.commitConfiguration()
                sess.startRunning()
                self.rigs[id] = PIPRig(session: sess, output: output, deviceID: id)
            }
        }
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        // 用 output 实例反查所属 rig,拿到设备 ID
        let deviceID = rigs.first { $0.value.output === output }?.key
        guard let deviceID else { return }
        onFrame?(deviceID, CIImage(cvPixelBuffer: pixelBuffer))
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {}
}
