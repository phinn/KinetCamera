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

    private weak var renderView: CIRenderView?
    private var analysisInFlight = false
    private var cancellables = Set<AnyCancellable>()
    /// 主预览帧计数(automation 需要读)
    var frameCount = 0

    init() {
        manager.onFrame = { [weak self] image, _ in
            self?.handleFrame(image)
        }
        manager.onPIPFrame = { [weak self] id, image in
            DispatchQueue.main.async {
                self?.pipFrames[id] = image
            }
        }
        // 屏流伪设备帧回流 PIP 字典(与摄像头 PIP 同一条成片合成路径)
        manager.screenSource.onFrame = { [weak self] id, image in
            DispatchQueue.main.async {
                self?.pipFrames[id] = image
            }
        }
        // manager 的状态变化透传给观察 vm 的视图
        manager.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &cancellables)
        // 自动化美颜接口
        NotificationCenter.default.addObserver(
            forName: Notification.Name("kinetSetBeauty"), object: nil, queue: .main
        ) { [weak self] note in
            guard let ui = note.userInfo else { return }
            self?.settings.smoothing = ui["smoothing"] as? Double ?? 0
            self?.settings.whitening = ui["whitening"] as? Double ?? 0
        }
    }

    /// 画中画当前帧(设备ID → 帧)
    @Published var pipFrames: [String: CIImage] = [:]

    // MARK: - 帧处理(videoQueue 调用)
    fileprivate nonisolated func handleFrame(_ raw: CIImage) {
        let filtered = pipeline.apply(raw, settings: settings, time: .zero)
        frameCount &+= 1
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
                    self?.analysisInFlight = false
                }
            }
        }
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
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processAndSave(frame, beauty: beauty)
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
            // 逐帧打分:清晰度为纲,曝光贴近 50 加权;隔帧采样降一半算力
            var best: (index: Int, score: Double, image: CIImage)?
            for (i, f) in frames.enumerated() where i % 2 == 0 {
                let a = AIAnalyzer.analyze(f.image, context: ctx)
                let score = a.blurScore - abs(a.exposureScore - 50) * 0.5
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
        if analysis.blurScore < 55 || analysis.exposureScore < 42 || analysis.exposureScore > 78 || analysis.faceCount > 0 {
            let corrected = AIAnalyzer.autoCorrect(raw, analysis: analysis, userSmoothing: beauty.smoothing)
            finalImage = corrected.image
            applied += corrected.appliedNames   // 追加不覆盖:保留前面的 PIP同框 标记
        }

        // 美颜层最后套(与预览同一条链,拍前所见即所得)
        if !beauty.isNeutral {
            finalImage = pipeline.apply(finalImage, settings: beauty, time: .zero)
        }

        guard let nsImage = CameraManager.ciToNSImage(finalImage) else { return }
        let url = CameraManager.savePNG(nsImage)

        // 修正效果复打分(before/after 同帧硬证据,写进伴生 JSON)
        let after = AIAnalyzer.rescore(finalImage, context: ctx)
        let report = CaptureReport(
            beforeBlur: (analysis.blurScore * 10).rounded() / 10,
            beforeExposure: (analysis.exposureScore * 10).rounded() / 10,
            afterBlur: (after.blur * 10).rounded() / 10,
            afterExposure: (after.exposure * 10).rounded() / 10,
            applied: applied,
            improved: after.blur >= analysis.blurScore && abs(after.exposure - 50) <= abs(analysis.exposureScore - 50),
            faceCount: analysis.faceCount)
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
        guard let frames = manager.recentFrames(mode.frameCount) else {
            lastSavedPath = "\(mode.label)失败:帧环不足(\(manager.ringCount)/\(mode.frameCount))"
            compositeInFlight = false
            return
        }
        Task.detached(priority: .userInitiated) { [weak self] in
            await self?.processComposite(frames, mode: mode, settings: s, pipeline: pipeline)
            await MainActor.run { self?.compositeInFlight = false }
        }
    }

    fileprivate func processComposite(_ frames: [(image: CIImage, time: CMTime)], mode: CompositeMode, settings s: FilterSettings, pipeline: FilterPipeline) async {
        let ctx = pipeline.renderContext
        let filtered = frames.map { pipeline.apply($0.image, settings: s, time: .zero) }
        let cgs = filtered.compactMap { ctx.createCGImage($0, from: $0.extent) }
        guard cgs.count == mode.frameCount else {
            await MainActor.run { [weak self] in self?.lastSavedPath = "\(mode.label)失败:帧解码失败(\(cgs.count)/\(mode.frameCount))" }
            return
        }

        if mode == .hdr {
            // HDR:堆栈降噪 + 阴影恢复 + 高光软肩
            let (hdrCG, stats) = FrameCompositor.hdrToneMap(cgs)
            guard let hdrCG else {
                await MainActor.run { [weak self] in self?.lastSavedPath = stats }
                return
            }
            let hdrCI = CIImage(cgImage: hdrCG)
            let analysis = AIAnalyzer.analyze(hdrCI, context: ctx)
            guard let nsImage = CameraManager.ciToNSImage(hdrCI) else { return }
            let url = CameraManager.savePNG(nsImage)
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
            ? ["\(cgs.count)帧时域平均", "运动补偿对齐", "夜景增益x\(mode.gain)"]
            : ["\(cgs.count)帧对齐平均", "搜索窗±\(mode.maxShift)px", "对齐残差\(String(format: "%.3f", comp.residual))→未对齐\(String(format: "%.3f", comp.naiveResidual))"]
        if comp.dropped > 0 { applied.append("弃运动帧\(comp.dropped)") }
        if analysis.blurScore < 55 || analysis.exposureScore < 42 || analysis.exposureScore > 78 {
            let (fixed, fixes) = AIAnalyzer.autoCorrect(composedCI, analysis: analysis)
            final = fixed
            applied += fixes
        }
        guard let nsImage = CameraManager.ciToNSImage(final) else { return }
        let url = CameraManager.savePNG(nsImage)
        let after = AIAnalyzer.rescore(final, context: ctx)
        let report = CaptureReport(
            beforeBlur: (analysis.blurScore * 10).rounded() / 10,
            beforeExposure: (analysis.exposureScore * 10).rounded() / 10,
            afterBlur: (after.blur * 10).rounded() / 10,
            afterExposure: (after.exposure * 10).rounded() / 10,
            applied: applied,
            improved: after.exposure > analysis.exposureScore || abs(after.exposure - 50) < abs(analysis.exposureScore - 50),
            faceCount: analysis.faceCount)
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
        Task.detached(priority: .userInitiated) { [weak self] in
            let ctx = pipeline.renderContext
            var scored: [(url: URL, blur: Double)] = []
            for (idx, f) in frames.enumerated() where idx % 3 == 0 {
                let img = pipeline.apply(f.image, settings: s, time: .zero)
                guard let nsImage = CameraManager.ciToNSImage(img) else { continue }
                guard let url = CameraManager.savePNG(nsImage) else { continue }
                let blur = AIAnalyzer.analyze(img, context: ctx).blurScore
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
        manager.recordFilter = s.isNeutral ? nil : { image, time in
            pipeline.apply(image, settings: s, time: time)
        }
        manager.startRecording()
    }

    func stopRecording() {
        manager.stopRecording { [weak self] url in
            self?.lastSavedPath = url.map { "视频已保存 \($0.path)" } ?? "录像保存失败"
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
}
