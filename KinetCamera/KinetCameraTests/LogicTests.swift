import XCTest
@testable import KinetCamera

/// 三摄切换守卫 + 变焦钳制 + AI 修正决策的纯逻辑单测。
/// 硬件无关,CI/真机同套;硬件路径由实机验收覆盖,这里锁死决策面。
final class DevicePolicyTests: XCTestCase {

    // MARK: - 切换守卫

    func testSwitchRejectedWhileRecording() {
        // 录像中一切切换都拒绝(防 AVAssetWriter 写坏文件)
        XCTAssertFalse(DevicePolicy.canSwitch(isRecording: true, current: "a", target: "b", liveDevices: ["a", "b"]))
        XCTAssertFalse(DevicePolicy.canSwitch(isRecording: true, current: "a", target: "a", liveDevices: ["a"]))
    }

    func testSwitchNoopOnSameDevice() {
        // 同设备重复切换 = no-op(防会话无谓重建 200ms 黑屏)
        XCTAssertFalse(DevicePolicy.canSwitch(isRecording: false, current: "a", target: "a", liveDevices: ["a"]))
    }

    func testSwitchRejectedForOfflineTarget() {
        // 目标已离线(拔掉的三摄/锁屏 iPhone)拒绝切换
        XCTAssertFalse(DevicePolicy.canSwitch(isRecording: false, current: "a", target: "ghost", liveDevices: ["a", "b"]))
    }

    func testSwitchAcceptedForLiveDifferentDevice() {
        XCTAssertTrue(DevicePolicy.canSwitch(isRecording: false, current: "a", target: "b", liveDevices: ["a", "b", "c"]))
        // 首次启动 current 为 nil 也放行
        XCTAssertTrue(DevicePolicy.canSwitch(isRecording: false, current: nil, target: "b", liveDevices: ["b"]))
    }

    // MARK: - 掉线接管

    func testFallbackKeepsLiveCurrent() {
        XCTAssertEqual(DevicePolicy.fallbackActive(current: "b", devices: ["a", "b"]), "b")
    }

    func testFallbackTakesFirstWhenCurrentDead() {
        XCTAssertEqual(DevicePolicy.fallbackActive(current: "dead", devices: ["a", "b"]), "a")
        XCTAssertEqual(DevicePolicy.fallbackActive(current: nil, devices: ["a"]), "a")
        XCTAssertNil(DevicePolicy.fallbackActive(current: nil, devices: []))
    }

    // MARK: - PIP 清理

    func testStalePIPsRemovedOnlyOffline() {
        // 屏流伪设备不在 live 枚举里,必须保留;离线真机 PIP 摘除;在线保留
        let pips = DevicePolicy.stalePIPs(pips: ["camB", "camGhost", "kinet.screen.0"],
                                          liveDevices: ["camA", "camB"],
                                          screenPseudoID: "kinet.screen.0")
        XCTAssertEqual(pips, ["camGhost"])
    }

    // MARK: - 变焦钳制

    func testZoomClampBounds() {
        XCTAssertEqual(DevicePolicy.clampZoom(0.5, formatMax: 120), 1.0)          // 不许缩小
        XCTAssertEqual(DevicePolicy.clampZoom(2.5, formatMax: 120), 2.5)
        XCTAssertEqual(DevicePolicy.clampZoom(50, formatMax: 120), 8.0)           // 画质红线 8x
        XCTAssertEqual(DevicePolicy.clampZoom(50, formatMax: 6.0), 6.0)           // 格式上限更紧
        XCTAssertEqual(DevicePolicy.clampZoom(4, formatMax: 1.0), 1.0)            // 不支持变焦的设备钳回 1
        // 无源态语义(manager 层传 qualityCeilingZoom 作 formatMax):目标值保留,不压回 1
        XCTAssertEqual(DevicePolicy.clampZoom(2.0, formatMax: DevicePolicy.qualityCeilingZoom), 2.0)
        XCTAssertEqual(DevicePolicy.qualityCeilingZoom, 8.0)
    }

    func testHardwareZoomAvailability() {
        XCTAssertFalse(DevicePolicy.hardwareZoomAvailable(formatMaxZoom: 1.0))    // 虚拟设备/合成源
        XCTAssertFalse(DevicePolicy.hardwareZoomAvailable(formatMaxZoom: 1.005))  // 容差内
        XCTAssertTrue(DevicePolicy.hardwareZoomAvailable(formatMaxZoom: 6.0))
        XCTAssertTrue(DevicePolicy.hardwareZoomAvailable(formatMaxZoom: 120))
    }
}

/// AI 修正决策面单测:白平衡分档/报告编解码链
final class AICorrectionTests: XCTestCase {

    func testWhiteBalanceGainLadder() {
        // 2026-09-26 改连续比例式(旧分档 0.18/0.35/0.5 对强暖图过校翻转偏冷,harness 实测 22.8→-26.7):
        // gain = min(0.30, |cast|/220),<6 视为噪声不动
        XCTAssertEqual(AIAnalyzer.whiteBalanceGain(forColorCast: 0), 0)       // 噪声内不动
        XCTAssertEqual(AIAnalyzer.whiteBalanceGain(forColorCast: 5), 0)
        XCTAssertEqual(AIAnalyzer.whiteBalanceGain(forColorCast: 12), 12.0/220.0, accuracy: 1e-9)   // 轻度
        XCTAssertEqual(AIAnalyzer.whiteBalanceGain(forColorCast: -25), 25.0/220.0, accuracy: 1e-9)  // 标准(冷偏同式)
        XCTAssertEqual(AIAnalyzer.whiteBalanceGain(forColorCast: 60), 60.0/220.0, accuracy: 1e-9)   // 比例区
        XCTAssertEqual(AIAnalyzer.whiteBalanceGain(forColorCast: -100), 0.30)  // 封顶 0.30
    }

    func testColorCastSymmetry() {
        // 冷暖对称分档:|cast| 相同 → 强度相同
        XCTAssertEqual(AIAnalyzer.whiteBalanceGain(forColorCast: 15),
                       AIAnalyzer.whiteBalanceGain(forColorCast: -15))
    }

    func testCaptureReportCodableRoundtrip() {
        let report = CaptureReport(
            beforeBlur: 12.3, beforeExposure: 88.1,
            afterBlur: 40.0, afterExposure: 52.7,
            applied: ["AI去暖(18)", "AI补锐"], improved: true, faceCount: 1,
            beforeColorCast: 18.4, afterColorCast: 6.2)
        let data = try! JSONEncoder().encode(report)
        let back = try! JSONDecoder().decode(CaptureReport.self, from: data)
        XCTAssertEqual(back, report)
        // 伴生 JSON 落盘格式核对:色偏字段必须在
        let obj = try! JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(obj["beforeColorCast"] as? Double, 18.4)
        XCTAssertEqual(obj["afterColorCast"] as? Double, 6.2)
    }

    // MARK: - 色偏检测(真实渲染,不 mock)

    func testColorCastDetectionOnSyntheticImages() throws {
        let ctx = FilterPipeline.shared.renderContext
        let w, h: Int; w = 320; h = 240

        func makeCG(r: UInt8, b: UInt8) -> CGImage {
            let bytes = [UInt8](repeating: 0, count: w * h * 4).map { _ in UInt8(255) }
            var px = bytes
            for i in 0..<(w * h) {
                px[i * 4] = r         // R
                px[i * 4 + 1] = 128   // G
                px[i * 4 + 2] = b     // B
            }
            let cs = CGColorSpaceCreateDeviceRGB()
            let ctx2 = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                                 bytesPerRow: w * 4, space: cs,
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            return ctx2.makeImage()!
        }

        // 暖图(R 高 B 低)→ 正色偏;冷图 → 负;中性 → 接近 0
        let warm = CIImage(cgImage: makeCG(r: 220, b: 80))
        let cool = CIImage(cgImage: makeCG(r: 80, b: 220))
        let neutral = CIImage(cgImage: makeCG(r: 128, b: 128))
        for (img, expect) in [(warm, 1), (cool, -1), (neutral, 0)] {
            guard let cg = ctx.createCGImage(img, from: img.extent) else {
                return XCTFail("render failed")
            }
            let cast = AIAnalyzer.colorCast(cg)
            switch expect {
            case 1: XCTAssertGreaterThan(cast, 30, "暖图应检出正色偏, got \(cast)")
            case -1: XCTAssertLessThan(cast, -30, "冷图应检出负色偏, got \(cast)")
            default: XCTAssertTrue(abs(cast) < 6, "中性图色偏应≈0, got \(cast)")
            }
        }
    }

    // MARK: - 软件变焦滤镜链(真实渲染)

    func testSoftwareZoomCropsAndRestoresExtent() {
        let ctx = FilterPipeline.shared.renderContext
        // 100x100 红图,中心 50x50 绿块;2x 软变焦后应整图变绿(中心裁切放大铺满)
        let full = CIImage(color: CIColor(red: 1, green: 0, blue: 0))
            .cropped(to: CGRect(x: 0, y: 0, width: 100, height: 100))
        let center = CIImage(color: CIColor(red: 0, green: 1, blue: 0))
            .cropped(to: CGRect(x: 25, y: 25, width: 50, height: 50))
        let img = center.composited(over: full)

        var s = FilterSettings.neutral
        s.softwareZoom = 2.0
        let zoomed = FilterPipeline.shared.apply(img, settings: s, time: .zero)
        XCTAssertEqual(Int(zoomed.extent.width), 100, "变焦后尺寸应复原(所见即所得)")
        XCTAssertEqual(Int(zoomed.extent.height), 100)

        var px = [UInt8](repeating: 0, count: 4)
        ctx.render(zoomed, toBitmap: &px, rowBytes: 4,
                   bounds: CGRect(x: 45, y: 45, width: 1, height: 1),
                   format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        XCTAssertGreaterThan(px[1], 200, "中心像素应为绿色(裁切放大后中心=原中心绿块), got R\(px[0]) G\(px[1]) B\(px[2])")
    }
}

// MARK: - CorrectionEngine 场景自适应规则(2026-09-27)
final class CorrectionEngineTests: XCTestCase {
    func testDarkSceneBoostsSmoothingAndSharpen() {
        let adj = CorrectionEngine.autoAdjust(brightness: 0.15, blurScore: 60, smoothing: 0.5)
        XCTAssertTrue(adj.smoothingDelta > 0)
        XCTAssertTrue(adj.sharpenDelta > 0)
        XCTAssertFalse(adj.reason.isEmpty)
    }
    func testDarkSceneNoSmoothingNoIntervention() {
        // 用户磨皮全关 = 明确意图,磨皮/补锐不介入;
        // 但暗光提亮仍生效(2026-09-28 P0-2:夜视预览独立于美颜意图,取景不再黑)
        let adj = CorrectionEngine.autoAdjust(brightness: 0.10, blurScore: 60, smoothing: 0.0)
        XCTAssertEqual(adj.smoothingDelta, 0)
        XCTAssertEqual(adj.sharpenDelta, 0)
        XCTAssertGreaterThan(adj.brighteningDelta, 0, "暗光夜视预览提亮独立于磨皮意图")
        XCTAssertFalse(adj.isNeutral)
        XCTAssertFalse(adj.reason.isEmpty)
    }
    func testDarkSceneBrighteningScalesWithDarkness() {
        // 越暗提亮越多,封顶 0.50
        let mild = CorrectionEngine.autoAdjust(brightness: 0.20, blurScore: 60, smoothing: 0.5)
        let dark = CorrectionEngine.autoAdjust(brightness: 0.05, blurScore: 60, smoothing: 0.5)
        XCTAssertGreaterThan(dark.brighteningDelta, mild.brighteningDelta)
        XCTAssertLessThanOrEqual(dark.brighteningDelta, 0.50)
    }
    func testBrightSceneReducesSmoothing() {
        let adj = CorrectionEngine.autoAdjust(brightness: 0.85, blurScore: 70, smoothing: 0.6)
        XCTAssertTrue(adj.smoothingDelta < 0, "强光应减磨皮保质感")
    }
    func testBrightSceneSmallSmoothingNoTouch() {
        // 磨皮本来就很低(≤0.3)时不画蛇添足
        let adj = CorrectionEngine.autoAdjust(brightness: 0.85, blurScore: 70, smoothing: 0.2)
        XCTAssertTrue(adj.isNeutral)
    }
    func testBlurryFrameAddsSharpen() {
        let adj = CorrectionEngine.autoAdjust(brightness: 0.5, blurScore: 12, smoothing: 0.5)
        XCTAssertTrue(adj.sharpenDelta > 0)
    }
    func testNormalSceneNeutral() {
        let adj = CorrectionEngine.autoAdjust(brightness: 0.5, blurScore: 60, smoothing: 0.5)
        XCTAssertTrue(adj.isNeutral)
    }
    func testDeltaCapped() {
        // 极暗场景磨皮增量封顶 0.15
        let adj = CorrectionEngine.autoAdjust(brightness: 0.0, blurScore: 60, smoothing: 0.8)
        XCTAssertLessThanOrEqual(adj.smoothingDelta, 0.15)
    }
    func testClamp01() {
        XCTAssertEqual(CorrectionEngine.clamp01(-0.5), 0)
        XCTAssertEqual(CorrectionEngine.clamp01(0.5), 0.5)
        XCTAssertEqual(CorrectionEngine.clamp01(1.5), 1)
    }
}

// MARK: - B3 连续变焦(virtual 摄位接力)策略
final class VirtualZoomPolicyTests: XCTestCase {
    func testVirtualRankOrder() {
        XCTAssertLessThan(DevicePolicy.virtualZoomRank(deviceType: "BuiltInTripleCamera"),
                          DevicePolicy.virtualZoomRank(deviceType: "BuiltInDualWideCamera"))
        XCTAssertLessThan(DevicePolicy.virtualZoomRank(deviceType: "BuiltInDualWideCamera"),
                          DevicePolicy.virtualZoomRank(deviceType: "BuiltInDualCamera"))
        XCTAssertLessThan(DevicePolicy.virtualZoomRank(deviceType: "BuiltInDualCamera"),
                          DevicePolicy.virtualZoomRank(deviceType: "BuiltInWideAngleCamera"))
        XCTAssertEqual(DevicePolicy.virtualZoomRank(deviceType: "anything"), 3)
    }
    func testZoomLensDescription() {
        // 软件档恒 software;单摄恒 single
        XCTAssertEqual(DevicePolicy.zoomLensDescription(zoomFactor: 3, isVirtual: false, isHardware: false), "software")
        XCTAssertEqual(DevicePolicy.zoomLensDescription(zoomFactor: 3, isVirtual: false, isHardware: true), "single")
        // virtual 按区间:<1 超广 / [1,5) 主摄 / ≥5 长焦
        XCTAssertEqual(DevicePolicy.zoomLensDescription(zoomFactor: 0.9, isVirtual: true, isHardware: true), "ultrawide")
        XCTAssertEqual(DevicePolicy.zoomLensDescription(zoomFactor: 1.0, isVirtual: true, isHardware: true), "wide")
        XCTAssertEqual(DevicePolicy.zoomLensDescription(zoomFactor: 4.9, isVirtual: true, isHardware: true), "wide")
        XCTAssertEqual(DevicePolicy.zoomLensDescription(zoomFactor: 5.0, isVirtual: true, isHardware: true), "telephoto")
    }
}
