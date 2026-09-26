import AVFoundation
import AppKit

@main
struct ExtractFrame {
    static func main() {
        let args = Array(CommandLine.arguments.dropFirst())
        let path = args[0]; let at = Double(args[1]) ?? 1.0
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.requestedTimeToleranceBefore = .zero
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.1, preferredTimescale: 600)
        do {
            let cg = try gen.copyCGImage(at: CMTime(seconds: at, preferredTimescale: 600), actualTime: nil)
            let rep = NSBitmapImageRep(cgImage: cg)
            guard let png = rep.representation(using: .png, properties: [:]) else { return }
            try png.write(to: URL(fileURLWithPath: args[2]))
            print("extracted @\(at)s -> \(args[2])")
        } catch { print("ERR \(error)") }
    }
}
