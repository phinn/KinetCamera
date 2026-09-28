import Foundation
import CoreImage

// MARK: - CorrectionEngine:AI 场景自适应决策层(P0,规则引擎,零模型零黑盒)
//
// 定位:感知层(AIAnalyzer 每帧分数)→ 决策层(本文件,规则可解释)→ 执行层(FilterPipeline)。
// 不改用户滑杆设定值,只在自动档(autoAdapt=true)时输出微调偏移量,全部可解释、可关。
// 算力:<0.1ms/帧(纯标量规则),任何设备零压力。

/// 场景自适应后的美颜微调偏移(作用于 FilterSettings 的增量,非绝对值)
struct BeautyAdjustment: Equatable {
    var smoothingDelta: Double = 0    // +磨皮(暗光压噪)/-磨皮(强光保细节)
    var sharpenDelta: Double = 0      // 暗光补锐(压噪后细节损失补偿)
    var brighteningDelta: Double = 0  // 逆光/暗光提亮
    var reason: String = ""           // 人话解释(UI 可展示,拒绝黑盒)

    var isNeutral: Bool {
        smoothingDelta == 0 && sharpenDelta == 0 && brighteningDelta == 0
    }

    static let neutral = BeautyAdjustment()
}

enum CorrectionEngine {

    /// 场景自适应规则(输入帧分析分数,输出美颜微调)。
    /// 阈值依据:磨皮暗光反升实测(亮度<60 时 hf +19~25%,噪点被细节回注放大)钉死。
    /// - brightness: 0-1 帧均值亮度(AIAnalyzer 直方图均值/255)
    /// - blurScore: 0-100(AIAnalyzer Laplacian 高频能量)
    static func autoAdjust(brightness: Double, blurScore: Double, smoothing: Double) -> BeautyAdjustment {
        var adj = BeautyAdjustment()

        // 场景1:暗光(亮度<0.24 ≈ 60/255)——磨皮烧噪是根因,压噪优先,磨皮后补锐;
        // 同步预览提亮(2026-09-28 P0-2:取景黑拍完亮是竞品高频差评,预览所见即所得)
        if brightness < 0.24 {
            // 磨皮全关时不介入磨皮(用户意图明确:零磨皮),但提亮仍生效(暗光预览增益独立于美颜意图)
            if smoothing > 0.05 {
                adj.smoothingDelta = min(0.15, (0.24 - brightness) * 0.8)  // 越暗越多压,封顶+0.15
                adj.sharpenDelta = 0.08                                     // 压噪细节损失补偿
            } else {
                adj.sharpenDelta = 0
            }
            // 提亮增益:亮度 0.24→0 越暗越多,封顶 +0.50(EV≈0.28,亮度 6.8/255 的暗房实测拉到 ~25-30)
            // 注意:纯暗光预览也提亮,让用户取景时就能看到"夜视预览"效果,不再拍完才亮
            adj.brighteningDelta = min(0.50, (0.24 - brightness) * 2.2)
            adj.reason = smoothing > 0.05
                ? "暗光场景:自动提亮+压噪+补锐(夜视预览)"
                : "暗光场景:自动提亮(夜视预览)"
            return adj
        }

        // 场景2:强光顺光(亮度>0.78)——噪点少,磨皮需求低,减磨皮保毛孔质感(防塑料脸)
        if brightness > 0.78, smoothing > 0.3 {
            adj.smoothingDelta = -0.10
            adj.reason = "强光场景:自动减磨皮,保留皮肤质感"
            return adj
        }

        // 场景3:糊帧(画面失焦/手抖)——不补磨皮(糊上涂糊),提醒补锐
        if blurScore < 18, brightness >= 0.24 {
            adj.sharpenDelta = 0.12
            adj.reason = "画面偏糊:自动补锐(对焦拉风箱保护)"
            return adj
        }

        return .neutral
    }

    /// clamp 用户滑杆+自适应偏移后的最终值(0...1,越界即截断)
    static func clamp01(_ v: Double) -> Double { max(0, min(1, v)) }
}
