import AVFoundation
import Foundation

final class Probe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = Probe()
    var frames = 0
    var peak: Float = 0
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        frames += 1
        var abl = AudioBufferList()
        abl.mNumberBuffers = 2
        var blockBuffer: CMBlockBuffer?
        guard CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: &blockBuffer
        ) == noErr else { return }
        for buf in UnsafeMutableAudioBufferListPointer(&abl) {
            let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
            guard let data = buf.mData else { continue }
            data.withMemoryRebound(to: Float.self, capacity: n) { p in
                for i in 0..<n { let v = abs(p[i]); if v > peak { peak = v } }
            }
        }
    }
}

@main struct Main {
    static func main() {
        let targets = AVCaptureDevice.devices(for: .audio)
        for dev in targets {
            let session = AVCaptureSession()
            session.sessionPreset = .high
            guard let input = try? AVCaptureDeviceInput(device: dev) else { print("[\(dev.localizedName)] input create FAIL"); continue }
            session.addInput(input)
            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(Probe.shared, queue: DispatchQueue(label: "probe"))
            session.addOutput(output)
            Probe.shared.frames = 0
            Probe.shared.peak = 0
            session.startRunning()
            Thread.sleep(forTimeInterval: 2.5)
            let db = 20 * log10(max(Probe.shared.peak, 1e-10))
            print("[\(dev.localizedName)] frames=\(Probe.shared.frames) peak=\(String(format: "%.4f", Probe.shared.peak)) \(String(format: "%.1f", db))dB")
            session.stopRunning()
            session.removeInput(input)
            session.removeOutput(output)
        }
        exit(0)
    }
}
