import XCTest
@testable import KinetCamera

/// 视频专项回归:
///  A. 录像质量档语义(4K60/1080p30 的 fps、最小宽、preset 映射)
///  B. 变焦 clamp(1-8 质量上限,formatMax 二次收口)
///  C. PTS 豁免窗口:合成源摄位切换的帧间隙不应触发时基重对齐
final class VideoSpecTests: XCTestCase {

    // MARK: - A. 录像质量档

    func testRecordingQualityFpsAndWidth() {
        XCTAssertEqual(CameraManager.RecordingQuality.hd1080p30.fps, 30)
        XCTAssertEqual(CameraManager.RecordingQuality.uhd4k60.fps, 60)
        XCTAssertEqual(CameraManager.RecordingQuality.hd1080p30.minWidth, 1920)
        XCTAssertEqual(CameraManager.RecordingQuality.uhd4k60.minWidth, 3840)
    }

    func testRecordingQualityPresetMapping() {
        // preset 是会话级,能落到 1080p/4K 两档
        XCTAssertEqual(CameraManager.RecordingQuality.hd1080p30.sessionPreset, .hd1920x1080)
        XCTAssertEqual(CameraManager.RecordingQuality.uhd4k60.sessionPreset, .hd4K3840x2160)
    }

    func testRecordingQualityAllCasesHaveStableRaw() {
        // /video?preset= 依赖 rawValue 稳定性(自动化契约)
        XCTAssertEqual(CameraManager.RecordingQuality(rawValue: "hd1080p30"), .hd1080p30)
        XCTAssertEqual(CameraManager.RecordingQuality(rawValue: "uhd4k60"), .uhd4k60)
        XCTAssertNil(CameraManager.RecordingQuality(rawValue: "8k120"))
    }

    // MARK: - B. 变焦 clamp

    func testClampZoomBounds() {
        // 质量上限 8×;formatMax 再收口
        XCTAssertEqual(DevicePolicy.clampZoom(0.5, formatMax: 16), 1.0)
        XCTAssertEqual(DevicePolicy.clampZoom(99, formatMax: 16), 8.0)
        XCTAssertEqual(DevicePolicy.clampZoom(99, formatMax: 4), 4.0, "format 上限低于质量上限时以 format 为准")
        XCTAssertEqual(DevicePolicy.clampZoom(2, formatMax: 16), 2.0)
    }

    // MARK: - C. PTS 守卫(纯函数层)

    func testPTSDiscontinuityThresholds() {
        // 30fps 帧距 0.033s;倒跳>0.2s 或前跳>0.5s 判断裂
        XCTAssertFalse(DevicePolicy.isPTSDiscontinuity(deltaSeconds: 0.033))
        XCTAssertFalse(DevicePolicy.isPTSDiscontinuity(deltaSeconds: 0.4))
        XCTAssertTrue(DevicePolicy.isPTSDiscontinuity(deltaSeconds: -0.3))
        XCTAssertTrue(DevicePolicy.isPTSDiscontinuity(deltaSeconds: 0.6))
        // 摄位切换 pattern 重建实测产生 0.53~1.5s 间隙 —— 属"前跳断裂"带,由豁免窗口压制
        XCTAssertTrue(DevicePolicy.isPTSDiscontinuity(deltaSeconds: 1.512))
    }
}
