import AVFoundation
import ScreenCaptureKit
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
    let screenSource = ScreenSourceController()
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

    /// 设备离线状态机:枚举 → 在线即接管 → 离线重试 → 超时降级 → 上线热恢复。
    /// 覆盖 iPhone 连续互通相机(解锁才广播、锁屏即离线)的完整生命周期。
    enum DeviceWaitState: Equatable {
        case idle                       // 目标设备在线或无等待目标
        case waiting(attempt: Int)      // 枚举等待中
        case degraded(reason: String)   // 超时降级(合成源/切主摄)
    }
    private(set) var deviceWaitState: DeviceWaitState = .idle
    private var waitTimer: Timer?
    private var waitAttempts = 0
    let waitMaxAttempts = 10           // 10 × 1s = 10s 超时

    /// 等待指定设备上线:每秒重枚举,命中即切主摄;超时降级并保持后台监听,上线自动恢复。
    /// 自动化验证入口:枚举 → 等待 → 超时 → 恢复 全路径可编程触发。
    func awaitDevice(id: String, timeoutAttempts: Int = 10, onOutcome: ((DeviceWaitState) -> Void)? = nil) {
        waitTimer?.invalidate()
        waitAttempts = 0
        waitTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.waitAttempts += 1
            let found = self.devices.contains { $0.uniqueID == id }
            if found {
                t.invalidate()
                self.deviceWaitState = .idle
                NSLog("[KinetCamera] device %@ back online after %d s — hot-resume", id, self.waitAttempts)
                self.switchDevice(to: id)
                onOutcome?(.idle)
            } else if self.waitAttempts >= timeoutAttempts {
                t.invalidate()
                let reason = "设备 \(id.prefix(8)) 等待超时(\(timeoutAttempts)s),已降级;上线将自动恢复"
                self.deviceWaitState = .degraded(reason: reason)
                NSLog("[KinetCamera] %@", reason)
                // 降级动作:若当前主摄恰好是掉线设备,健康检查会把合成源拉起(既有链路)
                onOutcome?(.degraded(reason: reason))
            } else {
                self.deviceWaitState = .waiting(attempt: self.waitAttempts)
                onOutcome?(.waiting(attempt: self.waitAttempts))
            }
        }
        RunLoop.main.add(waitTimer!, forMode: .common)
    }

    /// 即时接管成功后重置状态机(server 在线分支调用)
    func clearDeviceWaitState() {
        deviceWaitState = .idle
    }

    var deviceWaitStatusMessage: String {
        switch deviceWaitState {
        case .idle: return ""
        case .waiting(let n): return "等待设备上线…(\(n)s)"
        case .degraded(let r): return r
        }
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
        // 离线清理:PIP 列表里已消失的设备(锁屏的 iPhone/拔掉的 USB 摄像头)立即摘除,
        // 防成片合成引用死源;主摄掉线时交给 awaitDevice/健康检查降级,不在这里强切。
        let liveIDs = Set(found.map { $0.uniqueID })
        let deadPIP = pipDeviceIDs.filter { $0 != ScreenSourceController.id && !liveIDs.contains($0) }
        if !deadPIP.isEmpty {
            pipDeviceIDs.removeAll { deadPIP.contains($0) }
            NSLog("[KinetCamera] PIP devices went offline, removed: %@", deadPIP.joined(separator: ","))
        }
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
        if id == ScreenSourceController.id {
            // 屏幕流:伪设备,不在 devices 枚举里,单独 toggle
            if let idx = pipDeviceIDs.firstIndex(of: id) {
                pipDeviceIDs.remove(at: idx)
            } else {
                pipDeviceIDs.append(id)
            }
            screenSource.sync(deviceIDs: pipDeviceIDs)
            return
        }
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

    /// 全信号源状态(主摄 + 屏流),给 /status 诊断
    var pipStatusMessage: String {
        var parts: [String] = []
        if let c = pipController, !pipDeviceIDs.filter({ $0 != ScreenSourceController.id }).isEmpty {
            parts.append("摄像头PIP rig×\(pipDeviceIDs.filter { $0 != ScreenSourceController.id }.count)")
        }
        if pipDeviceIDs.contains(ScreenSourceController.id) {
            parts.append("屏流[\(screenSource.statusMessage)]")
        }
        return parts.isEmpty ? "无PIP" : parts.joined(separator: " + ")
    }

    /// 屏流帧计数透传给 /status(活帧判定:两次采样递增)
    var screenFrameCount: Int { screenSource.frameCount }

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

    // MARK: - 手动曝光(软件 EV) + 对焦控制
    // macOS AVFoundation 硬件手动曝光全墙:exposureModeCustom/duration/ISO 仅 iOS,
    // exposureTargetBias 也是 iOS only(get-only);setFocusModeLocked(lensPosition:) 同样不可用——
    // 三者均已逐一编译实证,这是平台事实而非实现缺口。
    // → 手动曝光走软件 EV 档:管线增益 2^EV,±2 EV 连续可调(见 FilterPipeline 段位 0),
    //   与 AE lock 互补:EV 管"基准明暗",AE lock 管"定格"。
    // → 对焦:macOS 可用面 = focusMode 切换(.locked 锁定当前对焦防拉风箱 / .continuousAutoFocus 交还系统),
    //   配合渲染层对焦峰值(focusPeaking)完成"看着峰值验证合焦"的工作流。

    /// 当前主摄设备(会话线程安全读取)
    private var activeMainDevice: AVCaptureDevice? {
        sessionQueue.sync {
            session.inputs.compactMap { ($0 as? AVCaptureDeviceInput)?.device }
                .first { $0.hasMediaType(.video) }
        }
    }

    /// 对焦模式切换: .locked = 锁定当前对焦(防拉风箱), .continuousAutoFocus = 交还系统
    func setFocusMode(_ mode: AVCaptureDevice.FocusMode) {
        guard let device = activeMainDevice, device.isFocusModeSupported(mode) else { return }
        do {
            try device.lockForConfiguration()
            device.focusMode = mode
            device.unlockForConfiguration()
            NSLog("[KinetCamera] focus mode → \(mode.rawValue)")
        } catch {
            NSLog("[KinetCamera] focus mode 失败: \(error.localizedDescription)")
        }
    }

    /// 配置帧率(不动 activeFormat:实测对内建 FaceTime 相机改格式会让 data output 静默断流)
    private func unlockMaxResolutionLocked(_ device: AVCaptureDevice) {        do {
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

// MARK: - 屏幕捕捉第二路信号源(CGDisplayStream)
// 场景:教学/演示/直播需要「人+桌面资料同框」。不依赖摄像头栈(OBS 虚拟摄被系统禁、
// 桌上视角相机需 iPhone 活跃),屏幕是每台 Mac 永远在的第二路画面。
// 权限:macOS 10.15+ 走屏幕录制 TCC 授权,拒绝时isActive=false并上报,不 crash。
final class ScreenSourceController: NSObject {
    static let id = "kinet.screen.0"   // 伪设备 ID,UI/接口用同一标识

    var onFrame: ((String, CIImage) -> Void)?
    private var stream: CGDisplayStream?
    private(set) var isActive = false
    private(set) var frameCount = 0
    private var lastError = ""

    /// deviceIDs 里含 kinet.screen.0 → 开屏流,否则关
    func sync(deviceIDs: [String]) {
        let want = deviceIDs.contains(Self.id)
        if want, !isActive { start() }
        else if !want, isActive { stop() }
    }

    var statusMessage: String {
        isActive ? "屏流运行中 已收\(frameCount)帧" : (lastError.isEmpty ? "未启动" : lastError)
    }

    /// 触发屏幕录制 TCC 授权弹框。
    /// CGDisplayStream 无授权时静默零帧,只有 ScreenCaptureKit 的内容查询会让系统弹框。
    private func requestAuthorization() {
        if #available(macOS 12.3, *) {
            Task { _ = (try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)) }
        }
    }

    private func start() {
        guard stream == nil else { return }
        let display = CGMainDisplayID()
        guard let s = CGDisplayStream(
            dispatchQueueDisplay: display,
            outputWidth: 960, outputHeight: 540,
            pixelFormat: Int32(kCVPixelFormatType_32BGRA),
            properties: [
                CGDisplayStream.showCursor: false,
                CGDisplayStream.minimumFrameTime: 1.0 / 15.0   // 15fps 够 PIP 小窗
            ] as CFDictionary,
            queue: DispatchQueue(label: "com.kinet.camera.screensrc"),
            handler: { [weak self] _, _, ioSurface, _ in
                guard let self, let ioSurface = ioSurface else { return }
                self.frameCount += 1
                self.onFrame?(ScreenSourceController.id, CIImage(ioSurface: ioSurface))
            }) else {
            lastError = "CGDisplayStream 创建失败"
            return
        }
        stream = s
        s.start()
        isActive = true
        lastError = ""
        // 起流后 2 秒零帧 → 八成没授权,主动唤起系统弹框
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.isActive, self.frameCount == 0 else { return }
            self.requestAuthorization()
        }
    }

    private func stop() {
        stream?.stop()
        stream = nil
        isActive = false
    }
}

