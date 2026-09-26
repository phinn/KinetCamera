import AppKit
import CoreImage
import Foundation

// 美颜三档 A/B(磨皮/美白/瘦脸),与 app 同源(FilterPipeline.apply 一条代码路径)
// 用法: beauty3_run <in.png> <outdir>

@main
struct Main {
    static func main() { run() }

    static func run() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: beauty3_run <in> <outdir>"); exit(1) }
        let inPath = args[1], outDir = args[2]
        let img = NSImage(contentsOfFile: inPath)!
        var rect = CGRect(x: 0, y: 0, width: Int(img.size.width), height: Int(img.size.height))
        let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        let input = CIImage(cgImage: cg)
        let pipeline = FilterPipeline.shared

        func save(_ name: String, _ s: FilterSettings) {
            let out = pipeline.apply(input, settings: s, time: .zero, quality: .photo)
            if let cg2 = pipeline.renderContext.createCGImage(out, from: out.extent) {
                let rep = NSBitmapImageRep(cgImage: cg2)
                if let data = rep.representation(using: .png, properties: [:]) {
                    try? data.write(to: URL(fileURLWithPath: outDir + "/" + name + ".png"))
                }
            }
            print("saved \(name)")
        }

        var s0 = FilterSettings(sharpen: 0)
        s0.smoothing = 0; s0.whitening = 0; s0.faceSlim = 0
        save("00_before", s0)
        var s1 = s0; s1.smoothing = 0.7
        save("01_smoothing07", s1)
        var s2 = s0; s2.whitening = 0.6
        save("02_whitening06", s2)
        var s3 = s0; s3.faceSlim = 0.8
        save("03_faceslim08", s3)
        var s4 = s0; s4.smoothing = 0.7; s4.whitening = 0.6; s4.faceSlim = 0.8
        save("04_full", s4)
        if let r = pipeline.cachedFaceRect(of: input) {
            print("faceRect: \(r)")
        } else {
            print("faceRect: NONE(无人脸,瘦脸档无效)")
        }
    }
}
