// AI 修正链 A/B harness —— 与 app 同源编译(swiftc + AIAnalyzer.swift)
// 用法: ai_correct_verify <输入图> <输出图> [warm|dark|dark2|tilt6|fisheye|none]
// 单帧跑完整 autoCorrect 链,输出 before/after 全指标 JSON,并落修正后 PNG。
import AppKit
import CoreImage

@main
struct WBVerify {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else {
            FileHandle.standardError.write("usage: ai_correct_verify <in> <out> [warm|dark|dark2|tilt6|fisheye|none]\n".data(using: .utf8)!)
            exit(1)
        }
        let inPath = args[1], outPath = args[2]
        let force = args.count > 3 ? args[3] : "none"

        guard let srcCI = CIImage(contentsOf: URL(fileURLWithPath: inPath)) else {
            FileHandle.standardError.write("cannot load \(inPath)\n".data(using: .utf8)!)
            exit(1)
        }
        let ctx = CIContext()
        var input = srcCI
        if force == "warm" {
            input = input.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1.15, y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.8, w: 0)])
        } else if force == "dark" {
            input = input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -1.3])
        } else if force == "dark2" {
            input = input.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -2.2])  // 严重暗光→暗光档
        } else if force == "tilt6" {
            input = input.transformed(by: CGAffineTransform(rotationAngle: CGFloat(-6.0 * .pi / 180)))  // 模拟顺时针拍歪(Vision 将读+6)
        }
        let inCG0 = ctx.createCGImage(input, from: input.extent)!

        func stats(_ cg: CGImage) -> (r: Double, g: Double, b: Double, lum: Double, cast: Double, exp: Double) {
            let maxDim = 256
            let scale = min(1.0, Double(maxDim) / Double(max(cg.width, cg.height)))
            let w = max(Int(Double(cg.width) * scale), 8), h = max(Int(Double(cg.height) * scale), 8)
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            let cctx = CGContext(data: &rgba, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            cctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            var rs = 0.0, gs = 0.0, bs = 0.0
            let n = Double(w * h)
            for i in 0..<Int(n) {
                rs += Double(rgba[i*4]); gs += Double(rgba[i*4+1]); bs += Double(rgba[i*4+2])
            }
            let r = rs/n, g = gs/n, b = bs/n
            let lum = 0.299*r + 0.587*g + 0.114*b
            return (r, g, b, lum, r - b, lum/255.0*2 - 1)
        }
        func cgOf(_ ci: CIImage) -> CGImage { ctx.createCGImage(ci, from: ci.extent)! }

        // fisheye 用已知系数预畸变(验证校正数学的收敛性:预加 k1=+0.16 桶形,看校正后还原度)
        if force == "fisheye" {
            input = AIAnalyzer.radialDistortionCorrect(input, k1: 0.16) ?? input  // 正 k1=桶形外鼓
        }
        let inCG = cgOf(input)
        let before = stats(inCG)

        // ---- 完整 autoCorrect 链(app 同源;tilt/fisheye 档直接注入 hint 验证触发) ----
        var analysis = AIAnalyzer.analyze(input, context: ctx)
        if force == "tilt6" { analysis.tiltAngle = 6.0 }        // 注入:预倾斜的图中 Vision horizon 可能测不出精确值
        if force == "fisheye" { analysis.fisheyeHint = 0.9 }    // 注入:已知畸变场景
        let corrected = AIAnalyzer.autoCorrect(input, analysis: analysis, userSmoothing: 0)
        // DEBUG: extent 与独立 straighten 对照
        if force == "tilt6" {
            let stOnly = input.applyingFilter("CIStraightenFilter", parameters: ["inputAngle": CGFloat(6.0 * .pi / 180)])
            if let ocg = ctx.createCGImage(stOnly, from: stOnly.extent) {
                let url = URL(fileURLWithPath: "/tmp/st_only.png") as CFURL
                if let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) {
                    CGImageDestinationAddImage(dest, ocg, nil); CGImageDestinationFinalize(dest)
                }
            }
            FileHandle.standardError.write("DEBUG input.extent=\(input.extent) corrected.extent=\(corrected.image.extent)\n".data(using: .utf8)!)
        }
        let outCG = cgOf(corrected.image)
        let after = stats(outCG)

        let blurB = AIAnalyzer.sharpnessScore(cgImage: inCG)
        let blurA = AIAnalyzer.sharpnessScore(cgImage: outCG)

        let applied = corrected.appliedNames.joined(separator: ",")
        func f(_ v: Double) -> String { String(format: "%.1f", v) }
        let tiltDetected = String(format: "%.2f", analysis.tiltAngle)
        print("""
        {"input":"\(inPath)","force":"\(force)","tiltDetected":\(tiltDetected),"fisheyeHint":\(f(analysis.fisheyeHint)),
         "before":{"cast":\(f(before.cast)),"exp":\(f(before.exp)),"lum":\(f(before.lum)),"blur":\(f(blurB))},
         "after":{"cast":\(f(after.cast)),"exp":\(f(after.exp)),"lum":\(f(after.lum)),"blur":\(f(blurA))},
         "applied":"\(applied)"}
        """)

        let rep = NSBitmapImageRep(cgImage: outCG)
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: outPath))
    }
}
