import CoreImage
import CoreVideo
import QuartzCore
import Foundation

struct Bench {
    static func run() {
        let w = 1280, h = 720
        var attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w, kCVPixelBufferHeightKey as String: h]
        var pool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attrs as CFDictionary, &pool)
        var pb: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool!, &pb)
        CVPixelBufferLockBaseAddress(pb!, [])
        let base = CVPixelBufferGetBaseAddress(pb!)!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<h {
            let row = base + y * CVPixelBufferGetBytesPerRow(pb!)
            for x in 0..<w { row[x*4] = UInt8(x % 255); row[x*4+1] = UInt8(y % 255); row[x*4+2] = 128; row[x*4+3] = 255 }
        }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        let img = CIImage(cvPixelBuffer: pb!)
        print("input extent=\(img.extent) pbFmt=\(CVPixelBufferGetPixelFormatType(pb!)) size=\(CVPixelBufferGetWidth(pb!))x\(CVPixelBufferGetHeight(pb!))")
        var s = FilterSettings()
        s.smoothing = 0.7; s.whitening = 0.6; s.brightening = 0.15; s.sharpen = 0.25
        let ctx = CIContext(options: [.cacheIntermediates: false])
        var out: CIImage = img
        // warmup + 强制求值
        let warm = FilterPipeline.shared.apply(img, settings: s, time: .zero, quality: .video)
        let warmCG = ctx.createCGImage(warm, from: warm.extent)
        print("warmup cg=\(warmCG != nil) extent=\(warm.extent)")
        let t0 = CACurrentMediaTime()
        for _ in 0..<20 {
            out = FilterPipeline.shared.apply(img, settings: s, time: .zero, quality: .video)
            _ = ctx.createCGImage(out, from: out.extent)   // 强制整链求值(与 app 实况同构)
        }
        let tApply = (CACurrentMediaTime() - t0) / 20 * 1000
        let tRender = 0.0
        print(String(format: "apply(.video) %.1fms/帧 | renderCG %.1fms → 合计 %.1fms ≈ %.0ffps", tApply, tRender, tApply + tRender, 1000 / (tApply + tRender)))
    }
}

@main
struct BenchEntry { static func main() { Bench.run() } }
