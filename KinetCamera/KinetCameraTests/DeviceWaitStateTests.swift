import XCTest
@testable import KinetCamera

/// 设备等待状态机四路径:离线→等待 / 超时→降级 / 上线→热恢复 / 即时接管。
/// 用 deviceProbe 注入假设备存在性,不碰真 AVCaptureSession;
/// Timer 走主 runloop(.common),XCTest expectation 驱动。
@MainActor
final class DeviceWaitStateTests: XCTestCase {

    override func setUp() {
        super.setUp()
        continueAfterFailure = false
    }

    /// 路径①:目标持续离线 → 每 1s 进入 waiting(n),attempt 递增
    func testPath1_offlineKeepsWaiting() {
        let mgr = CameraManager()
        mgr.deviceProbe = { _ in false }
        var seen: [CameraManager.DeviceWaitState] = []
        let exp = expectation(description: "2 waits")
        mgr.awaitDevice(id: "ghost-cam", timeoutAttempts: 4) { s in
            seen.append(s)
            if case .waiting(let n) = s, n == 2 { exp.fulfill() }
        }
        wait(for: [exp], timeout: 6)
        guard case .waiting(let n1) = seen[0] else { return XCTFail("expect waiting, got \(seen[0])") }
        guard case .waiting(let n2) = seen[1] else { return XCTFail("expect waiting, got \(seen[1])") }
        XCTAssertEqual(n1, 1)
        XCTAssertEqual(n2, 2, "attempt 必须逐秒递增")
        mgr.deviceProbe = nil
    }

    /// 路径②:超时未上线 → degraded + 原因可读,状态落定不再变
    func testPath2_timeoutDegrades() {
        let mgr = CameraManager()
        mgr.deviceProbe = { _ in false }
        var finalState: CameraManager.DeviceWaitState?
        var totalOutcomes = 0
        let exp = expectation(description: "degraded")
        mgr.awaitDevice(id: "ghost-cam", timeoutAttempts: 2) { s in
            totalOutcomes += 1
            if case .degraded(let reason) = s {
                finalState = s
                XCTAssertTrue(reason.contains("超时"), "降级原因必须可读:\(reason)")
                XCTAssertTrue(reason.contains("自动恢复"), "降级原因必须说明会热恢复:\(reason)")
                exp.fulfill()
            }
        }
        wait(for: [exp], timeout: 6)
        // 降级后 Timer 已失效,再等 1.5s 确认无多余回调(状态机不诈尸)
        let quiet = expectation(description: "quiet after degrade")
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { quiet.fulfill() }
        wait(for: [quiet], timeout: 3)
        XCTAssertLessThanOrEqual(totalOutcomes, 3, "降级后不应再有 outcome 回调")
        guard case .degraded = mgr.deviceWaitState else { return XCTFail("终态应是 degraded") }
        XCTAssertEqual(finalState.map { mgr.deviceWaitStatusMessage(for: $0).isEmpty }, false)
        mgr.deviceProbe = nil
    }

    /// 路径③:先离线等待,再上线 → waiting 若干次后热恢复为 idle
    func testPath3_onlineHotResume() {
        let mgr = CameraManager()
        var online = false
        mgr.deviceProbe = { _ in online }
        var seen: [CameraManager.DeviceWaitState] = []
        let exp = expectation(description: "hot resume")
        mgr.awaitDevice(id: "iphone-cc", timeoutAttempts: 10) { s in
            seen.append(s)
            if case .idle = s { exp.fulfill() }
        }
        // 2.5s 后设备"上线"(模拟解锁 iPhone 广播)
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { online = true }
        wait(for: [exp], timeout: 8)
        guard case .waiting(let first) = seen[0] else { return XCTFail("首回调应是 waiting") }
        XCTAssertEqual(first, 1)
        guard case .idle = seen.last else { return XCTFail("末回调应是 idle(热恢复)") }
        guard case .idle = mgr.deviceWaitState else { return XCTFail("状态机终态应是 idle") }
        mgr.deviceProbe = nil
    }

    /// 路径④:目标即时在线 → 首秒直接 idle 接管,不经过 waiting
    func testPath4_immediateTakeover() {
        let mgr = CameraManager()
        mgr.deviceProbe = { _ in true }
        var outcomes: [CameraManager.DeviceWaitState] = []
        let exp = expectation(description: "immediate idle")
        mgr.awaitDevice(id: "live-cam", timeoutAttempts: 10) { s in
            outcomes.append(s)
            exp.fulfill()
        }
        wait(for: [exp], timeout: 4)
        XCTAssertEqual(outcomes.count, 1, "即时在线只应有一次回调")
        guard case .idle = outcomes[0] else { return XCTFail("唯一回调应是 idle, got \(outcomes[0])") }
        mgr.deviceProbe = nil
    }

    /// 附加:等待中途换目标(重复 awaitDevice)——旧 Timer 必须被作废,不双跑
    func testRetargetInvalidatesOldTimer() {
        let mgr = CameraManager()
        mgr.deviceProbe = { _ in false }
        var aCount = 0
        var bDone = false
        let expA = expectation(description: "a waits")
        mgr.awaitDevice(id: "cam-a", timeoutAttempts: 30) { s in
            if case .waiting = s { aCount += 1; if aCount == 2 { expA.fulfill() } }
        }
        wait(for: [expA], timeout: 6)
        // 换目标:cam-b 第 1 秒即上线
        mgr.deviceProbe = { $0 == "cam-b" }
        let expB = expectation(description: "b resolves")
        mgr.awaitDevice(id: "cam-b", timeoutAttempts: 30) { s in
            if case .idle = s { bDone = true; expB.fulfill() }
        }
        wait(for: [expB], timeout: 6)
        // 再静置 2.5s:cam-a 的旧回调不得再来(旧 timer 已废)
        let quiet = expectation(description: "a stays dead")
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { quiet.fulfill() }
        wait(for: [quiet], timeout: 4)
        let aAfter = aCount
        XCTAssertLessThanOrEqual(aAfter, 2, "换目标后旧目标不得继续回调")
        XCTAssertTrue(bDone)
        mgr.deviceProbe = nil
    }
}

extension CameraManager {
    /// 单测可访问的状态文案(镜像 deviceWaitStatusMessage,避免 private 依赖)
    func deviceWaitStatusMessage(for state: DeviceWaitState) -> String {
        switch state {
        case .idle: return ""
        case .waiting(let n): return "等待设备上线…(\(n)s)"
        case .degraded(let r): return r
        }
    }
}
