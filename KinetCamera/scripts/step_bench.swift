
import CoreImage
import CoreVideo
import QuartzCore
import Foundation

struct Bench2 {
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
        for y in 0..<h { let row = base + y*CVPixelBufferGetBytesPerRow(pb!)
            for x in 0..<w { row[x*4]=UInt8(x%255); row[x*4+1]=UInt8(y%255); row[x*4+2]=128; row[x*4+3]=255 } }
        CVPixelBufferUnlockBaseAddress(pb!, [])
        var image = CIImage(cvPixelBuffer: pb!)
        let ctx = CIContext(options: [:])
        func probe(_ label: String, _ img: CIImage) {
            let cg = ctx.createCGImage(img, from: img.extent)
            let px = cg.flatMap { c -> UInt8? in
                let w = c.width, h = c.height
                guard let d = c.dataProvider?.data, let b = CFDataGetBytePtr(d) else { return nil }
                return b[(h/2*w + w/2)*4 + 2]
            }
            print("\(label): extent=\(img.extent) cg=\(cg != nil) centerB=\(String(describing: px))")
        }
        // step1: YCbCr 转换
        let ycc = image.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
            "inputGVector": CIVector(x: -0.168736, y: -0.331264, z: 0.5, w: 0.5),
            "inputBVector": CIVector(x: 0.5, y: -0.418688, z: -0.081312, w: 0.5)])
        probe("ycc", ycc)
        // step2: skin mask
        let skin = ycc.applyingFilter("CIColorClamp", parameters: [
            "inputMinComponents": CIVector(x: 0, y: 0.49, z: 0.33, w: 0),
            "inputMaxComponents": CIVector(x: 0, y: 0.75, z: 0.48, w: 1),
        ]).applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 12.5, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 12.5, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 12.5, w: 0),
            "inputBiasVector": CIVector(x: 0, y: -9.25, z: -7.06, w: 0)])
        let skinMask = skin.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0]).cropped(to: image.extent)
        probe("skinMask", skinMask)
        // step3: blur+blend
        let blurred = image.clampedToExtent().applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6.2]).cropped(to: image.extent)
        probe("blurred", blurred)
        let blended = blurred.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputImageKey: blurred, kCIInputBackgroundImageKey: image, kCIInputMaskImageKey: skinMask])
        probe("blend", blended)
        // 美白段
        let lift = 0.6
        let bright = blended.applyingFilter("CIColorControls", parameters: [
            kCIInputBrightnessKey: 0.05 * lift, kCIInputContrastKey: 1.0 + 0.02 * lift])
            .applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 1.05, w: 0),
                "inputBiasVector": CIVector(x: 0, y: 0, z: 6 * lift, w: 0)])
        probe("bright", bright)
        // 修法A: CISourceOverCompositing + alpha 0.85
        let brightA = bright.applyingFilter("CIColorMatrix", parameters: [
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 0.85)])
        let over = blended.applyingFilter("CISourceOverCompositing", parameters: [kCIInputImageKey: brightA])
        probe("fixA_sourceOver", over)
        // 修法B: CIBlendWithMask + 常数 mask 0.85
        let constMask = CIImage(color: CIColor(red: 0.85, green: 0.85, blue: 0.85)).cropped(to: blended.extent)
        let fixB = blended.applyingFilter("CIBlendWithMask", parameters: [
            kCIInputImageKey: bright, kCIInputBackgroundImageKey: blended, kCIInputMaskImageKey: constMask])
        probe("fixB_constMask", fixB)
    }
}

@main
struct Entry2 { static func main() { Bench2.run() } }
