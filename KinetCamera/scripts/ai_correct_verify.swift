// AI 修正链 A/B harness —— 与 app 同源编译(swiftc + AIAnalyzer.swift)
// 用法: ai_correct_verify <输入图> <输出图> [warm|dark|cool|none]
// 单帧跑完整 autoCorrect 链,输出 before/after 全指标 JSON,并落修正后 PNG。
import AppKit
import CoreImage

@main
struct WBVerify {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write("usage: ai_correct_verify <in> <out> [warm|dark|cool|none]\n".data(using: .utf8)!)
            exit(1)
        }
        let inPath = args[1], outPath = args[2]
        let force = args.count > 3 ? args[3] : "none"

        guard let srcNS = NSImage(contentsOfFile: inPath),
              let tiff = srcNS.tiffRepresentation,
              let srcCI = CIImage(data: tiff) else {
            FileHandle.standardError.write("cannot load \(inPath)\n".data(using: .utf8)!)
            exit(1)
        }
        let ctx = CIContext()

        func cgOf(_ ci: CIImage) -> CGImage {
            ctx.createCGImage(ci, from: ci.extent)!
        }

        func stats(_ cg: CGImage) -> (r: Double, g: Double, b: Double, lum: Double, cast: Double, exp: Double) {
            let maxDim = 256
            let scale = min(1.0, Double(maxDim) / Double(max(cg.width, cg.height)))
            let w = max(Int(Double(cg.width) * scale), 8), h = max(Int(Double(cg.height) * scale), 8)
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            let c = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.interpolationQuality = .medium
            c.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            var sr = 0.0, sg = 0.0, sb = 0.0
            for i in stride(from: 0, to: rgba.count, by: 4) {
                sr += Double(rgba[i]); sg += Double(rgba[i+1]); sb += Double(rgba[i+2])
            }
            let n = Double(rgba.count / 4)
            let r = sr / n, g = sg / n, b = sb / n
            let lum = 0.299 * r + 0.587 * g + 0.114 * b
            let expScore = 100.0 - abs(lum - 128.0) * 100.0 / 128.0
            return (r, g, b, lum, r - b, expScore)
        }

        // ---- 生成强制劣化输入 ----
        var input = srcCI
        if force == "warm" {   // 钨丝灯模拟:R 抬 25%,B 压 25%
            input = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.25, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.75, w: 0)])
        } else if force == "cool" {
            input = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.75, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1.25, w: 0)])
        } else if force == "dark" {
            input = input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.3])
        }
        let inCG = cgOf(input)
        let before = stats(inCG)

        // ---- 完整 autoCorrect 链(app 同源) ----
        let analysis = AIAnalyzer.analyze(input, context: ctx)
        let corrected = AIAnalyzer.autoCorrect(input, analysis: analysis, userSmoothing: 0)
        let outCG = cgOf(corrected.image)
        let after = stats(outCG)

        let blurB = AIAnalyzer.sharpnessScore(cgImage: inCG)
        let blurA = AIAnalyzer.sharpnessScore(cgImage: outCG)

        let applied = corrected.appliedNames.joined(separator: ",")
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        print("""
        {"input":"\(inPath)","force":"\(force)",
         "before":{"cast":\(f(before.cast)),"exp":\(f(before.exp)),"lum":\(f(before.lum)),"blur":\(f(blurB))},
         "after":{"cast":\(f(after.cast)),"exp":\(f(after.exp)),"lum":\(f(after.lum)),"blur":\(f(blurA))},
         "applied":"\(applied)"}
        """)

        let rep = NSBitmapImageRep(cgImage: outCG)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
    }
}
