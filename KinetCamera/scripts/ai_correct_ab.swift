import AppKit
import CoreImage

// AI修正同帧 A/B:raw → autoCorrect(6档全开) before/after + 量化(亮度/色偏)
@main
struct Main {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: ai_correct_ab <in.png> <outdir>"); exit(1) }
        let img = NSImage(contentsOfFile: args[1])!
        var rect = CGRect(x: 0, y: 0, width: Int(img.size.width), height: Int(img.size.height))
        let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        let input = CIImage(cgImage: cg)
        let ctx = CIContext()

        func save(_ name: String, _ image: CIImage) {
            guard let c = ctx.createCGImage(image, from: image.extent) else { return }
            let rep = NSBitmapImageRep(cgImage: c)
            try? rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: args[2] + "/" + name))
            print("saved \(name)")
        }
        func stats(_ image: CIImage, tag: String) {
            guard let c = ctx.createCGImage(image, from: image.extent) else { return }
            let w = c.width, h = c.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let cs = CGColorSpaceCreateDeviceRGB()
            guard let bmp = CGContext(data: &px, width: w, height: h, bitsPerComponent: 8,
                  bytesPerRow: w * 4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            bmp.draw(c, in: CGRect(x: 0, y: 0, width: w, height: h))
            var sum = 0.0; var n = 0.0
            var rSum = 0.0; var bSum = 0.0
            for y in stride(from: 0, to: h, by: 4) {
                for x in stride(from: 0, to: w, by: 4) {
                    let i = (y * w * 4) + x * 4
                    sum += Double(px[i]) + Double(px[i+1]) + Double(px[i+2])
                    rSum += Double(px[i]); bSum += Double(px[i+2]); n += 1
                }
            }
            print("[\(tag)] lum=\(String(format: "%.1f", sum / n / 3)) R-B=\(String(format: "%.1f", (rSum - bSum) / n))")
        }

        let analysis = AIAnalyzer.analyze(input, context: ctx)
        print("analysis: blur=\(analysis.blurScore) exposure=\(analysis.exposureScore) cast=\(analysis.colorCast) bias=\(analysis.exposureBias)")
        stats(input, tag: "before")
        let (corrected, applied) = AIAnalyzer.autoCorrect(input, analysis: analysis, userSmoothing: 0, enabled: Set(AICorrectionKind.allCases))
        stats(corrected, tag: "after ")
        print("applied: \(applied)")
        save("ai_before.png", input)
        save("ai_after.png", corrected)
    }
}
