import Foundation

/// 导管规格(来自 benddata.json)
public struct ConduitSpec: Codable, Identifiable, Equatable {
    public let id: String                 // "emt-1/2"
    public let tradeSize: String          // "1/2\""
    public let type: String               // "EMT" / "RMC" / "IMC" / "PVC"
    /// take-up( Bender deduct):弯 90° 时弯管机吃掉的长度
    public let takeUpInches: Double
    /// shrink 系数:每英寸 offset 高度产生的缩短量(Benfield 表)
    public let shrinkPerInch: Double
    /// NEC Table 2 最小弯内半径( inches)
    public let minRadiusInches: Double

    public var label: String { "\(type) \(tradeSize)" }
}

public enum BendAngle: Double, CaseIterable, Identifiable {
    case a10 = 10
    case a22_5 = 22.5
    case a30 = 30
    case a45 = 45
    case a60 = 60

    public var id: Double { rawValue }
    public var degrees: Double { rawValue }

    /// Benfield 常数(标称角对应的 multiplier)
    public var multiplier: Double {
        switch self {
        case .a10: return 6.0
        case .a22_5: return 2.6
        case .a30: return 2.0
        case .a45: return 1.414
        case .a60: return 1.155
        }
    }

    /// 任意角度的精确 multiplier = 1 / sin(θ)
    public static func multiplier(degrees: Double) -> Double {
        guard degrees > 0.5 else { return .infinity }
        return 1.0 / sin(degrees * .pi / 180.0)
    }
}

// MARK: - 90° Stub-Up

public struct StubUpResult: Equatable {
    /// 第一标记(与弯管机箭头对齐的位置)
    public let mark1: FractionInch
    /// 第二标记(终点)
    public let mark2: FractionInch
    /// take-up 值(显示用)
    public let takeUp: FractionInch
    /// 目标抬高高度
    public let height: FractionInch
}

public enum BendMath {

    /// 90° stub-up:
    /// mark1 = 高度 − takeUp;mark2 = mark1 + takeUp = 高度。
    /// 现场操作:管端到 mark1 画线,mark1 对 bender 箭头,mark2 到鞋尖终点。
    public static func stubUp(height: Double, spec: ConduitSpec) -> StubUpResult {
        let mark1 = max(0, height - spec.takeUpInches)
        return StubUpResult(
            mark1: FractionInch(decimalInches: mark1),
            mark2: FractionInch(decimalInches: height),
            takeUp: FractionInch(decimalInches: spec.takeUpInches),
            height: FractionInch(decimalInches: height)
        )
    }

    /// Offset:
    /// Mark 间距 = 高度 × multiplier(标称角用 Benfield 常数,任意角用 1/sinθ)
    /// shrink = 高度 × shrinkPerInch(管径相关)
    public struct OffsetResult: Equatable {
        public let angle: Double
        public let multiplier: Double
        public let markSpacing: FractionInch
        public let shrink: FractionInch
        public let height: FractionInch
    }

    public static func offset(height: Double, angleDegrees: Double, spec: ConduitSpec) -> OffsetResult {
        let m = BendAngle.multiplier(degrees: angleDegrees)
        let spacing = height * m
        let shrink = height * spec.shrinkPerInch
        return OffsetResult(
            angle: angleDegrees,
            multiplier: m,
            markSpacing: FractionInch(decimalInches: spacing),
            shrink: FractionInch(decimalInches: shrink),
            height: FractionInch(decimalInches: height)
        )
    }

    /// 3-Point Saddle:
    /// 中心标到障碍中心 = 障碍宽度;侧标距中心 = 障碍高度 × 2.5(Benfield 45° 标准做法
    /// 实际用 22.5-45-22.5 三折)。侧标间距惯例 = height × 2.5,中心弯角 45°。
    public struct SaddleResult: Equatable {
        public let obstacleWidth: FractionInch
        public let obstacleHeight: FractionInch
        /// 中心标记:障碍中心对齐处
        public let centerMarkOffset: FractionInch   // 从起弯参考点到障碍中心
        /// 侧标记离中心标的距离
        public let sideMarkSpacing: FractionInch
        /// 侧弯角度(惯例 22.5°)
        public let sideAngle: Double
        public let centerAngle: Double
    }

    public static func saddle(obstacleWidth: Double, obstacleHeight: Double) -> SaddleResult {
        // Benfield 惯例:侧标 = 高度 × 2.5,中心 45°,两侧 22.5°
        let spacing = obstacleHeight * 2.5
        return SaddleResult(
            obstacleWidth: FractionInch(decimalInches: obstacleWidth),
            obstacleHeight: FractionInch(decimalInches: obstacleHeight),
            centerMarkOffset: FractionInch(decimalInches: obstacleWidth / 2.0),
            sideMarkSpacing: FractionInch(decimalInches: spacing),
            sideAngle: 22.5,
            centerAngle: 45
        )
    }

    /// Kick(单侧踢弯):
    /// kick 高度 h、角度 θ → 沿管标记距离 = h / tan(θ)(从墙角点起算)
    public struct KickResult: Equatable {
        public let angle: Double
        public let height: FractionInch
        /// 从踢点(墙角)沿管回退到弯心的距离
        public let markDistance: FractionInch
    }

    public static func kick(height: Double, angleDegrees: Double) -> KickResult {
        let rad = angleDegrees * .pi / 180.0
        let d = height / tan(rad)
        return KickResult(
            angle: angleDegrees,
            height: FractionInch(decimalInches: height),
            markDistance: FractionInch(decimalInches: d)
        )
    }

    /// 四点 saddle(跨宽障碍):中心两折各 = 宽度方向,侧标同 3 点法
    public struct FourPointSaddleResult: Equatable {
        public let markSpacing: FractionInch   // 侧标间距(高度×2.5)
        public let riseSpacing: FractionInch   // 中心两标间距 = 障碍宽度
        public let sideAngle: Double
        public let centerAngle: Double
    }

    public static func fourPointSaddle(obstacleWidth: Double, obstacleHeight: Double) -> FourPointSaddleResult {
        FourPointSaddleResult(
            markSpacing: FractionInch(decimalInches: obstacleHeight * 2.5),
            riseSpacing: FractionInch(decimalInches: obstacleWidth),
            sideAngle: 22.5,
            centerAngle: 45
        )
    }
}
