import XCTest
import CoreImage
import CoreMedia
@testable import KinetCamera

// MARK: - P0① MFNR 多帧降噪
final class MFNRTests: XCTestCase {
    private lazy var ctx = CIContext(options: [.workingColorSpace: NSNull()])

    private func solidColor(_ r: UInt8, _ g: UInt8, _ b: UInt8, w: Int = 64, h: Int = 64) -> CIImage {
        CIImage(color: CIColor(red: Double(r)/255, green: Double(g)/255, blue: Double(b)/255))
            .cropped(to: CGRect(x: 0, y: 0, width: w, height: h))
    }

    private func mean(_ image: CIImage) -> Double {
        var pix = [UInt8](repeating: 0, count: 64*64*4)
        ctx.render(image, toBitmap: &pix, rowBytes: 64*4,
                   bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBA8, colorSpace: nil)
        var sum = 0.0
        for i in 0..<(64*64) { sum += Double(pix[i*4]) + Double(pix[i*4+1]) + Double(pix[i*4+2]) }
        return sum / Double(64*64*3)
    }

    func testCanMergeAcceptsNormalFrameTimes() {
        let t = { CMTime(seconds: $0, preferredTimescale: 600) }
        XCTAssertTrue(MFNR.canMerge(times: [t(1.000), t(1.033), t(1.066)]))
    }
    func testCanMergeRejectsTooFew() {
        let t = { CMTime(seconds: $0, preferredTimescale: 600) }
        XCTAssertFalse(MFNR.canMerge(times: [t(1.0), t(1.033)]))
    }
    func testCanMergeRejectsPTSGap() {
        // 时基断裂(423861s 事故域):间隔>0.10s 一票否决
        let t = { CMTime(seconds: $0, preferredTimescale: 600) }
        XCTAssertFalse(MFNR.canMerge(times: [t(1.0), t(1.033), t(423861.0)]))
    }
    func testCanMergeRejectsNaNAndNegative() {
        let t = { CMTime(seconds: $0, preferredTimescale: 600) }
        XCTAssertFalse(MFNR.canMerge(times: [t(1.0), CMTime(seconds: .nan, preferredTimescale: 600), t(1.066)]))
        XCTAssertFalse(MFNR.canMerge(times: [t(-1.0), t(1.033), t(1.066)]))
    }
    func testCanMergeRejectsNonMonotonic() {
        let t = { CMTime(seconds: $0, preferredTimescale: 600) }
        XCTAssertFalse(MFNR.canMerge(times: [t(1.066), t(1.033), t(1.000)]))
    }
    func testCompositeRejectsTooFew() {
        XCTAssertNil(MFNR.composite([solidColor(10,10,10)], context: ctx))
    }
    func testCompositeRejectsExtentMismatch() {
        let a = solidColor(10,10,10)
        let b = solidColor(10,10,10, w: 32)
        XCTAssertNil(MFNR.composite([a, b, a], context: ctx))
    }
    func testCompositeStaticSceneAveragesNoise() {
        // 静区语义:三帧相同输入,输出≈输入均值(无运动时全走平均路径)
        let a = solidColor(100,100,100)
        let b = solidColor(110,110,110)
        let c = solidColor(120,120,120)
        let out = MFNR.composite([a,b,c], context: ctx)!
        let m = mean(out)
        XCTAssertEqual(m, 110.0, accuracy: 2.0, "三帧均值应≈(100+110+120)/3=110")
    }
    func testCompositeMotionRegionTakesMiddleFrame() {
        // 动区语义:中央放一个 32x32 亮块且三帧位置/值大变 → 动区取中间帧,不被平均糊掉
        func frame(_ blockVal: UInt8) -> CIImage {
            let bg = solidColor(20,20,20)
            let block = solidColor(blockVal, blockVal, blockVal, w: 32, h: 32)
                .transformed(by: CGAffineTransform(translationX: 16, y: 16))
            return block.composited(over: bg)
        }
        let a = frame(240), b = frame(60), c = frame(240)   // 中间帧明显不同=动区
        let out = MFNR.composite([a,b,c], context: ctx)!
        var pix = [UInt8](repeating: 0, count: 64*64*4)
        ctx.render(out, toBitmap: &pix, rowBytes: 64*4,
                   bounds: CGRect(x: 0, y: 0, width: 64, height: 64), format: .RGBA8, colorSpace: nil)
        // 中心像素在动区掩膜内 → 应≈中间帧的 60,而不是平均后的 ~140
        let i = (32*64 + 32) * 4
        let center = (Double(pix[i]) + Double(pix[i+1]) + Double(pix[i+2])) / 3
        XCTAssertEqual(center, 60.0, accuracy: 25.0, "动区中心应取中间帧亮度")
        // 角落是静区(全帧同值)→ 平均结果同值
        let j = (8*64 + 8) * 4
        let corner = (Double(pix[j]) + Double(pix[j+1]) + Double(pix[j+2])) / 3
        XCTAssertEqual(corner, 20.0, accuracy: 6.0, "静区应保持背景均值")
    }
}

// MARK: - P0② 脸区 blurScore 加权
final class FaceSharpnessTests: XCTestCase {
    private lazy var ctx = CIContext(options: [.workingColorSpace: NSNull()])
    func testNoFaceFallsBackToGlobal() {
        let img = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        guard let cg = ctx.createCGImage(img, from: img.extent) else { return XCTFail() }
        XCTAssertEqual(AIAnalyzer.sharpnessScore(cgImage: cg, faceRect: nil),
                       AIAnalyzer.sharpnessScore(cgImage: cg), accuracy: 0.001)
    }
    func testDegenerateRectFallsBackToGlobal() {
        let img = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
        guard let cg = ctx.createCGImage(img, from: img.extent) else { return XCTFail() }
        XCTAssertEqual(AIAnalyzer.sharpnessScore(cgImage: cg, faceRect: CGRect(x: 0, y: 0, width: 0, height: 0)),
                       AIAnalyzer.sharpnessScore(cgImage: cg), accuracy: 0.001)
    }
    func testSharpFaceRegionScoresHigherThanBlurry() throws {
        // 同一底图,脸区内放高频棋盘(锐) vs 纯色(糊),ROI 分数必须显著区分
        func checkerboard(sharp: Bool) -> CGImage {
            let img = CIImage(color: CIColor(red: 0.5, green: 0.5, blue: 0.5)).cropped(to: CGRect(x: 0, y: 0, width: 128, height: 128))
            var out = img
            if sharp {
                for y in stride(from: 40, to: 88, by: 4) {
                    for x in stride(from: 40, to: 88, by: 4) {
                        let cell = CIImage(color: (Int(x + y) / 4 % 2 == 0 ? CIColor(red: 0.95, green: 0.95, blue: 0.95) : CIColor(red: 0.05, green: 0.05, blue: 0.05)))
                            .cropped(to: CGRect(x: x, y: y, width: 4, height: 4))
                        out = cell.composited(over: out)
                    }
                }
            }
            return ctx.createCGImage(out, from: out.extent)!
        }
        let sharpScore = AIAnalyzer.sharpnessScore(cgImage: checkerboard(sharp: true),
                                                   faceRect: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        let blurScore = AIAnalyzer.sharpnessScore(cgImage: checkerboard(sharp: false),
                                                  faceRect: CGRect(x: 0.3, y: 0.3, width: 0.4, height: 0.4))
        XCTAssertGreaterThan(sharpScore, blurScore + 15, "脸区高频能量必须显著高于纯色")
    }
}

// MARK: - P0③ 再对焦抑制策略
final class FocusPolicyTests: XCTestCase {
    let now: TimeInterval = 1000
    func testFirstFaceTriggersRefocus() {
        XCTAssertTrue(FocusPolicy.shouldRefocus(previousFace: nil, currentFace: CGRect(x:0.3,y:0.3,width:0.3,height:0.3), now: now, lastRefocus: 0))
    }
    func testLostFaceDoesNotRefocus() {
        XCTAssertFalse(FocusPolicy.shouldRefocus(previousFace: CGRect(x:0.3,y:0.3,width:0.3,height:0.3), currentFace: nil, now: now, lastRefocus: 0))
    }
    func testCooldownBlocksRefocus() {
        // 冷却期内(0.5s < 1.2s)即使大变化也不拉
        XCTAssertFalse(FocusPolicy.shouldRefocus(
            previousFace: CGRect(x:0.3,y:0.3,width:0.3,height:0.3),
            currentFace: CGRect(x:0.3,y:0.3,width:0.6,height:0.6),
            now: now, lastRefocus: now - 0.5))
    }
    func testSmallJitterDoesNotRefocus() {
        // 呼吸抖动:面积±5%、中心位移~0.01 —— 不拉
        XCTAssertFalse(FocusPolicy.shouldRefocus(
            previousFace: CGRect(x:0.30,y:0.30,width:0.30,height:0.30),
            currentFace: CGRect(x:0.31,y:0.29,width:0.315,height:0.315),
            now: now, lastRefocus: now - 5))
    }
    func testAreaChangeOver15Triggers() {
        // 面积 0.09 → 0.126 = +40%,超阈值
        XCTAssertTrue(FocusPolicy.shouldRefocus(
            previousFace: CGRect(x:0.3,y:0.3,width:0.3,height:0.3),
            currentFace: CGRect(x:0.3,y:0.3,width:0.354,height:0.354),
            now: now, lastRefocus: now - 5))
    }
    func testAreaChangeExactly15DoesNotTrigger() {
        // 0.15 恰好=阈值(> 严格大于才触发):呼吸抖动域
        XCTAssertFalse(FocusPolicy.shouldRefocus(
            previousFace: CGRect(x:0.3,y:0.3,width:0.3,height:0.3),
            currentFace: CGRect(x:0.3,y:0.3,width:0.3216,height:0.3216),
            now: now, lastRefocus: now - 5))
    }
    func testCenterMoveOver6Triggers() {
        // 位移 0.10 > 0.06
        XCTAssertTrue(FocusPolicy.shouldRefocus(
            previousFace: CGRect(x:0.3,y:0.3,width:0.3,height:0.3),
            currentFace: CGRect(x:0.40,y:0.3,width:0.3,height:0.3),
            now: now, lastRefocus: now - 5))
    }
}
