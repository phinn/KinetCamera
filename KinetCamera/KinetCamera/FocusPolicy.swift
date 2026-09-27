import Foundation
import CoreGraphics

// MARK: - FocusPolicy 再对焦抑制策略(P0③:拉风箱痛点)
// 痛点:连续自动对焦在人脸小幅移动/呼吸抖动时反复拉焦,画面"呼吸"、抓拍全糊。
// 策略:脸框面积/位移变化超过阈值才触发 re-focus,小幅抖动一律不动。

enum FocusPolicy {

    struct State: Equatable {
        var faceRect: CGRect?       // 上次对焦时的归一化脸框
        var lastRefocusTime: TimeInterval = 0
    }

    /// 是否需要 re-focus。
    /// - areaChange: 脸框面积相对变化 |A1-A0|/A0
    /// - centerMove: 脸框中心归一化位移
    /// - now/last: 秒(单调钟);冷却 1.2s 内绝不连拉(拉风箱主因就是无冷却连拉)
    static func shouldRefocus(
        previousFace: CGRect?, currentFace: CGRect?,
        areaChangeThreshold: Double = 0.15,
        moveThreshold: Double = 0.06,
        cooldown: Double = 1.2,
        now: TimeInterval, lastRefocus: TimeInterval
    ) -> Bool {
        // 冷却期:绝不连拉
        guard now - lastRefocus >= cooldown else { return false }
        // 从无脸到有脸:初见必对(唯一必对场景)
        guard let p = previousFace, let c = currentFace else {
            return currentFace != nil && previousFace == nil
        }
        // 脸丢失(当前无脸):不对焦,等稳定
        guard p.width > 0.001, p.height > 0.001 else { return false }

        // 面积变化>15%(人物前后移动,景深边界)
        let areaDelta = abs(c.width * c.height - p.width * p.height) / (p.width * p.height)
        if areaDelta > areaChangeThreshold { return true }

        // 中心位移>6%(换人入镜/大幅转头走位)
        let dcx = abs(c.midX - p.midX), dcy = abs(c.midY - p.midY)
        if max(dcx, dcy) > moveThreshold { return true }

        return false
    }
}
