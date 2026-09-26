import AVFoundation
import AppKit

// 抽指定轨道的帧:遍历 sample 输出过于复杂,改用 generator + preferredTransform 不行(只主轨)。
// 正解:AVAssetReader 逐帧读指定 track,输出指定 PTS 的 PNG。
@main
struct ExtractTrackFrame {
    static func main() {
        let a = Array(CommandLine.arguments.dropFirst())
        let path = a[0]; let trackIdx = Int(a[1])!; let atSec = Double(a[2])!; let out = a[3]
        let asset = AVURLAsset(url: URL(fileURLWithPath: path))
        guard let track = asset.tracks(withMediaType: .video)[safe: trackIdx] else {
            print("no track \(trackIdx)"); return
        }
        var reader: AVAssetReader!
        do { reader = try AVAssetReader(asset: asset) } catch { print("reader err"); return }
        let outSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: outSettings)
        reader.add(output)
        reader.startReading()
        let want = CMTime(seconds: atSec, preferredTimescale: 600)
        var last: CVPixelBuffer?
        var lastTS: CMTime = .zero
        let ctx = CIContext()
        while let sb = output.copyNextSampleBuffer() {
            let ts = CMSampleBufferGetPresentationTimeStamp(sb)
            if ts > want {
                if last == nil { last = CMSampleBufferGetImageBuffer(sb); lastTS = ts }
                break
            }
            last = CMSampleBufferGetImageBuffer(sb)
            lastTS = ts
        }
        if let pb = last {
            let ci = CIImage(cvPixelBuffer: pb)
            let cg = ctx.createCGImage(ci, from: ci.extent)!
            let rep = NSBitmapImageRep(cgImage: cg)
            let png = rep.representation(using: .png, properties: [:])!
            try! png.write(to: URL(fileURLWithPath: out))
            print("track\(trackIdx) @\(CMTimeGetSeconds(lastTS))s -> \(out) \(cg.width)x\(cg.height)")
        } else { print("no frames") }
    }
}
extension Array { subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil } }
