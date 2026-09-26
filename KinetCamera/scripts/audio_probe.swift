// 层1取证:HAL 直采物理麦,量化真实输入电平(绕开 app 全链路)
import AVFoundation
import Foundation

final class Probe: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate {
    static let shared = Probe()
    var frames = 0
    var peak: Float = 1e-10
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
        let session = AVCaptureSession()
        session.sessionPreset = .high
        guard let mic = AVCaptureDevice.default(.builtInMicrophone, for: .audio, position: .unspecified) else {
            print("FATAL: no builtInMicrophone"); return
        }
        print("device:", mic.localizedName)
        let input = try! AVCaptureDeviceInput(device: mic)
        session.addInput(input)
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(Probe.shared, queue: DispatchQueue(label: "probe"))
        session.addOutput(output)
        session.startRunning()
        Thread.sleep(forTimeInterval: 3.0)
        let db = 20 * log10(Probe.shared.peak)
        print("frames: \(Probe.shared.frames)  peakLinear: \(Probe.shared.peak)  peakdB: \(String(format: "%.1f", db))")
        session.stopRunning()
        exit(0)
    }
}
