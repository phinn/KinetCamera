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

        // 低分 → AI 修正落成片(修正前后都会重打分留证)
        if analysis.blurScore < 55 || analysis.exposureScore < 42 || analysis.exposureScore > 78 {
            (finalImage, applied) = AIAnalyzer.autoCorrect(finalImage, analysis: analysis)
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

    // MARK: - 夜景(多帧降噪合成:取最近 8 帧,亮度对齐后时域平均,等效延长曝光)
    func captureNight() {
        guard let frames = manager.recentFrames(8), frames.count == 8 else {
            lastSavedPath = "夜景失败:帧环不足(\(manager.ringCount)/8)"
            return
        }
        lastSavedPath = "夜景合成中…"
        let s = settings
        let pipeline = self.pipeline
        Task.detached(priority: .userInitiated) { [weak self] in
            guard let self else { return }
            let ctx = pipeline.renderContext
            // 每帧先过滤镜链(与预览一致),再取灰度
            let filtered = frames.map { pipeline.apply($0.image, settings: s, time: .zero) }
            let cgs = filtered.compactMap { ctx.createCGImage($0, from: $0.extent) }
            guard cgs.count == 8, let first = cgs.first else {
                await MainActor.run { [weak self] in self?.lastSavedPath = "夜景失败:帧解码失败" }
                return
            }
            let w = first.width, h = first.height

            // —— 运动补偿:灰度块匹配估全局平移,超限弃帧,防时域平均鬼影 ——
            func grayBytes(_ cg: CGImage) -> [UInt8]? {
                guard let ctx = CGContext(
                    data: nil, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
                ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
                guard let data = ctx.data else { return nil }
                return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h))
            }
            let grays = cgs.compactMap { grayBytes($0) }
            guard grays.count == 8 else {
                await MainActor.run { [weak self] in self?.lastSavedPath = "夜景失败:灰度解码失败" }
                return
            }
            let refGray = grays[0]
            // SAD(stride 4)在 ±2px 窗口内搜最佳平移
            func sadAt(_ g: [UInt8], dx: Int, dy: Int) -> Int {
                var sum = 0
                var y = 2
                while y < h - 2 {
                    var x = 2
                    while x < w - 2 {
                        let ry = y + dy, rx = x + dx
                        if ry >= 0, ry < h, rx >= 0, rx < w {
                            sum += abs(Int(g[y * w + x]) - Int(refGray[ry * w + rx]))
                        }
                        x += 4
                    }
                    y += 4
                }
                return sum
            }
            var offsets: [(dx: Int, dy: Int)] = []
            var droppedMotion = 0
            for g in grays {
                var best = (dx: 0, dy: 0, sad: sadAt(g, dx: 0, dy: 0))
                for dy in -2...2 {
                    for dx in -2...2 where dx != 0 || dy != 0 {
                        let s = sadAt(g, dx: dx, dy: dy)
                        if s < best.sad { best = (dx, dy, s) }
                    }
                }
                // 平移超出补偿窗口 → 运动过猛,弃帧防鬼影
                if max(abs(best.dx), abs(best.dy)) >= 2 { droppedMotion += 1; continue }
                offsets.append((best.dx, best.dy))
            }
            let kept = offsets.count
            guard kept >= 4 else {
                await MainActor.run { [weak self] in
                    self?.lastSavedPath = "夜景失败:运动帧过多(\(droppedMotion)/8弃用)"
                }
                return
            }

            guard let outCtx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }

            var acc = [UInt32](repeating: 0, count: w * h * 4)
            outCtx.setFillColor(CGColor(gray: 0, alpha: 1))
            for (idx, cg) in cgs.enumerated() where idx < offsets.count {
                let off = offsets[idx]
                // 按估计平移对齐后累加(补偿帧间全局运动)
                outCtx.clear(CGRect(x: 0, y: 0, width: w, height: h))
                outCtx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                outCtx.draw(cg, in: CGRect(x: CGFloat(off.dx), y: CGFloat(off.dy), width: CGFloat(w), height: CGFloat(h)))
                guard let data = outCtx.data else { continue }
                let p = data.assumingMemoryBound(to: UInt8.self)
                for i in 0..<(w * h * 4) { acc[i] &+= UInt32(p[i]) }
            }
            // 平均 + 夜景增益(等效多倍感光,压噪声靠时域平均)
            var outBytes = [UInt8](repeating: 0, count: w * h * 4)
            let gain: Float = 1.9   // 平均后亮度回拉,补偿时域平均的"变暗"
            let denom = Float(kept)
            for i in 0..<(w * h * 4) {
                let avg = Float(acc[i]) / denom
                outBytes[i] = UInt8(max(0, min(255, Int(avg * gain))))
            }
            let composed = outBytes.withUnsafeBytes { ptr -> CGImage? in
                guard let c = CGContext(
                    data: UnsafeMutableRawPointer(mutating: ptr.baseAddress),
                    width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                return c.makeImage()
            }
            guard let composedCG = composed else { return }
            // 合成图走 AI 修正链再体检落盘(与普通拍照同一出口)
            let composedCI = CIImage(cgImage: composedCG)
            let analysis = AIAnalyzer.analyze(composedCI, context: ctx)
            var final = composedCI
            var applied = ["8帧时域平均", "运动补偿对齐", "夜景增益x1.9"]
            if droppedMotion > 0 { applied.append("弃运动帧\(droppedMotion)") }
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
                self?.lastSavedPath = url?.path ?? "夜景保存失败"
                self?.lastAnalysis = analysis
                self?.lastCaptureReport = report
            }
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
