import CoreImage
import CoreGraphics
import AppKit
import Foundation

// 美颜管线 harness:文件进 FilterPipeline.apply(与 app 预览/成片同一条代码路径)
// 用法: beauty_pipeline <in.png> <out.png> [smoothing] [whitening] [brightening] [sharpen]

@main
struct BeautyPipeline {
    static func main() {
        let args = CommandLine.arguments
        guard args.count >= 3 else { print("usage: beauty_pipeline <in> <out> [smoothing=0.7] [whitening=0.6] [bright=0] [sharpen=0.25]"); exit(1) }

        guard let img = NSImage(contentsOfFile: args[1]),
              let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
            print("read fail"); exit(1)
        }

        let smoothing = args.count > 3 ? Double(args[3]) ?? 0.7 : 0.7
        let whitening = args.count > 4 ? Double(args[4]) ?? 0.6 : 0.6
        let brightening = args.count > 5 ? Double(args[5]) ?? 0 : 0
        let sharpen = args.count > 6 ? Double(args[6]) ?? 0.25 : 0.25

        var s = FilterSettings(sharpen: sharpen)
        s.smoothing = smoothing
        s.whitening = whitening
        s.brightening = brightening

        let pipeline = FilterPipeline.shared
        let out = pipeline.apply(CIImage(cgImage: cg), settings: s, time: .zero)
        guard let outCG = pipeline.renderContext.createCGImage(out, from: out.extent) else {
            print("render fail"); exit(1)
        }
        let rep = NSBitmapImageRep(cgImage: outCG)
        guard let data = rep.representation(using: .png, properties: [:]) else { print("encode fail"); exit(1) }
        try? data.write(to: URL(fileURLWithPath: args[2]))
        print("OK smoothing=\(smoothing) whitening=\(whitening) -> \(args[2])")
    }
}
