import CoreImage
import Foundation

// AI 去暖修正 A/B harness:直调 AIAnalyzer(CLI 纯 CPU 渲染,无相机权限需求)
@main
struct WBHarness {
    static func main() {
        let ctx = CIContext()
        let W = 1280, H = 720

        // 合成"钨丝灯暖偏"图:中性灰 + 暖色增益(R×1.42, B×0.62) + 纹理(供锐度分析)
        var px = [UInt8](repeating: 0, count: W * H * 4)
        for y in 0..<H {
            for x in 0..<W {
                let i = (y * W + x) * 4
                let base = Double((x * 7919 + y * 104729) % 256)
                let lum = 90 + base * 0.25
                px[i]   = UInt8(min(255, lum * 1.18))
                px[i+1] = UInt8(min(255, lum))
                px[i+2] = UInt8(min(255, lum * 0.82))
                px[i+3] = 255
            }
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let bmp = CGContext(data: &px, width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let warmCG = bmp.makeImage()!
        let warm = CIImage(cgImage: warmCG)

        let beforeCast = AIAnalyzer.colorCast(warmCG)
        let beforeBlur = AIAnalyzer.sharpnessScore(cgImage: warmCG)
        let beforeExp = AIAnalyzer.exposureScore(cgImage: warmCG)
        let analysis = AIAnalysis(blurScore: beforeBlur, exposureScore: beforeExp, faceCount: 0,
                                  compositionHint: nil, suggestion: nil, colorCast: beforeCast)

        let (fixed, applied) = AIAnalyzer.autoCorrect(warm, analysis: analysis, userSmoothing: 0)
        let afterCG = ctx.createCGImage(fixed, from: fixed.extent)!
        let afterCast = AIAnalyzer.colorCast(afterCG)
        let afterBlur = AIAnalyzer.sharpnessScore(cgImage: afterCG)
        let afterExp = AIAnalyzer.exposureScore(cgImage: afterCG)

        print("══ AI 去暖 A/B(合成钨丝灯场景 1280x720)══")
        print(String(format: "colorCast: %+.1f → %+.1f (目标 |cast|<8)", beforeCast, afterCast))
        print(String(format: "blur: %.1f → %.1f", beforeBlur, afterBlur))
        print(String(format: "exposure: %.1f → %.1f", beforeExp, afterExp))
        print("applied: \(applied.joined(separator: " | "))")

        let dir = URL(fileURLWithPath: "/tmp")
        try? ctx.writePNGRepresentation(of: CIImage(cgImage: warmCG), to: dir.appendingPathComponent("wb_before.png"), format: .RGBA8, colorSpace: cs)
        try? ctx.writePNGRepresentation(of: CIImage(cgImage: afterCG), to: dir.appendingPathComponent("wb_after.png"), format: .RGBA8, colorSpace: cs)
        print("evidence: /tmp/wb_before.png /tmp/wb_after.png")
    }
}
