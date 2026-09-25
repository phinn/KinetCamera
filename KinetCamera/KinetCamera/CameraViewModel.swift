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
        let filtered = pipeline.apply(frame, settings: settings, time: .zero)
        let ctx = pipeline.renderContext
        Task.detached(priority: .userInitiated) { [weak self] in
            // 拍照即体检,按结果自动修正
            let analysis = AIAnalyzer.analyze(filtered, context: ctx)
            var finalImage = filtered
            if analysis.exposureScore < 35 {
                finalImage = finalImage.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.6])
                finalImage = finalImage.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: 0.2])
            } else if analysis.exposureScore > 78 {
                finalImage = finalImage.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.45])
                finalImage = finalImage.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.08])
            }
            if analysis.blurScore < 40 {
                finalImage = finalImage.applyingFilter("CISharpenLuminance", parameters: [
                    kCIInputRadiusKey: 6, "inputSharpness": 0.6,
                ])
            }
            guard let nsImage = CameraManager.ciToNSImage(finalImage) else { return }
            let url = CameraManager.savePNG(nsImage)
            let resultAnalysis = analysis
            await MainActor.run { [weak self] in
                self?.lastSavedPath = url?.path ?? "保存失败"
                self?.lastAnalysis = resultAnalysis
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
}
