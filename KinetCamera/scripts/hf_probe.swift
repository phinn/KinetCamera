import AppKit
import CoreImage
import Foundation

@main
struct Main {
    static func main() {
        // 512x512 合成:左黑右白阶跃边(中央竖线) + 均匀噪声(毛孔)
        var px = [UInt8](repeating: 0, count: 512*512*4)
        var seed: UInt64 = 12345
        func rnd() -> Double { seed = seed &* 6364136223846793005 &+ 1442695040888963407; return Double((seed >> 33) & 0xFF) }
        for y in 0..<512 {
            for x in 0..<512 {
                let i = (y*512+x)*4
                let base: Double = x < 256 ? 60 : 200
                let noise = (rnd() / 255.0 - 0.5) * 24   // ±12 噪声
                let v = max(0, min(255, base + noise))
                px[i] = UInt8(v); px[i+1] = UInt8(v); px[i+2] = UInt8(v); px[i+3] = 255
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(data: &px, width: 512, height: 512, bitsPerComponent: 8,
                            bytesPerRow: 512*4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let cg = ctx.makeImage()!
        let input = CIImage(cgImage: cg)
        let pipeline = FilterPipeline.shared
        var s0 = FilterSettings(sharpen: 0); s0.smoothing = 0; s0.whitening = 0
        var s1 = FilterSettings(sharpen: 0); s1.smoothing = 0.7; s1.whitening = 0
        func dump(_ name: String, _ s: FilterSettings) {
            let out = pipeline.apply(input, settings: s, time: .zero, quality: .photo)
            let o = pipeline.renderContext.createCGImage(out, from: out.extent)!
            let rep = NSBitmapImageRep(cgImage: o)
            let data = rep.representation(using: .png, properties: [:])!
            try! data.write(to: URL(fileURLWithPath: "/tmp/hfp_\(name).png"))
        }
        dump("before", s0)
        dump("after", s1)
        print("done")
    }
}
