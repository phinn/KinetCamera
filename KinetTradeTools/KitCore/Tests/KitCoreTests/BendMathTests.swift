import XCTest
@testable import KitCore

final class BendMathTests: XCTestCase {

    // MARK: - FractionInch

    func testFractionReduction() {
        XCTAssertEqual(FractionInch(sixteenths: 3).displayInches, "3/16\"")
        XCTAssertEqual(FractionInch(sixteenths: 4).displayInches, "1/4\"")
        XCTAssertEqual(FractionInch(sixteenths: 8).displayInches, "1/2\"")
        XCTAssertEqual(FractionInch(sixteenths: 21).displayInches, "1-5/16\"")
        XCTAssertEqual(FractionInch(sixteenths: 32).displayInches, "2\"")
        XCTAssertEqual(FractionInch(sixteenths: 0).displayInches, "0\"")
    }

    func testDecimalRoundToSixteenth() {
        // 0.604 -> 9.664/16 -> 10/16 = 5/8
        XCTAssertEqual(FractionInch(decimalInches: 0.604).displayInches, "5/8\"")
        // 1.29 -> 20.64/16 -> 21/16 = 1-5/16
        XCTAssertEqual(FractionInch(decimalInches: 1.29).displayInches, "1-5/16\"")
    }

    func testMM() {
        // 1" = 25.4mm
        XCTAssertEqual(FractionInch(sixteenths: 16).millimeters, 25.4, accuracy: 0.001)
    }

    // MARK: - Multiplier

    func testBenfieldMultipliers() {
        XCTAssertEqual(BendAngle.a10.multiplier, 6.0, accuracy: 0.001)
        XCTAssertEqual(BendAngle.a22_5.multiplier, 2.6, accuracy: 0.001)
        XCTAssertEqual(BendAngle.a30.multiplier, 2.0, accuracy: 0.001)
        XCTAssertEqual(BendAngle.a45.multiplier, 1.414, accuracy: 0.001)
        XCTAssertEqual(BendAngle.a60.multiplier, 1.155, accuracy: 0.001)
    }

    func testArbitraryAngleMultiplier() {
        // 1/sin(45°) = √2
        XCTAssertEqual(BendAngle.multiplier(degrees: 45), 1.41421, accuracy: 0.0001)
        // 1/sin(30°) = 2
        XCTAssertEqual(BendAngle.multiplier(degrees: 30), 2.0, accuracy: 0.0001)
        // 0° 防护
        XCTAssertEqual(BendAngle.multiplier(degrees: 0), .infinity)
    }

    // MARK: - Stub-Up(黄金手算样例)

    /// 手算:1/2" EMT,take-up 5",抬高 10"
    /// mark1 = 10 − 5 = 5";mark2 = 10"
    func testStubUpHalfInchEMT() {
        let db = ConduitCatalog.load()
        let emt12 = db.conduits.first { $0.id == "emt-1/2" }!
        let r = BendMath.stubUp(height: 10, spec: emt12)
        XCTAssertEqual(r.mark1.sixteenths, 80)   // 5" = 80/16
        XCTAssertEqual(r.mark2.sixteenths, 160)  // 10"
        XCTAssertEqual(r.mark1.displayInches, "5\"")
    }

    /// 手算:3/4" EMT,take-up 6",抬高 15-1/2"
    /// mark1 = 15.5 − 6 = 9.5"
    func testStubUpThreeQuarter() {
        let db = ConduitCatalog.load()
        let emt34 = db.conduits.first { $0.id == "emt-3/4" }!
        let r = BendMath.stubUp(height: 15.5, spec: emt34)
        XCTAssertEqual(r.mark1.displayInches, "9-1/2\"")
    }

    // MARK: - Offset(黄金手算样例)

    /// 手算:1/2" EMT,30° offset,高度 6"
    /// 间距 = 6 × 2 = 12";shrink = 6 × 1/4(30° Benfield)= 1-1/2"(与管径无关)
    func testOffset30() {
        let db = ConduitCatalog.load()
        let emt12 = db.conduits.first { $0.id == "emt-1/2" }!
        let r = BendMath.offset(height: 6, angleDegrees: 30, spec: emt12)
        XCTAssertEqual(r.multiplier, 2.0, accuracy: 0.0001)
        XCTAssertEqual(r.markSpacing.displayInches, "12\"")
        XCTAssertEqual(r.shrink.decimalInches, 1.5, accuracy: 0.001)
        XCTAssertEqual(r.shrink.displayInches, "1-1/2\"")
    }

    /// 手算:1/2" EMT,45° offset,高度 8"
    /// 间距 = 8 × 1.414 = 11.31" → 11-5/16";shrink = 8 × 3/8(45° Benfield)= 3"
    func testOffset45() {
        let db = ConduitCatalog.load()
        let emt12 = db.conduits.first { $0.id == "emt-1/2" }!
        let r = BendMath.offset(height: 8, angleDegrees: 45, spec: emt12)
        XCTAssertEqual(r.markSpacing.decimalInches, 11.3137, accuracy: 0.01)
        XCTAssertEqual(r.markSpacing.displayInches, "11-5/16\"")
        XCTAssertEqual(r.shrink.displayInches, "3\"")
    }

    /// Benfield shrink 表:标称角表值 + 任意角回落 tan(θ/2)
    func testShrinkPerInch() {
        XCTAssertEqual(BendAngle.shrinkPerInch(angleDegrees: 10), 0.0625, accuracy: 0.0001)
        XCTAssertEqual(BendAngle.shrinkPerInch(angleDegrees: 22.5), 0.1875, accuracy: 0.0001)
        XCTAssertEqual(BendAngle.shrinkPerInch(angleDegrees: 30), 0.25, accuracy: 0.0001)
        XCTAssertEqual(BendAngle.shrinkPerInch(angleDegrees: 45), 0.375, accuracy: 0.0001)
        XCTAssertEqual(BendAngle.shrinkPerInch(angleDegrees: 60), 0.5, accuracy: 0.0001)
        // 任意角:tanhalf = tan(θ/2);25° → tan(12.5°) = 0.2217
        XCTAssertEqual(BendAngle.shrinkPerInch(angleDegrees: 25), tan(25 * .pi / 360), accuracy: 0.0001)
        // 20° 与 22.5° 应不同(证明是连续函数,不是查表直通)
        XCTAssertNotEqual(BendAngle.shrinkPerInch(angleDegrees: 20), BendAngle.shrinkPerInch(angleDegrees: 22.5))
    }

    /// 任意角 25°:1/sin25 = 2.366;4 × 2.366 = 9.4648 → 舍到 1/16 = 9-7/16"
    func testOffsetArbitraryAngle() {
        let db = ConduitCatalog.load()
        let emt12 = db.conduits.first { $0.id == "emt-1/2" }!
        let r = BendMath.offset(height: 4, angleDegrees: 25, spec: emt12)
        XCTAssertEqual(r.multiplier, 2.3662, accuracy: 0.001)
        // FractionInch 是 1/16 显示精度,容差 ±1/16
        XCTAssertEqual(r.markSpacing.decimalInches, 9.4648, accuracy: 1.0/16.0)
        XCTAssertEqual(r.markSpacing.displayInches, "9-7/16\"")
    }

    // MARK: - Saddle

    /// 手算:3 点 saddle,障碍高 2",宽 4"
    /// 侧标 = 2 × 2.5 = 5";中心偏移 = 宽/2 = 2"
    func testThreePointSaddle() {
        let r = BendMath.saddle(obstacleWidth: 4, obstacleHeight: 2)
        XCTAssertEqual(r.sideMarkSpacing.displayInches, "5\"")
        XCTAssertEqual(r.centerMarkOffset.displayInches, "2\"")
        XCTAssertEqual(r.sideAngle, 22.5)
        XCTAssertEqual(r.centerAngle, 45)
    }

    /// 4 点:中心两标间距 = 障碍宽
    func testFourPointSaddle() {
        let r = BendMath.fourPointSaddle(obstacleWidth: 6, obstacleHeight: 3)
        XCTAssertEqual(r.riseSpacing.displayInches, "6\"")
        XCTAssertEqual(r.markSpacing.displayInches, "7-1/2\"")
    }

    // MARK: - Kick

    /// 手算:kick 高 4",45° → d = 4 / tan45 = 4"
    func testKick45() {
        let r = BendMath.kick(height: 4, angleDegrees: 45)
        XCTAssertEqual(r.markDistance.displayInches, "4\"")
    }

    /// 手算:kick 高 3",30° → d = 3 / tan30 = 5.196" → 5-3/16"
    func testKick30() {
        let r = BendMath.kick(height: 3, angleDegrees: 30)
        XCTAssertEqual(r.markDistance.decimalInches, 5.196, accuracy: 0.01)
        XCTAssertEqual(r.markDistance.displayInches, "5-3/16\"")
    }

    // MARK: - Catalog

    func testCatalogLoads() {
        let db = ConduitCatalog.load()
        XCTAssertGreaterThanOrEqual(db.conduits.count, 30)
        // id 唯一
        let ids = db.conduits.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count)
        // 全部字段为正
        for c in db.conduits {
            XCTAssertGreaterThan(c.takeUpInches, 0)
            XCTAssertGreaterThan(c.minRadiusInches, 0)
        }
        // EMT 10 档
        XCTAssertEqual(ConduitCatalog.specs(type: "EMT", database: db).count, 10)
    }
}
