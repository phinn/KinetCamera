import AVFoundation
import CoreMedia

@main
struct MovProbe {
    static func main() {
        let path = CommandLine.arguments[1]
        let url = URL(fileURLWithPath: path)
        let asset = AVURLAsset(url: url)
        let dur = asset.duration
        print("duration: \(CMTimeGetSeconds(dur))s (\(dur.timescale) tps)")
        let vt = asset.tracks(withMediaType: .video)
        for t in vt {
            print("video: nominalFrameRate=\(t.nominalFrameRate) size=\(t.naturalSize) timeScale=\(t.naturalTimeScale) estFps=\(t.estimatedDataRate)")
        }
        let at = asset.tracks(withMediaType: .audio)
        print("audio tracks: \(at.count)")
        for a in at {
            print("audio: timeScale=\(a.naturalTimeScale)")
        }
    }
}
