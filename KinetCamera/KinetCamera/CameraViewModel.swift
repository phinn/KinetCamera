import SwiftUI
import Combine
import CoreImage
import AVFoundation

final class CameraViewModel: ObservableObject {

    let manager = CameraManager()
    let pipeline = FilterPipeline.shared

    @Published var settings = FilterSettings(sharpen: 0.25)
    @Published var lastSavedPath: String?
    @Published var lastAnalysis = AIAnalysis.empty
    @Published var showGrid = true
    @Published var lastCaptureReport: CaptureReport?
    /// AI 修正档位开关(每类修正独立启用;用户显式关掉的项不再自动触发)
    @Published var aiToggles: [AICorrectionKind: Bool] = Dictionary(
        uniqueKeysWithValues: AICorrectionKind.allCases.map { ($0, true) }) {
        didSet { UserDefaults.standard.set(
            Dictionary(uniqueKeysWithValues: aiToggles.map { ($0.key.rawValue, $0.value) }),
            forKey: "kinet.aiToggles") }
    }
    var enabledAICorrections: Set<AICorrectionKind> {
        Set(aiToggles.filter { $0.value }.keys)
    }
    @Published var audioSilentWarning = false      // 录音静音告警(录制中实时)
    @Published var lastVideoAudioSilent = false    // 上段录像成片是否静音(JSON 打标用)

    private weak var renderView: CIRenderView?
    private var analysisInFlight = false
    private var cancellables = Set<AnyCancellable>()
    /// 主预览帧计数(automation 需要读)
    var frameCount = 0
    /// 处理后帧率滑动窗口(最近1s时间戳),handleFrame 每帧 push,/status 读 count
    fileprivate var fpsWindow: [CFTimeInterval] = []
    /// 美颜/AI处理后实时fps(最近1s滑动窗口)
    var processedFps: Int { fpsWindow.count }

    init() {
        // 恢复持久化的档位开关(缺省项默认 true:新增档位自动启用)
        let saved = UserDefaults.standard.dictionary(forKey: "kinet.aiToggles") as? [String: Bool] ?? [:]
        for kind in AICorrectionKind.allCases {
            if let v = saved[kind.rawValue] { aiToggles[kind] = v }
        }
        manager.onFrame = { [weak self] image, _ in
            self?.handleFrame(image)
        }
        manager.onPIPFrame = { [weak self] id, image in
            DispatchQueue.main.async {
                self?.pipFrames[id] = image
                self?.pipFrameTotal += 1
            }
        }
        // 屏流伪设备帧回流 PIP 字典(与摄像头 PIP 同一条成片合成路径)
        manager.screenSource.onFrame = { [weak self] id, image in
            DispatchQueue.main.async {
                self?.pipFrames[id] = image
                self?.pipFrameTotal += 1
            }
        }
        // manager 的状态变化透传给观察 vm 的视图
        manager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 软件变焦桥:manager 决定走软件档时回调这里写滤镜链设置
        manager.onSoftwareZoom = { [weak self] z in
            self?.settings.softwareZoom = z
        }
        // 录音静音实时告警:录制中持续 ≥3s 静音 → UI 徽标 + 自动化可查
        manager.onSilentAudio = { [weak self] silent, _ in
            self?.audioSilentWarning = silent
            NSLog("[KinetCamera] 录音静音告警: \(silent ? "进入静音" : "恢复有声")")
        }
        // 自动化美颜接口
        NotificationCenter.default.addObserver(
            forName: Notification.Name("kinetSetBeauty"), object: nil, queue: .main
        ) { [weak self] note in
            guard let ui = note.userInfo else { return }
            self?.settings.smoothing = ui["smoothing"] as? Double ?? 0
            self?.settings.whitening = ui["whitening"] as? Double ?? 0
            self?.settings.backgroundBlur = ui["backgroundBlur"] as? Double ?? 0
            self?.settings.faceSlim = ui["faceSlim"] as? Double ?? 0
            if let sh = ui["sharpen"] as? Double { self?.settings.sharpen = sh }
        }
    }

    /// 画中画当前帧(设备ID → 帧)
    /// PIP 帧总数(含屏流,真实帧计数;pipFrames 字典是"每设备最新帧",count 只是设备数)
    @Published var pipFrameTotal = 0
    @Published var pipFrames: [String: CIImage] = [:]

    // MARK: - 帧处理(videoQueue 调用)
    fileprivate nonisolated func handleFrame(_ raw: CIImage) {
        // 预览走 .video GPU 快速档(与录像同路径,30fps 可达):
        // .photo 档的全尺寸导向滤波 CPU pass 在预览路径会把帧率压到 7-14fps(实测)。
        // 拍照/回溯/连拍落盘仍走各自显式的 .photo 全画质链(170/245/335 行),互不影响。
        let filtered = pipeline.apply(raw, settings: effectiveSettings, time: .zero, quality: .video)
        frameCount &+= 1
        // 实时处理帧率(美颜链后):滑动窗口,最近 1s 计数,给 /status 美颜 fps 验收
        fpsWindow.append(CFAbsoluteTimeGetCurrent())
        let cutoff = CFAbsoluteTimeGetCurrent() - 1.0
        while let first = fpsWindow.first, first < cutoff { fpsWindow.removeFirst() }
        let view = renderView
        DispatchQueue.main.async {
            view?.inputCIImage = filtered
        }

        // AI 实时体检:每 30 帧一次(约 1s)
        if frameCount % 30 == 0 && !analysisInFlight {
            analysisInFlight = true
            let ctx = pipeline.renderContext
            Task.detached(priority: .utility) { [weak self] in
                let result = AIAnalyzer.analyze(filtered, context: ctx)
                await MainActor.run { [weak self] in
                    self?.lastAnalysis = result
                    self?.applyAutoAdjustment()
                    self?.enforceFocusPolicy(now: CFAbsoluteTimeGetCurrent())
                    self?.analysisInFlight = false
                }
            }
        }
    }

    // MARK: - AI 场景自适应(CorrectionEngine 决策层)
    /// 微调偏移独立于用户滑杆:用户值不动,自适应偏移在渲染前叠加,reason 可在 UI 展示
    @Published private(set) var lastAdjustment = BeautyAdjustment.neutral
    /// 自动档开关(默认开;UI 加 toggle,关=纯手动零干预)
    @Published var autoAdapt = true

    private func applyAutoAdjustment() {
        guard autoAdapt else {
            if !lastAdjustment.isNeutral { lastAdjustment = .neutral }
            return
        }
        let adj = CorrectionEngine.autoAdjust(
            brightness: lastAnalysis.brightness,
            blurScore: lastAnalysis.blurScore,
            smoothing: settings.smoothing)
        lastAdjustment = adj
    }

    // MARK: - P0③ 再对焦抑制(FocusPolicy)
    /// 上次分析的脸框(连续帧间比较用);分析每 30 帧一次,天然形成采样节拍
    private var focusStateLastFace: CGRect?
    private var focusStateLastRefocus: TimeInterval = 0

    private func enforceFocusPolicy(now: TimeInterval) {
        // iOS:脸变>15%/位移>6%/冷却1.2s 才拉焦;macOS 内建摄无 focusMode 可用面,跳过
        #if os(iOS)
        guard let device = manager.activeMainDeviceInternal, device.isFocusModeSupported(.continuousAutoFocus) else { return }
        let need = FocusPolicy.shouldRefocus(
            previousFace: focusStateLastFace,
            currentFace: lastAnalysis.faceRect,
            now: now, lastRefocus: focusStateLastRefocus)
        focusStateLastFace = lastAnalysis.faceRect
        if need {
            focusStateLastRefocus = now
            manager.setFocusMode(.continuousAutoFocus)   // 交还系统拉一次焦
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                self?.manager.setFocusMode(.locked)      // 拉完即锁,防连拉
            }
        }
        #endif
    }

    /// 生效值 = 用户滑杆 + 自适应偏移(clamp 0-1)。预览/录像链统一取 effectiveSettings。
    var effectiveSmoothing: Double { CorrectionEngine.clamp01(settings.smoothing + lastAdjustment.smoothingDelta) }
    var effectiveSharpen: Double { CorrectionEngine.clamp01(settings.sharpen + lastAdjustment.sharpenDelta) }
    var effectiveBrightening: Double { CorrectionEngine.clamp01(settings.brightening + lastAdjustment.brighteningDelta) }
    /// 渲染链生效配置:用户设定为底,自适应偏移叠加(拍照 .photo 链同用,所见即所得一致)
    var effectiveSettings: FilterSettings {
        guard autoAdapt, !lastAdjustment.isNeutral else { return settings }
        var s = settings
        s.smoothing = effectiveSmoothing
        s.sharpen = effectiveSharpen
        s.brightening = effectiveBrightening
        return s
    }

    func attach(_ view: CIRenderView) {
        renderView = view
    }

    /// 渲染诊断(automation)
    var renderDrawCount: Int { renderView?.drawCount ?? -1 }
    var renderDrawState: String { renderView?.lastDrawError ?? "no view" }

    // MARK: - 拍照(主线程调用)
    func capturePhoto() {
        guard let frame = manager.takeLatestFrame() else {
            lastSavedPath = "拍照失败:无画面"
            return
        }
        // 主线程快照滤镜设置,避免后台线程读 @Published struct 的 data race
        let beauty = settings
        let autoAdapt = self.autoAdapt
        let brightness = lastAnalysis.brightness
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            // P0① MFNR:暗光(亮度<0.30)自动 3 帧合成降噪,失败/不合法静默回退单帧(拍照永远成功)
            if autoAdapt, brightness < 0.30 {
                let ring = self.manager.recentFrames(3) ?? []
                let times = ring.map { $0.time }
                if MFNR.canMerge(times: times),
                   let merged = MFNR.composite(ring.map { $0.image }, context: self.pipeline.renderContext) {
                    await self.processAndSave(
                        merged, beauty: beauty,
                        retroNote: String(format: "MFNR 3帧降噪(暗光%.0f%%)", brightness * 100))
                    return
                }
            }
            await self.processAndSave(frame, beauty: beauty)
        }
    }

    /// 回溯快门:痛点"快门按下去的瞬间,笑刚好停了/手抖了/孩子跑出焦了"。
    /// 帧环保有快门前 ~2s(60帧@30fps),全量打分后选综合最优帧走正常落盘链。
    func captureRetro() {
        let frames = manager.recentFrames(60) ?? []
        guard frames.count >= 12 else {
            lastSavedPath = "回溯失败:帧环不足(\(manager.ringCount)/12)"
            return
        }
        let beauty = settings
        let pipeline = self.pipeline
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ctx = pipeline.renderContext
            // 逐帧打分:清晰度为纲,曝光贴近 50 加权;隔帧采样降一半算力。
            // P0②:有脸时叠加脸区分数(权重 0.5)—— 背景再清晰,脸糊不算好抓拍
            var best: (index: Int, score: Double, image: CIImage)?
            for (i, f) in frames.enumerated() where i % 2 == 0 {
                let a = AIAnalyzer.analyze(f.image, context: ctx)
                var score = a.blurScore * 0.6 + a.exposureScore * 0.4
                if a.faceCount > 0, let cg = ctx.createCGImage(f.image, from: f.image.extent) {
                    let faceScore = AIAnalyzer.sharpnessScore(cgImage: cg, faceRect: a.faceRect)
                    score = a.blurScore * 0.3 + a.exposureScore * 0.2 + faceScore * 0.5
                }
                if best == nil || score > best!.score { best = (i, score, f.image) }
            }
            guard let pick = best else {
                await MainActor.run { self.lastSavedPath = "回溯失败:无候选帧" }
                return
            }
            await self.processAndSave(
                pick.image, beauty: beauty,
                retroNote: "回溯快门:扫描\(frames.count)帧取#\(pick.index),综合分\(Int(pick.score))")
        }
    }

    /// 拍照全流程:体检 → 低分自动修正 → 美颜链 → 落盘(图 + 伴生 JSON 报告)
    /// 顺序语义:AI 修正对齐技术指标在前,用户显式美颜意图在后(修正不对抗美颜)
    fileprivate func processAndSave(_ raw: CIImage, beauty: FilterSettings, retroNote: String? = nil) async {
        let ctx = pipeline.renderContext
        let analysis = AIAnalyzer.analyze(raw, context: ctx)
        var finalImage = raw
        var applied: [String] = []

        // 双路同框:PIP 小窗烧进成片(右上角),主摄+并发采集证据一图两用
        let pipSnapshot = await MainActor.run { [weak self] in Array((self?.pipFrames ?? [:]).values) }
        for (idx, pip) in pipSnapshot.enumerated() where idx < 3 {
            let pw = finalImage.extent.width * 0.24
            let scaled = pip.applyingFilter("CILanczosScaleTransform", parameters: [
                kCIInputScaleKey: pw / pip.extent.width,
            ])
            let ph = scaled.extent.height
            let x = finalImage.extent.maxX - pw - 12
            let y = finalImage.extent.maxY - ph - 12 - CGFloat(idx) * (ph + 8)
            let placed = scaled.transformed(by: CGAffineTransform(translationX: x, y: y))
            finalImage = placed.applyingFilter("CISourceOverCompositing", parameters: [
                kCIInputBackgroundImageKey: finalImage,
            ])
            applied.append("PIP同框×\(idx + 1)")
        }

        // 低分 → AI 修正落成片(修正前后都会重打分留证)
        // 美颜纳入修正链:人脸在场即触发质感兜底(用户显式开磨皮时 AIAnalyzer 内自动跳过防双重涂抹)
        if analysis.blurScore < 55 || analysis.faceCount > 0 || abs(analysis.colorCast) >= 8 || abs(analysis.exposureBias) > 0.18 {
            let corrected = AIAnalyzer.autoCorrect(raw, analysis: analysis, userSmoothing: beauty.smoothing,
                                                   enabled: enabledAICorrections)
            finalImage = corrected.image
            applied += corrected.appliedNames   // 追加不覆盖:保留前面的 PIP同框 标记
        }

        // 美颜层最后套(与预览同一条链,拍前所见即所得)
        if !beauty.isNeutral {
            finalImage = pipeline.apply(finalImage, settings: beauty, time: .zero)
        }

        // EXIF 元数据(设备实参:ISO/曝光时间/光圈/镜头)+ PNG 无损保底
        let device = manager.devices.first { $0.uniqueID == manager.activeDeviceID }
        let meta = CameraManager.captureMetadata(device: device)
        guard let cgFinal = pipeline.renderContext.createCGImage(finalImage, from: finalImage.extent) else { return }
        let url = CameraManager.savePhoto(cg: cgFinal, exif: meta.exif, tiff: meta.tiff)

        // 修正效果复打分(before/after 同帧硬证据,写进伴生 JSON;含色偏复测)
        let after = AIAnalyzer.rescore(finalImage, context: ctx)  // (blur, exposure, colorCast, bias)
        let report = CaptureReport(
            beforeBlur: (analysis.blurScore * 10).rounded() / 10,
            beforeExposure: (analysis.exposureScore * 10).rounded() / 10,
            afterBlur: (after.blur * 10).rounded() / 10,
            afterExposure: (after.exposure * 10).rounded() / 10,
            applied: applied,
            improved: after.blur >= analysis.blurScore && abs(after.bias) <= abs(analysis.exposureBias),
            faceCount: analysis.faceCount,
            beforeColorCast: (analysis.colorCast * 10).rounded() / 10,
            afterColorCast: (after.colorCast * 10).rounded() / 10)
        if let url, let data = try? JSONEncoder().encode(report) {
            try? data.write(to: url.deletingPathExtension().appendingPathExtension("json"))
        }

        await MainActor.run { [weak self] in
            self?.lastSavedPath = retroNote ?? (url?.path ?? "保存失败")
            self?.lastAnalysis = analysis
            self?.lastCaptureReport = report
        }
    }

    // MARK: - 夜景(公共合成栈:对齐时域平均+夜景增益,再走 AI 修正链)
    func captureNight() {
        captureComposite(mode: .night)
    }

    // MARK: - 防抖(多帧对齐取平均,消手抖拖影;原亮度不增益,报告带对齐残差)
    func captureSteady() {
        captureComposite(mode: .steady)
    }

    // MARK: - HDR(堆栈降噪+阴影恢复+高光软肩;不宣称扩真动态范围,见 FrameCompositor 注释)
    func captureHDR() {
        captureComposite(mode: .hdr)
    }

    enum CompositeMode {
        case night, steady, hdr
        var label: String { self == .night ? "夜景" : self == .steady ? "防抖" : "HDR" }
        var frameCount: Int { 8 }
        var gain: Float { self == .night ? 1.9 : self == .steady ? 1.0 : 1.6 }
        var maxShift: Int { self == .steady ? 3 : 2 }
    }

    private var compositeInFlight = false
    private func captureComposite(mode: CompositeMode) {
        guard !compositeInFlight else {
            lastSavedPath = "\(mode.label)合成中,请稍候"
            return
        }
        compositeInFlight = true
        lastSavedPath = "\(mode.label)合成中…"
        let s = settings
        let pipeline = self.pipeline
        // 帧环 = 最近 2s 实拍历史(含手抖/运动),取末尾 N 帧合成
        guard let frames = manager.recentFrames(mode.frameCount * 2) else {
            lastSavedPath = "\(mode.label)失败:帧环不足(\(manager.ringCount)/\(mode.frameCount * 2))"
            compositeInFlight = false
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processComposite(frames, mode: mode, settings: s, pipeline: pipeline)
            await MainActor.run { [weak self] in self?.compositeInFlight = false }
        }
    }

    fileprivate func processComposite(_ frames: [(image: CIImage, time: CMTime)], mode: CompositeMode, settings s: FilterSettings, pipeline: FilterPipeline) async {
        let ctx = pipeline.renderContext
        // 夜拍/防抖痛点:快门按下瞬间手可能还在动,盲取末尾 N 帧会把"运动中最糊的帧"合成进去
        // (165005 样本失败根因)。策略:多取一倍候选帧,解码后按 Laplacian 锐度分选最锐的 N 帧,
        // 把"运动中"的帧从源头筛掉,再做时域平均。
        let candidateCount = mode.frameCount * 2
        let pool = frames.count >= candidateCount ? Array(frames.suffix(candidateCount)) : frames
        let scored: [(cg: CGImage, score: Double)] = pool.compactMap { f in
            guard let cg = ctx.createCGImage(pipeline.apply(f.image, settings: s, time: .zero), from: f.image.extent) else { return nil }
            return (cg, AIAnalyzer.sharpnessScore(cgImage: cg))
        }
        guard scored.count >= mode.frameCount else {
            await MainActor.run { [weak self] in self?.lastSavedPath = "\(mode.label)失败:帧解码失败(\(scored.count)/\(mode.frameCount))" }
            return
        }
        // 锐度降序取前 N;若最高分 < 25(全糊),照常合成但报告里如实标注
        let picked = scored.sorted { $0.score > $1.score }.prefix(mode.frameCount).map { $0.cg }
        let cgs = Array(picked)
        let sharpest = scored.map { $0.score }.max() ?? 0
        let frameSel = "选帧:候选\(scored.count)取\(mode.frameCount),最锐\(Int(sharpest))"

        if mode == .hdr {
            // HDR:堆栈降噪 + 阴影恢复 + 高光软肩
            let (hdrCG, stats) = FrameCompositor.hdrToneMap(cgs)
            guard let hdrCG else {
                await MainActor.run { [weak self] in self?.lastSavedPath = stats }
                return
            }
            let hdrCI = CIImage(cgImage: hdrCG)
            let analysis = AIAnalyzer.analyze(hdrCI, context: ctx)
            let meta = CameraManager.captureMetadata(device: manager.devices.first { $0.uniqueID == manager.activeDeviceID })
            let url = CameraManager.savePhoto(cg: hdrCG, exif: meta.exif, tiff: meta.tiff)
            let report = CaptureReport(
                beforeBlur: 0, beforeExposure: 0,
                afterBlur: analysis.blurScore, afterExposure: analysis.exposureScore,
                applied: ["HDR堆栈降噪x8", "阴影恢复γ0.45", "高光软肩", stats],
                improved: true, faceCount: analysis.faceCount)
            if let url, let data = try? JSONEncoder().encode(report) {
                try? data.write(to: url.deletingPathExtension().appendingPathExtension("json"))
            }
            await MainActor.run { [weak self] in
                self?.lastSavedPath = url?.path ?? "\(mode.label)保存失败"
                self?.lastCaptureReport = report
            }
            return
        }

        // 夜景 / 防抖:运动补偿时域平均
        let comp = FrameCompositor.motionCompensatedAverage(cgs, gain: mode.gain, maxShift: mode.maxShift)
        guard let composedCG = comp.image else {
            let reason = comp.kept < 4 ? "运动帧过多(\(comp.dropped)/\(cgs.count)弃用)" : "解码失败"
            await MainActor.run { [weak self] in self?.lastSavedPath = "\(mode.label)失败:\(reason)" }
            return
        }
        let composedCI = CIImage(cgImage: composedCG)
        let analysis = AIAnalyzer.analyze(composedCI, context: ctx)
        var final = composedCI
        var applied = mode == .night
            ? ["\(cgs.count)帧时域平均", "运动补偿对齐", "夜景增益x\(mode.gain)", frameSel]
            : ["\(cgs.count)帧对齐平均", "搜索窗±\(mode.maxShift)px", "对齐残差\(String(format: "%.3f", comp.residual))→未对齐\(String(format: "%.3f", comp.naiveResidual))", frameSel]
        if comp.dropped > 0 { applied.append("弃运动帧\(comp.dropped)") }
        if analysis.blurScore < 55 || abs(analysis.colorCast) >= 8 || abs(analysis.exposureBias) > 0.18 {
            let (fixed, fixes) = AIAnalyzer.autoCorrect(composedCI, analysis: analysis)
            final = fixed
            applied += fixes
        }
        let meta = CameraManager.captureMetadata(device: manager.devices.first { $0.uniqueID == manager.activeDeviceID })
        var url: URL?
        if let cgFinal = ctx.createCGImage(final, from: final.extent) {
            url = CameraManager.savePhoto(cg: cgFinal, exif: meta.exif, tiff: meta.tiff)
        }
        let after = AIAnalyzer.rescore(final, context: ctx)
        let report = CaptureReport(
            beforeBlur: (analysis.blurScore * 10).rounded() / 10,
            beforeExposure: (analysis.exposureScore * 10).rounded() / 10,
            afterBlur: (after.blur * 10).rounded() / 10,
            afterExposure: (after.exposure * 10).rounded() / 10,
            applied: applied,
            improved: after.exposure > analysis.exposureScore || abs(after.bias) < abs(analysis.exposureBias),
            faceCount: analysis.faceCount,
            beforeColorCast: (analysis.colorCast * 10).rounded() / 10,
            afterColorCast: (after.colorCast * 10).rounded() / 10)
        if let url, let data = try? JSONEncoder().encode(report) {
            try? data.write(to: url.deletingPathExtension().appendingPathExtension("json"))
        }
        await MainActor.run { [weak self] in
            self?.lastSavedPath = url?.path ?? "\(mode.label)保存失败"
            self?.lastAnalysis = analysis
            self?.lastCaptureReport = report
        }
    }

    // MARK: - 连拍(burst:每 3 帧落一张,共 10 张;AI 选最清晰一张)
    private var burstInFlight = false
    func captureBurst() {
        guard !burstInFlight else { return }
        guard manager.ringCount >= 12 else {
            lastSavedPath = "连拍失败:帧环不足(\(manager.ringCount)/12)"
            return
        }
        burstInFlight = true
        let s = settings
        let pipeline = self.pipeline
        // 帧环取最近 30 帧,每 3 帧一张 = 10 张连拍
        let frames = manager.recentFrames(30) ?? []
        let activeDev = manager.devices.first { $0.uniqueID == manager.activeDeviceID }
        Task.detached(priority: .userInitiated) { [weak self] in
            let ctx = pipeline.renderContext
            var scored: [(url: URL, blur: Double)] = []
            for (idx, f) in frames.enumerated() where idx % 3 == 0 {
                let img = pipeline.apply(f.image, settings: s, time: .zero)
                guard let cg = ctx.createCGImage(img, from: img.extent) else { continue }
                let blur = AIAnalyzer.analyze(img, context: ctx).blurScore
                let meta = CameraManager.captureMetadata(device: activeDev)
                guard let url = CameraManager.savePhoto(cg: cg, exif: meta.exif, tiff: meta.tiff) else { continue }
                scored.append((url, blur))
            }
            let best = scored.max(by: { $0.blur < $1.blur })
            await MainActor.run { [weak self] in
                self?.lastSavedPath = best.map { "连拍10张,AI选片:\($0.url.lastPathComponent) (清晰度\(Int($0.blur)))" } ?? "连拍失败"
                self?.burstInFlight = false
            }
        }
    }

    // MARK: - 录像(主线程调用)
    func startRecording() {
        let s = settings
        let pipeline = self.pipeline
        // PIP 不再烧入主画面:每路 PIP 是一条独立视频辅轨(manager.writePIPFrame 实时写入,
        // 同一 writer 同一主机钟 root clock,成片双 v 流可多机位拆轨)
        manager.recordFilter = { image, time in
            guard !s.isNeutral else { return image }
            return pipeline.apply(image, settings: s, time: time, quality: .video)
        }
        manager.startRecording()
    }

    func stopRecording() {
        manager.stopRecording { [weak self] url in
            guard let self else { return }
            // 成片音频打标:静音检测终值写入伴生 JSON(与照片 CaptureReport 同目录同命名)
            self.lastVideoAudioSilent = self.manager.lastRecordingAudioSilent
            if let url, let peak = self.manager.lastRecordingAudioPeak as Double? {
                let report: [String: Any] = [
                    "audioSilent": self.lastVideoAudioSilent,
                    "audioPeak": peak,
                    "audioPeakDB": peak > 0 ? 20 * log10(peak) : -200.0,
                    "note": self.lastVideoAudioSilent
                        ? "音轨静音:采集源无声音输入(录制中已实时告警)"
                        : "音轨正常",
                ]
                if let data = try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted]) {
                    try? data.write(to: url.deletingPathExtension().appendingPathExtension("audio.json"))
                }
            }
            self.lastSavedPath = url.map { "视频已保存 \($0.path)\(self.lastVideoAudioSilent ? " ⚠️音轨静音" : "")" } ?? "录像保存失败"
        }
    }

    // MARK: - 相机操作转发
    func switchDevice(_ id: String) { manager.switchDevice(to: id) }
    func togglePIP(_ id: String) { manager.togglePIP(id) }

    // MARK: - 手动曝光/对焦
    /// 手动曝光走滤镜链软件 EV(macOS 硬件无曝光 API,FilterPipeline 段位 0)
    var exposureBiasRange: ClosedRange<Double> { -2.0...2.0 }
    var aeBiasEV: Double {
        get { settings.exposureEV }
        set { settings.exposureEV = newValue }
    }

    /// 对焦锁定/交还(macOS 无 lensPosition 手动对焦,用模式切换+峰值验证工作流)
    var isFocusLocked: Bool = false
    func toggleFocusLock() {
        isFocusLocked.toggle()
        manager.setFocusMode(isFocusLocked ? .locked : .continuousAutoFocus)
    }

    /// 对焦峰值开关(渲染层,任意源可用)
    func setFocusPeaking(_ on: Bool) {
        settings.focusPeaking = on ? 0.8 : 0
    }

    // MARK: - 变焦(硬件优先,软件兜底,互斥路由)
    /// UI/自动化统一入口。硬件档直接动 device.videoZoomFactor;
    /// 合成源/屏流/无硬件 zoom 设备走滤镜链中心裁切,预览录像拍照所见即所得。
    /// 档位跳变痛点:1x→4x 硬切画面猛跳。此处对目标倍率做缓动逼近(≈24帧过渡),
    /// 预览每帧收到平滑递增的 softwareZoom,人眼无跳变;硬件档(iOS)由系统动画,不经此路径。
    private var zoomAnimTimer: Timer?
    func setZoom(_ factor: Double, animated: Bool = true) {
        zoomAnimTimer?.invalidate()
        let from = manager.zoomFactor
        let clamped = min(max(factor, 1.0), 8.0)
        guard animated, abs(clamped - from) > 0.01 else {
            manager.setZoom(clamped)
            return
        }
        // easeOutCubic 逼近:前快后慢,体感跟手
        let steps = 24
        var i = 0
        zoomAnimTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 120.0, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            i += 1
            let p = Double(i) / Double(steps)
            let eased = 1 - pow(1 - p, 3)
            let v = from + (clamped - from) * eased
            if i >= steps {
                t.invalidate()
                self.zoomAnimTimer = nil
                self.manager.setZoom(clamped)
            } else {
                self.manager.setZoom(v)
            }
        }
    }
    var zoom: Double { manager.zoomFactor }
    var zoomIsHardware: Bool { manager.zoomIsHardware }
}
