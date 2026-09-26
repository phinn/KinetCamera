import XCTest
@testable import KinetCamera

/// 录像时基守卫纯决策单测:423861s 成片事故(设备切换 PTS 断崖)的防线锁死。
/// 决策面在 DevicePolicy,硬件路径由实机验收,这里把每条边界钉死。
final class TimebasePolicyTests: XCTestCase {

    // MARK: - 视频 PTS 断裂判定

    func testNormalFrameIntervalsPass() {
        // 30fps=0.033s / 24fps=0.042 / 网络摄掉帧到 0.3s 都算正常
        XCTAssertFalse(DevicePolicy.isPTSDiscontinuity(deltaSeconds: 0.0333))
        XCTAssertFalse(DevicePolicy.isPTSDiscontinuity(deltaSeconds: 0.0417))
        XCTAssertFalse(DevicePolicy.isPTSDiscontinuity(deltaSeconds: 0.3))
        XCTAssertFalse(DevicePolicy.isPTSDiscontinuity(deltaSeconds: 0.5), "0.5 恰在阈值内(>0.5 才断裂)")
    }

    func testForwardJumpIsDiscontinuity() {
        // 换设备后 PTS 大步前跳(小时级/天级时基差)
        XCTAssertTrue(DevicePolicy.isPTSDiscontinuity(deltaSeconds: 0.51))
        XCTAssertTrue(DevicePolicy.isPTSDiscontinuity(deltaSeconds: 42.0))
        XCTAssertTrue(DevicePolicy.isPTSDiscontinuity(deltaSeconds: 423861.0), "423861s 事故值必须命中")
    }

    func testBackwardJumpIsDiscontinuity() {
        // 新设备时基更小(PTS 倒跳):>0.2s 倒退即断裂
        XCTAssertFalse(DevicePolicy.isPTSDiscontinuity(deltaSeconds: -0.033), "轻倒跳≤0.2s 允许(帧重排)")
        XCTAssertFalse(DevicePolicy.isPTSDiscontinuity(deltaSeconds: -0.2), "恰 -0.2 在阈值内")
        XCTAssertTrue(DevicePolicy.isPTSDiscontinuity(deltaSeconds: -0.21))
        XCTAssertTrue(DevicePolicy.isPTSDiscontinuity(deltaSeconds: -3600.0))
    }

    // MARK: - 音频 PTS 平移守卫

    func testSafeAudioPTSAcceptsNormal() {
        XCTAssertEqual(DevicePolicy.safeAudioPTS(shiftedPTS: 0), 0, "恰 0 合法(音画同源起点)")
        XCTAssertEqual(DevicePolicy.safeAudioPTS(shiftedPTS: 1.024), 1.024)
        XCTAssertEqual(DevicePolicy.safeAudioPTS(shiftedPTS: 0.0001), 0.0001)
    }

    func testSafeAudioPTSRejectsNegativeAndNaN() {
        // 平移后仍为负 = 音频先于视频首帧,append 会触发 -16364,必须丢弃
        XCTAssertNil(DevicePolicy.safeAudioPTS(shiftedPTS: -0.001))
        XCTAssertNil(DevicePolicy.safeAudioPTS(shiftedPTS: -1000))
        // NaN/Inf(CMTime 无效值换算产物)必须挡在 writer 之外
        XCTAssertNil(DevicePolicy.safeAudioPTS(shiftedPTS: Double.nan))
        XCTAssertNil(DevicePolicy.safeAudioPTS(shiftedPTS: Double.infinity))
        XCTAssertNil(DevicePolicy.safeAudioPTS(shiftedPTS: -Double.infinity))
    }

    // MARK: - 帧环跨时基重置

    func testFrameRingResetOnSourceChange() {
        // 首帧(last=nil)不触发重置
        XCTAssertFalse(DevicePolicy.shouldResetFrameRing(newPTS: 0.033, lastPTS: nil))
        // 同源连续帧:不重置
        XCTAssertFalse(DevicePolicy.shouldResetFrameRing(newPTS: 1.0, lastPTS: 0.967))
        XCTAssertFalse(DevicePolicy.shouldResetFrameRing(newPTS: 2.3, lastPTS: 1.8))
        // 换源断裂(合成源 pts 从 0 起 vs 真机摄宿主时钟):重置
        XCTAssertTrue(DevicePolicy.shouldResetFrameRing(newPTS: 0.0, lastPTS: 102337.5))
        XCTAssertTrue(DevicePolicy.shouldResetFrameRing(newPTS: 102337.5, lastPTS: 0.0), "反向同样断裂")
    }

    // MARK: - 回归:时基守卫链路组合(平移→守卫→断裂判定)

    func testShiftThenGuardPipeline() {
        // 场景:宿主时钟音频 raw=102337.9,视频会话起点 sessionStartPTS=0.4
        // shift = raw - sessionStart = 102337.5;下一帧 raw=102337.933 → shifted=0.433 ✓
        let shift = 102337.9 - 0.4
        let shifted = 102337.933 - shift
        XCTAssertEqual(shifted, 0.433, accuracy: 1e-9)
        XCTAssertNotNil(DevicePolicy.safeAudioPTS(shiftedPTS: shifted))
        // 若 shift 未建(音频先到):shifted<0 → 丢弃,不写坏 writer
        XCTAssertNil(DevicePolicy.safeAudioPTS(shiftedPTS: 0.1 - 102337.5))
    }
}
