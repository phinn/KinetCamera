import Foundation

/// 分数英寸:1/16" 精度的工地通用表示。
/// 支持 1/16 → 1/2 → 1(分母规约),显示为 "1-5/16"" 风格。
public struct FractionInch: Equatable, Hashable {
    /// 总分子(以 1/16 为单位),恒 >= 0
    public let sixteenths: Int

    public init(sixteenths: Int) {
        self.sixteenths = max(0, sixteenths)
    }

    /// 从十进制英寸构造,四舍五入到 1/16
    public init(decimalInches: Double) {
        self.sixteenths = Int((decimalInches * 16.0).rounded())
    }

    /// 从整英寸 + 分子/分母构造(如 1, 5, 16 = 1-5/16")
    public init(whole: Int = 0, numerator: Int = 0, denominator: Int = 16) {
        precondition(denominator > 0)
        let value = Double(whole) + Double(numerator) / Double(denominator)
        self.sixteenths = Int((value * 16.0).rounded())
    }

    public var decimalInches: Double {
        Double(sixteenths) / 16.0
    }

    public var millimeters: Double {
        decimalInches * 25.4
    }

    /// 分母规约到 2/4/8/16 中最小可整除的
    private var reducedFraction: (n: Int, d: Int) {
        let n = sixteenths % 16
        var num = n
        var den = 16
        while num % 2 == 0, den > 2 {
            num /= 2
            den /= 2
        }
        return (num, den)
    }

    /// 显示:"3/16""、"1-5/16""、"2""
    public var displayInches: String {
        let whole = sixteenths / 16
        let (n, d) = reducedFraction
        switch (whole, n) {
        case (0, 0): return "0\""
        case (0, _): return "\(n)/\(d)\""
        case (_, 0): return "\(whole)\""
        default: return "\(whole)-\(n)/\(d)\""
        }
    }

    /// 显示毫米:"33.3 mm"
    public var displayMM: String {
        String(format: "%.1f mm", millimeters)
    }

    /// 显示(按单位制)
    public func display(unit: LengthUnit) -> String {
        switch unit {
        case .inchFraction: return displayInches
        case .inchDecimal: return String(format: "%.3f\"", decimalInches)
        case .millimeter: return displayMM
        }
    }
}

public enum LengthUnit: String, CaseIterable, Identifiable {
    case inchFraction
    case inchDecimal
    case millimeter

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .inchFraction: return "1/16\""
        case .inchDecimal: return "in"
        case .millimeter: return "mm"
        }
    }
}
