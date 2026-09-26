import AVFoundation
import ImageIO
import UniformTypeIdentifiers
#if os(macOS)
import ScreenCaptureKit
#endif
import CoreImage
#if canImport(AppKit)
import AppKit
#endif

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
    // 多机位真多轨:每路 PIP 设备一条独立视频轨(同一 writer、同一时间轴=天然 root clock 对齐),
    // 成片 m4v/mov 带 N 条 v 流,剪辑器(FCP/PR)可当多机位拆轨,不再烧 PIP 快照进主画面。
    private var pipVideoInputs: [String: AVAssetWriterInput] = [:]
    private var pipAdaptors: [String: AVAssetWriterInputPixelBufferAdaptor] = [:]
    private var pipInputAppended: Set<String> = []   // 该辅轨 append 过至少一帧(stop 时决定 mark 或丢弃)
    private var recordStartHost: CFTimeInterval?     // 起录主机钟时刻(root clock 原点)
    private var sessionStartAligned = false
    private var sessionStartPTS = CMTime.zero       // 视频首帧 PTS(会话时间轴原点)
    private var lastVideoPTS: CMTime?               // 上一视频帧 PTS(录制中时基断裂检测)
    private var audioPTSShift: CMTime?              // 麦克风时钟 → 会话时间轴 的平移量
    private var recordStartRealtime: Date?
    private var recordTimer: Timer?
    private var movieURL: URL?
    /// 录像实时滤镜(nil = 原片直录)
    var recordFilter: ((CIImage, CMTime) -> CIImage?)?

    /// 最近 sample buffer 原始帧尺寸(ingest 时记录;writer dims 对齐实际输入,防 CI render 坐标错位)
    private(set) var lastIngestDims: (width: Int, height: Int) = (1280, 720)

    /// 最近一帧缓存(videoQueue 写,锁保护)
    private var lastFrameBox: (image: CIImage, time: CMTime)?
    private let frameLock = NSLock()

    private var pipController: PIPController?
    #if os(macOS)
    let screenSource = ScreenSourceController()
    #else
    final class ScreenSourceStub {
        static let id = "kinet.screen.0"
        var onFrame: ((String, CIImage) -> Void)?
        var isActive = false
        var frameCount = 0
        var statusMessage: String { "iOS 不支持屏流" }
        func sync(deviceIDs: [String]) {}
        func stop() {}
    }
    let screenSource = ScreenSourceStub()
    #endif
    static var screenPseudoID: String {
        #if os(macOS)
        return ScreenSourceController.id
        #else
        return "kinet.screen.0"
        #endif
    }
    private var streamHealthTimer: Timer?

    /// 诊断:rebuild 后的连接状态(供 automation status 输出)
    var debugConnEnabled = false
    var debugOutputsCount = 0
    var debugFormatDims = ""
    private(set) var framesDelivered = 0
    private(set) var droppedAtRecord = 0
    private(set) var appendAttempts = 0
    private(set) var framesDropped = 0
    private(set) var videoFrames = 0
    private(set) var audioFrames = 0
    private var audioInputAppended = false
    private var audioPtsDebug = 0
    static var lastAudioFormat: (channels: Int, sampleRate: Double)?
    private(set) var activeMicName = ""

    // MARK: 录音实时静音检测(所见即所闻防线:静音当场告警,不留到回放才发现)
    struct AudioRecordingStats {
        var sampleTotal = 0          // 累计样本数
        var peak: Float = 0          // 录制全程峰值
        var silentSeconds = 0.0      // 当前连续静音时长(峰值 ≤ -60dB 记为静音)
        var hasEverHadSound = false  // 是否出现过真实声音(区分"一直静音"vs"中途静音")
        var flagged = false          // 本次录制是否已告警(一次录制只弹一次)
    }
    private(set) var audioStats = AudioRecordingStats()
    /// 录音静音告警回调(主线程):silent=true 进入静音,silent=false 恢复有声
    var onSilentAudio: ((Bool, Double) -> Void)?
    private var audioStatsQueue = DispatchQueue(label: "com.kinet.camera.audiostats")
    private static let silenceThreshold: Float = 0.001   // ≈ -60dB

    /// 录音静音监测入口(录制结束后调用,返回给 JSON 打标)
    private(set) var lastRecordingAudioSilent: Bool = false
    private(set) var lastRecordingAudioPeak: Double = 0

    override init() {
        super.init()
        refreshDevices()
        bindScreenTrack()
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

    /// denied 状态下的授权看门狗:2s 轮询一次,用户在系统设置开闸后自动出画。
    /// 授权成功或 app 退出时自毁。
    private var authWatchdog: Timer?
    func startAuthWatchdog() {
        guard authWatchdog == nil else { return }
        authWatchdog = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            DispatchQueue.main.async {
                if AVCaptureDevice.authorizationStatus(for: .video) == .authorized {
                    t.invalidate()
                    self.authWatchdog = nil
                    self.authorizationDenied = false
                    self.refreshDevices()
                    NSLog("[KinetCamera] camera authorization granted via watchdog, rebuilding session")
                }
            }
        }
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
    /// 可测性:deviceProbe 闭包注入设备存在性(默认真枚举);单测/预览环境注入假序列跑四路径,
    /// probeOn=true 时跳过 switchDevice 副作用(不重建真 session)。
    var deviceProbe: ((String) -> Bool?)?
    func awaitDevice(id: String, timeoutAttempts: Int = 10, onOutcome: ((DeviceWaitState) -> Void)? = nil) {
        waitTimer?.invalidate()
        waitAttempts = 0
        waitTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            self.waitAttempts += 1
            let found: Bool
            if let probe = self.deviceProbe {
                guard let probed = probe(id) else { t.invalidate(); return }  // probe 返回 nil = 结束测试
                found = probed
            } else {
                found = self.devices.contains { $0.uniqueID == id }
            }
            if found {
                t.invalidate()
                self.deviceWaitState = .idle
                NSLog("[KinetCamera] device %@ back online after %d s — hot-resume", id, self.waitAttempts)
                if self.deviceProbe == nil { self.switchDevice(to: id) }  // probe 模式不动真 session
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
        #if os(macOS)
        if #available(macOS 14.0, *) {
            types.append(.external)
            types.append(.continuityCamera)
        } else {
            types.append(.externalUnknown)
        }
        #else
        types.append(contentsOf: [.builtInUltraWideCamera, .builtInTelephotoCamera, .builtInTrueDepthCamera])
        if #available(iOS 17.0, *) { types.append(.external) }
        #endif
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: types, mediaType: .video, position: .unspecified)
        var found = discovery.devices
        // 白名单兜底:macOS 14 新增的 DeskView(桌上视角)不在旧 deviceType 白名单里,
        // 但 devices(for:.video) 能枚举到 —— 全量枚举补差集,避免第二路视频源漏网
        #if os(macOS)
        let all = AVCaptureDevice.devices(for: .video)
        for d in all where !found.contains(where: { $0.uniqueID == d.uniqueID }) {
            NSLog("[KinetCamera] discovery whitelist missed: %@ (%@)", d.localizedName, d.uniqueID)
            found.append(d)
        }
        #endif
        devices = found
        // 离线清理:PIP 列表里已消失的设备(锁屏的 iPhone/拔掉的 USB 摄像头)立即摘除,
        // 防成片合成引用死源;主摄掉线时交给 awaitDevice/健康检查降级,不在这里强切。
        let liveIDs = Set(found.map { $0.uniqueID })
        let deadPIP = pipDeviceIDs.filter { $0 != Self.screenPseudoID && !liveIDs.contains($0) }
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
        case .denied:
            authorizationDenied = true
            // 自愈:用户可能在系统设置里翻开关;授权状态变化不能靠 notification(denied 时收不到),
            // 定时轮询,变授权即自动重建会话,免去手动重启 app
            startAuthWatchdog()
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
        #if os(macOS)
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
        #endif
    }

    /// 切换主摄(录像中禁止,避免写坏文件)。
    /// 守卫决策收敛在 DevicePolicy(可单测):录像禁切/同设备 no-op/离线目标拒绝。
    func switchDevice(to id: String) {
        let live = devices.map { $0.uniqueID }
        guard DevicePolicy.canSwitch(isRecording: isRecording,
                                     current: activeDeviceID,
                                     target: id,
                                     liveDevices: live) else {
            if isRecording, id != activeDeviceID {
                NSLog("[KinetCamera] switch rejected: recording in progress")
            }
            return
        }
        activeDeviceID = id            // 主线程改 @Published
        resetZoomForDeviceChange()     // 换镜头变焦回 1x,防旧倍率套新镜头
        rebuildAndRun()
    }

    // MARK: - 变焦(硬件 zoomFactor 优先,软件裁切兜底;预览/拍照/录像同一路径)

    /// 当前有效变焦倍数(对外状态,UI/接口读)
    @Published private(set) var zoomFactor: Double = 1.0
    /// 当前设备是否走硬件变焦
    @Published private(set) var zoomIsHardware = false

    /// 软件变焦档单写桥(vm 启动时挂):CameraManager 不持有 FilterSettings,
    /// 只在需要软件变焦时回调 vm 写 settings(主线程,单向,无引用环)
    var onSoftwareZoom: ((Double) -> Void)?

    /// 设变焦倍数。iOS → 硬件 device.videoZoomFactor(实时零开销);
    /// macOS(API 不存在)→ settings.softwareZoom 走滤镜链中心裁切,全设备统一。
    /// 两者互斥,由 resetZoomForDeviceChange 路由,绝不叠加。
    func setZoom(_ factor: Double) {
        guard !isRecording else { return }   // 录像中变焦会跳帧,禁(与切换同守卫)
        let clamped = DevicePolicy.clampZoom(factor, formatMax: activeFormatMaxZoom())
        zoomFactor = clamped
        #if os(iOS)
        if zoomIsHardware, let device = activeMainDevice {
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = clamped
                device.unlockForConfiguration()
            } catch {
                NSLog("[KinetCamera] zoom lockForConfiguration failed: \(error.localizedDescription)")
            }
            return
        }
        #endif
        DispatchQueue.main.async { [weak self] in
            self?.onSoftwareZoom?(clamped)   // 软件档:回调 vm 写 settings,走滤镜链裁切
        }
    }

    /// 换镜头/换源后重算变焦路由:硬件可用则迁移当前倍率到 videoZoomFactor,否则回 1x
    private func resetZoomForDeviceChange() {
        #if os(iOS)
        let hw = DevicePolicy.hardwareZoomAvailable(formatMaxZoom: activeFormatMaxZoom())
        #else
        let hw = false   // macOS 无 videoZoomFactor API,一律软件档
        #endif
        zoomIsHardware = hw
        let carry = hw ? zoomFactor : 1.0
        if !hw { DispatchQueue.main.async { [weak self] in self?.onSoftwareZoom?(1.0) } }
        zoomFactor = carry
        #if os(iOS)
        if hw, let device = activeMainDevice {
            do {
                try device.lockForConfiguration()
                device.videoZoomFactor = carry
                device.unlockForConfiguration()
            } catch { NSLog("[KinetCamera] zoom migrate failed: \(error.localizedDescription)") }
        }
        #endif
    }

    private func activeFormatMaxZoom() -> Double {
        #if os(iOS)
        guard let d = activeMainDevice else { return 1.0 }
        return d.activeFormat.videoMaxZoomFactor
        #else
        return 1.0   // macOS 无硬件变焦 API,软件档上限由 DevicePolicy 画质红线兜底
        #endif
    }

    /// 主摄 ↔ 画中画
    func togglePIP(_ id: String) {
        guard !isRecording else { return }
        if id == Self.screenPseudoID {
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
            pipController?.onFrameRaw = { [weak self] id, pb, time in
                self?.writePIPFrame(id, pixelBuffer: pb, hostTime: CFAbsoluteTimeGetCurrent())
            }
        }
        pipController?.setActive(ids: pipDeviceIDs, devices: devices)
    }

    /// 全信号源状态(主摄 + 屏流),给 /status 诊断
    var pipStatusMessage: String {
        var parts: [String] = []
        let camPips = pipDeviceIDs.filter { $0 != Self.screenPseudoID }
        if let c = pipController, !camPips.isEmpty {
            parts.append("摄像头PIP rig×\(camPips.count)")
        }
        if pipDeviceIDs.contains(Self.screenPseudoID) {
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
              mainDevice.isConnected else {
            DispatchQueue.main.async { self.lastError = "未找到可用摄像头" }
            return
        }
        // 坑:设备断开瞬间(如iPhone连续互通断连)AVCaptureDeviceInput(device:) 抛的是
        // NSException 而非 Swift Error —— try? 捕不住,直接崩 app(实测 20:16:14 崩溃)。
        // 预检 isConnected 把失效设备挡在 init 之外。
        let input: AVCaptureDeviceInput
        do { input = try AVCaptureDeviceInput(device: mainDevice) }
        catch {
            DispatchQueue.main.async { self.lastError = "摄像头输入创建失败(设备可能已断开)" }
            return
        }
        if session.canAddInput(input) { session.addInput(input) }

        // 显式拉 1080p:默认 preset(.high)在该设备给 720p sample buffer,
        // 与 writer 声明的 1080p 不匹配 → 录像帧坐标错位(PIP 烧入被裁切的真实根因)
        let canHD = session.canSetSessionPreset(.hd1920x1080)
        if canHD { session.sessionPreset = .hd1920x1080 }
        NSLog("[KinetCamera] session preset hd1920x1080 canSet=\(canHD) → \(session.sessionPreset.rawValue) (\(session.sessionPreset))")

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
        guard mic.isConnected else { return }   // 断开设备 init 抛 NSException(try?捕不住),预检挡掉
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
        // 跨时基守卫:换源(设备切换/合成源接管)后新帧 PTS 时基不同,
        // 混环会让夜拍运动补偿对齐误判位移 → 检测到断裂直接清环重开
        if DevicePolicy.shouldResetFrameRing(newPTS: CMTimeGetSeconds(time),
                                             lastPTS: frameRing.last.map({ CMTimeGetSeconds($0.time) })) {
            frameRing.removeAll()
        }
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
            // 锁定最大分辨率 format:仅设 frameDuration 不改 format,
            // macOS 27 上 MacBook Air 相机 session preset 1080p 仍给 720p buffer,
            // 必须显式选含 1920x1080 的 format 让 session/output 协商到 1080p
            let candidates = device.formats.filter { fmt in
                let d = CMVideoFormatDescriptionGetDimensions(fmt.formatDescription)
                return d.width >= 1920 && d.height >= 1080
                    && fmt.videoSupportedFrameRateRanges.contains { $0.maxFrameRate >= 30 }
            }
            if let best = candidates.last, best != device.activeFormat {
                device.activeFormat = best
                NSLog("[KinetCamera] locked format \(CMVideoFormatDescriptionGetDimensions(best.formatDescription).width)x\(CMVideoFormatDescriptionGetDimensions(best.formatDescription).height)")
            }
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
        lastIngestDims = (CVPixelBufferGetWidth(pixelBuffer), CVPixelBufferGetHeight(pixelBuffer))
        #if os(macOS)
        if SyntheticCameraSource.shared.isActive {
            NSLog("[KinetCamera] hardware frames resumed — stopping synthetic source")
            SyntheticCameraSource.shared.stop()
        }
        #endif
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

    static func ciToCGImage(_ image: CIImage) -> CGImage? {
        FilterPipeline.shared.renderContext.createCGImage(image, from: image.extent)
    }

    /// 跨平台落盘:CIImage → PNG(macOS→~/Pictures,iOS→Documents)
    @discardableResult
    static func savePNG(image: CIImage) -> URL? {
        guard let cg = ciToCGImage(image) else { return nil }
        return savePNG(cg: cg)
    }

    /// 拍照落盘(JPEG+完整EXIF)。EXIF 写进 JPEG 容器,CGImageSource 直读;
    /// 同一时间戳再落一张无损 PNG(用户定的保底交付,不被 EXIF 需求牺牲)。
    /// - Parameters:
    ///   - exif: kCGImagePropertyExifDictionary 键值(已含 DateTimeOriginal 等)
    ///   - tiff: kCGImagePropertyTIFFDictionary(Make/Model/Software 必须 TIFF 域,EXIF 域会被读取器忽略)
    @discardableResult
    static func savePhoto(cg: CGImage, exif: [String: Any], tiff: [String: Any]) -> URL? {
        #if os(macOS)
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        let dir = base.appendingPathComponent("KinetCamera", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let stamp = formatter.string(from: Date())

        // JPEG + EXIF(主交付,CGImageSource 直读)
        let jpegURL = dir.appendingPathComponent("KinetCamera-\(stamp).jpg")
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        var props: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: 0.95,
            kCGImagePropertyExifDictionary: exif,
            kCGImagePropertyTIFFDictionary: tiff,
        ]
        CGImageDestinationAddImage(dest, cg, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        try? (out as Data).write(to: jpegURL)

        // PNG 无损保底(兼容既有消费链)
        let pngURL = dir.appendingPathComponent("KinetCamera-\(stamp).png")
        if let png = AutomationServer.pngData(of: cg) {
            try? png.write(to: pngURL)
        }
        return jpegURL
    }

    /// 从设备快照构造拍照 EXIF/TIFF(设备为 nil 时仍写软件/时间基础字段,不返回 nil)
    static func captureMetadata(device: AVCaptureDevice?) -> (exif: [String: Any], tiff: [String: Any]) {
        let f = DateFormatter()
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        let now = f.string(from: Date())
        var exif: [String: Any] = [
            kCGImagePropertyExifDateTimeOriginal as String: now,
            kCGImagePropertyExifDateTimeDigitized as String: now,
        ]
        var tiff: [String: Any] = [
            kCGImagePropertyTIFFSoftware as String: "KinetCamera",
            kCGImagePropertyTIFFDateTime as String: now,
        ]
        if let d = device {
            tiff[kCGImagePropertyTIFFMake as String] = d.manufacturer
            tiff[kCGImagePropertyTIFFModel as String] = d.localizedName
            exif[kCGImagePropertyExifLensMake as String] = d.manufacturer
            exif[kCGImagePropertyExifLensModel as String] = d.localizedName
            exif[kCGImagePropertyExifExposureProgram as String] = 2   // Program AE(相机自动)
            exif[kCGImagePropertyExifWhiteBalance as String] = 0      // Auto WB
            #if os(iOS)
            // macOS 平台墙:iso/exposureDuration/lensAperture 编译期 unavailable(见 TIMEBASE docs),
            // Mac 侧 ISO/快门/光圈字段不写(宁缺勿假),iOS 侧写真值
            if d.iso > 0 { exif[kCGImagePropertyExifISOSpeedRatings as String] = [Int(d.iso)] }
            if d.exposureDuration.seconds > 0, d.exposureDuration.seconds < 1 {
                exif[kCGImagePropertyExifExposureTime as String] = d.exposureDuration.seconds
            }
            if d.lensAperture > 0 { exif[kCGImagePropertyExifFNumber as String] = d.lensAperture }
            let fov = d.activeFormat.videoFieldOfView
            if fov > 0 { exif[kCGImagePropertyExifFocalLength as String] = Float(35.0 / tan(fov * .pi / 360.0)) }
            #endif
        }
        return (exif, tiff)
    }

    @discardableResult
    static func savePNG(cg: CGImage) -> URL? {
        #if os(macOS)
        let base = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
        let dir = base.appendingPathComponent("KinetCamera", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        let url = dir.appendingPathComponent("KinetCamera-\(formatter.string(from: Date())).png")
        guard let png = AutomationServer.pngData(of: cg) else { return nil }
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

            // 录音静音检测状态归零
            audioStatsQueue.async { self.audioStats = AudioRecordingStats() }

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

            // 音频 outputSettings 必须与实际输入 format 匹配(声道数/采样率),
            // 否则 append 第 2 帧起 AVAssetWriter 报 -16364 并 cancelled,成片无 moov 打不开。
            // (内置麦 48k 单声道 vs 硬编码 44.1k 双声道 —— 历史上能过纯粹因为当时默认设备是 Teams/Oray 虚拟 2ch)
            var inCh = 1
            var inRate = 48000.0
            // 从最近一帧音频的 CMAudioFormatDescription 拿真实声道/采样率(AVCaptureAudioDataOutput
            // 无直接 format 查询;writeAudioSample 回调里已缓存)
            if let (ch, rate) = Self.lastAudioFormat {
                inCh = ch
                inRate = rate
            }
            let aInput: AVAssetWriterInput
            if true {
                aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVNumberOfChannelsKey: inCh,
                    AVSampleRateKey: inRate,
                ])
                aInput.expectsMediaDataInRealTime = true
                writer.add(aInput)
            } else {
                // 音频流未到达(设备死/无音频)→ 本次录像不建音轨,避免 -16364
                aInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
                NSLog("[KinetCamera] 无音频 format 缓存,本次录像仅视频轨")
            }

            // PIP 真多轨:开录瞬间快照当前 PIP 设备列表,每路一条辅轨 input。
            // 尺寸统一 960x540(PIP 源分辨率,屏流 960x540/连续互通低清),帧由 writePIPFrame 实时进轨。
            for pipID in self.pipDeviceIDs {
                let pw: Int32 = 960, ph: Int32 = 540
                let pInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                    AVVideoCodecKey: AVVideoCodecType.h264,
                    AVVideoWidthKey: pw,
                    AVVideoHeightKey: ph,
                ])
                pInput.expectsMediaDataInRealTime = true
                let pAdaptor = AVAssetWriterInputPixelBufferAdaptor(
                    assetWriterInput: pInput,
                    sourcePixelBufferAttributes: [
                        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                        kCVPixelBufferWidthKey as String: pw,
                        kCVPixelBufferHeightKey as String: ph,
                    ])
                if writer.canAdd(pInput) {
                    writer.add(pInput)
                    self.pipVideoInputs[pipID] = pInput
                    self.pipAdaptors[pipID] = pAdaptor
                    NSLog("[KinetCamera] PIP track added: \(pipID)")
                } else {
                    NSLog("[KinetCamera] PIP track REJECTED by writer: \(pipID)")
                }
            }
            self.pipInputAppended.removeAll()
            self.recordStartHost = CFAbsoluteTimeGetCurrent()

            self.assetWriter = writer
            self.videoInput = vInput
            self.audioInput = aInput
            self.pixelBufferAdaptor = adaptor
            self.movieURL = url
            self.sessionStartAligned = false
            self.lastVideoPTS = nil
            self.audioPTSShift = nil
            self.audioInputAppended = false
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
        NSLog("[KinetCamera] stopRecording called, assetWriter=\(assetWriter != nil ? "存在" : "nil"), isRecording=\(isRecording)")
        // 静音检测终值快照(录制收尾时给成片打标)
        audioStatsQueue.async { [weak self] in
            guard let self else { return }
            let peak = self.audioStats.peak
            let silent = peak <= Self.silenceThreshold
            let samples = self.audioStats.sampleTotal
            DispatchQueue.main.async {
                self.lastRecordingAudioSilent = silent
                self.lastRecordingAudioPeak = Double(peak)
            }
            NSLog("[KinetCamera] audioStats final: samples=\(samples) peak=\(peak) silent=\(silent)")
        }
        sessionQueue.async { [weak self] in
            guard let self, let writer = self.assetWriter else {
                NSLog("[KinetCamera] stopRecording ABORT: assetWriter nil (isRecording=\(self?.isRecording ?? false))")
                completion?(nil)
                return
            }
            let url = self.movieURL
            DispatchQueue.main.async {
                self.recordTimer?.invalidate()
                self.recordTimer = nil
                self.isRecording = false
            }
            // 会话已对齐过才 mark;未写入任何帧则取消
            if self.sessionStartAligned {
                self.videoInput?.markAsFinished()
                // 音频流死亡(-91dB)时 audioInput 从未 append 过任何样本,
                // 对其 markAsFinished 会让 finishWriting 永久挂起(AVF 已知坑)→ 成片无 moov 打不开。
                // 未 append 过的 input 直接丢弃引用,不参与 finishWriting。
                if self.audioInputAppended {
                    self.audioInput?.markAsFinished()
                } else {
                    self.audioInput = nil
                }
                // PIP 辅轨同理:只 mark 写过帧的轨,零帧轨直接丢弃引用防挂起
                for (id, pInput) in self.pipVideoInputs {
                    if self.pipInputAppended.contains(id) {
                        pInput.markAsFinished()
                    }
                }
                self.pipVideoInputs.removeAll()
                self.pipAdaptors.removeAll()
            } else {
                self.pipVideoInputs.removeAll()
                self.pipAdaptors.removeAll()
            }
            NSLog("[KinetCamera] finishWriting 开始 status=\(writer.status.rawValue) errRAW=\(writer.error) aligned=\(sessionStartAligned) audioIn=\(audioInput != nil)")
            writer.finishWriting {
                NSLog("[KinetCamera] finishWriting 完成 status=\(writer.status.rawValue) errRAW=\(writer.error)")
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
        // 调用方已在 sessionQueue 内。设备 activeFormat 1080p 但 macOS 27 session
        // 协商可能仍给 720p buffer,writer dims 必须跟实际输入帧走
        let w = max(lastIngestDims.width, 1280) & ~1
        let h = max(lastIngestDims.height, 720) & ~1
        return (w, h)
    }

    // sessionQueue 上下文调用
    /// 屏流帧进辅轨:ioSurface → CVPixelBuffer → writePIPFrame 同一条轨逻辑(与 PIPController 共轨逻辑)
    /// iOS 无屏流(ScreenSourceStub),bind 为 no-op
    func bindScreenTrack() {
        #if os(macOS)
        screenSource.onRawSurface = { [weak self] surface, hostTime in
            guard let self, self.isRecording else { return }
            var pbUnmanaged: Unmanaged<CVPixelBuffer>?
            let status = CVPixelBufferCreateWithIOSurface(
                kCFAllocatorDefault, surface,
                [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA] as CFDictionary,
                &pbUnmanaged)
            let pb: CVPixelBuffer? = (status == kCVReturnSuccess) ? pbUnmanaged?.takeRetainedValue() : nil
            guard let pb else { return }
            self.writePIPFrame(ScreenSourceController.id, pixelBuffer: pb, hostTime: hostTime)
        }
        #endif
    }

    /// PIP 实时帧进辅轨(真多轨,不烧入主画面)。
    /// root clock = 主机单调钟:CFAbsoluteTime。各设备原始 PTS 时基互不相干(屏流/连续互通各有时钟),
    /// 到达即弃源 PTS,用「相对起录时刻的主机钟偏移 + sessionStartPTS」生成辅轨 PTS,
    /// 与主轨(同主机钟轴实时写入)天然同轴 —— 这就是跨设备 root clock 对齐。
    /// 主轨尚未 startSession(首帧未到)时辅轨先缓冲丢弃,保证 writer 会话起点恒由主轨定义。
    func writePIPFrame(_ deviceID: String, pixelBuffer: CVPixelBuffer, hostTime: CFTimeInterval) {
        guard isRecording,
              let writer = assetWriter, writer.status == .writing,
              let input = pipVideoInputs[deviceID],
              let adaptor = pipAdaptors[deviceID] else { return }
        guard sessionStartAligned, let startHost = recordStartHost else { return }
        guard input.isReadyForMoreMediaData else { return }
        let sessionPTS = CMTimeAdd(sessionStartPTS,
            CMTime(seconds: max(0, hostTime - startHost), preferredTimescale: 600))
        let pb: CVPixelBuffer
        if let pool = adaptor.pixelBufferPool {
            var maybe: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &maybe)
            if let buf = maybe {
                // pool buffer 是空白内存,必须把源帧像素拷进去(直接 append 空 buf = 成片黑帧)
                pb = buf
                CVPixelBufferLockBaseAddress(buf, [])
                CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
                defer {
                    CVPixelBufferUnlockBaseAddress(buf, [])
                    CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
                }
                guard let dst = CVPixelBufferGetBaseAddress(buf),
                      let srcAddr = CVPixelBufferGetBaseAddress(pixelBuffer) else {
                    return
                }
                let dw = CVPixelBufferGetWidth(buf), dh = CVPixelBufferGetHeight(buf)
                let sw = CVPixelBufferGetWidth(pixelBuffer), sh = CVPixelBufferGetHeight(pixelBuffer)
                let dBytes = CVPixelBufferGetBytesPerRow(buf)
                let sBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
                let copyH = min(dh, sh), copyW = min(dw, sw) * 4
                let dBase = dst.assumingMemoryBound(to: UInt8.self)
                let sBase = srcAddr.assumingMemoryBound(to: UInt8.self)
                for row in 0..<copyH {
                    memcpy(dBase + row * dBytes, sBase + row * sBytes, copyW)
                }
            } else { pb = pixelBuffer }
        } else { pb = pixelBuffer }
        if adaptor.append(pb, withPresentationTime: sessionPTS) {
            pipInputAppended.insert(deviceID)
        }
    }

    private func writeVideoFrame(_ src: CVPixelBuffer, time: CMTime) {
        guard let writer = assetWriter,
              writer.status == .writing,
              let input = videoInput else {
            if isRecording, videoFrames % 30 == 0 {
                NSLog("[KinetCamera] writeVideoFrame skip: writer=\(assetWriter != nil) status=\(assetWriter?.status.rawValue ?? -1) input=\(videoInput != nil) frames=\(videoFrames)")
            }
            return
        }
        guard input.isReadyForMoreMediaData else {
            droppedAtRecord &+= 1
            if droppedAtRecord % 60 == 1 {
                NSLog("[KinetCamera] record drop total=%d (isReadyForMoreMediaData=false)", droppedAtRecord)
            }
            return
        }

        if !sessionStartAligned {
            writer.startSession(atSourceTime: time)   // 只调一次,对齐第一帧 PTS
            sessionStartAligned = true
            sessionStartPTS = time
            lastVideoPTS = time
            audioPTSShift = nil
        } else {
            // PTS 连续性守卫:录制中切换设备(内置摄↔iPhone连续互通)后,新设备帧的 PTS 时基
            // 与旧设备完全不同步 —— 实测切换后 append ok=1 全部成功,但 PTS 断崖
            // (成片视频轨 duration 423861s ≈ 4.9 天,播放器炸)。守卫:与前帧间隔 >0.5s
            // 视为时基断裂,丢弃该帧并把 session 起点重新对齐到新时基。
            if let last = lastVideoPTS {
                let delta = CMTimeSubtract(time, last).seconds
                if DevicePolicy.isPTSDiscontinuity(deltaSeconds: delta) {
                    NSLog("[KinetCamera] video PTS jump %.3fs detected — realigning session to new device timebase", delta)
                    writer.startSession(atSourceTime: time)
                    sessionStartPTS = time
                    audioPTSShift = nil
                }
            }
            lastVideoPTS = time
        }

        var outBuffer: CVPixelBuffer? = src
        if let recordFilter {
            let ci = CIImage(cvPixelBuffer: src)
            let t0 = CFAbsoluteTimeGetCurrent()
            defer { if videoFrames % 30 == 0 { NSLog("[KinetCamera] recordFilter cost %.1f ms", (CFAbsoluteTimeGetCurrent()-t0)*1000) } }
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
            appendAttempts &+= 1
            let ok = pixelBufferAdaptor?.append(pb, withPresentationTime: time) ?? false
            if appendAttempts <= 3 || !ok {
                NSLog("[KinetCamera] video append #%d pts=%.3f ok=%d status=%d err=%@", appendAttempts, CMTimeGetSeconds(time), ok ? 1 : 0, writer.status.rawValue, writer.error?.localizedDescription ?? "nil")
            }
        }
    }

    private func writeAudioSample(_ sampleBuffer: CMSampleBuffer) {
        if let fdesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(fdesc) {
            Self.lastAudioFormat = (Int(asbd.pointee.mChannelsPerFrame), asbd.pointee.mSampleRate)
        }
        // 实时静音检测:从 PCM 数据取峰值(vDSP),累计静音时长,超阈值告警一次
        if let fdesc = CMSampleBufferGetFormatDescription(sampleBuffer),
           CMFormatDescriptionGetMediaType(fdesc) == kCMMediaType_Audio,
           let block = CMSampleBufferGetDataBuffer(sampleBuffer) {
            let length = CMBlockBufferGetDataLength(block)
            if length > 0 {
                let bytes = UnsafeMutableRawPointer.allocate(byteCount: length, alignment: 16)
                defer { bytes.deallocate() }
                if CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: bytes) == noErr {
                    let floats = bytes.bindMemory(to: Float.self, capacity: length / 4)
                    let n = length / 4
                    if n > 0 {
                        var chunkPeak: Float = 0
                        for i in 0..<n where abs(floats[i]) > chunkPeak { chunkPeak = abs(floats[i]) }
                        audioStatsQueue.async { [weak self] in
                            guard let self else { return }
                            self.audioStats.sampleTotal += n
                            if chunkPeak > self.audioStats.peak { self.audioStats.peak = chunkPeak }
                            let asbd = Self.lastAudioFormat
                            let sr = asbd?.sampleRate ?? 48000
                            let chunkSeconds = Double(n) / sr
                            if chunkPeak > Self.silenceThreshold {
                                self.audioStats.hasEverHadSound = true
                                if self.audioStats.silentSeconds > 0 {
                                    self.audioStats.silentSeconds = 0
                                    if self.audioStats.flagged {
                                        DispatchQueue.main.async { self.onSilentAudio?(false, Double(chunkPeak)) }
                                    }
                                }
                            } else {
                                self.audioStats.silentSeconds += chunkSeconds
                                // 持续 ≥3s 静音 → 告警一次(整个录制周期只弹一次)
                                if self.audioStats.silentSeconds >= 3.0 && !self.audioStats.flagged {
                                    self.audioStats.flagged = true
                                    DispatchQueue.main.async { self.onSilentAudio?(true, Double(self.audioStats.peak)) }
                                }
                            }
                        }
                    }
                }
            }
        }
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
            // 防 AVAssetWriter -16364:平移后负 PTS/NaN(音频先于视频首帧/时钟异常)直接丢弃
            guard let safePTS = DevicePolicy.safeAudioPTS(shiftedPTS: CMTimeGetSeconds(pts)) else {
                return
            }
            pts = CMTime(seconds: safePTS, preferredTimescale: pts.timescale)
            var timing = CMSampleTimingInfo(
                duration: CMSampleBufferGetDuration(sampleBuffer),
                presentationTimeStamp: pts,
                decodeTimeStamp: CMSampleBufferGetDecodeTimeStamp(sampleBuffer))
            // -16364 防御:CreateCopyWithNewTiming 对 invalid duration 的 buffer 会产出非法样本
            if timing.duration.value == 0 || timing.duration.timescale == 0 {
                timing.duration = CMTime(value: 1024, timescale: 48000)  // 典型 AAC/PCM 帧长 21.3ms
            }

            // Swift 导入版签名(inout sampleBufferOut),非 ObjC 返回值版
            var out: CMSampleBuffer?
            if CMSampleBufferCreateCopyWithNewTiming(
                allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
                sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleBufferOut: &out) == noErr, let shifted = out {
                buf = shifted
            }
        }
        if audioPtsDebug < 4 {
            audioPtsDebug += 1
            let rp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            let sp = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(buf))
            NSLog("[KinetCamera] audio#\(audioPtsDebug) raw=\(rp) shifted=\(sp) numSamples=\(CMSampleBufferGetNumSamples(buf))")
        }
        input.append(buf)
        if audioInputAppended == false {
            NSLog("[KinetCamera] audio append #1 writerStatus=\(assetWriter?.status.rawValue ?? -1) err=\(assetWriter?.error?.localizedDescription ?? "nil")")
        }
        audioInputAppended = true
        if assetWriter?.status == .failed || assetWriter?.status == .cancelled {
            NSLog("[KinetCamera] audio append broke writer: \(assetWriter?.error)")
        }
    }
}

// MARK: - 画中画(每设备一套独立 input+output+session)
final class PIPController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var onFrameRaw: ((String, CVPixelBuffer, CMTime) -> Void)?


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
                      device.isConnected,   // 断开设备 init 抛 NSException(try?捕不住),预检挡掉
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
        onFrameRaw?(deviceID, pixelBuffer, CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
        onFrame?(deviceID, CIImage(cvPixelBuffer: pixelBuffer))
    }

    func captureOutput(_ output: AVCaptureOutput,
                       didDrop sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {}
}

#if os(macOS)
// MARK: - 屏幕捕捉第二路信号源(CGDisplayStream)
// 场景:教学/演示/直播需要「人+桌面资料同框」。不依赖摄像头栈(OBS 虚拟摄被系统禁、
// 桌上视角相机需 iPhone 活跃),屏幕是每台 Mac 永远在的第二路画面。
// 权限:macOS 10.15+ 走屏幕录制 TCC 授权,拒绝时isActive=false并上报,不 crash。
final class ScreenSourceController: NSObject {
    static let id = "kinet.screen.0"   // 伪设备 ID,UI/接口用同一标识

    var onFrame: ((String, CIImage) -> Void)?
    var onRawSurface: ((IOSurface, CFTimeInterval) -> Void)?
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
                let now = CFAbsoluteTimeGetCurrent()
                // 辅轨(真多轨):屏流帧经回调交给 manager 进 writer(录像中才实际写入)
                self.onRawSurface?(ioSurface, now)
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


#endif
