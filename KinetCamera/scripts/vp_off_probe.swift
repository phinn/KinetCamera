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
            sampleBuffer, bufferListSizeNeededOut: nil, bufferListOut: &abl,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault, blockBufferMemoryAllocator: nil,
            flags: 0, blockBufferOut: &blockBuffer) == noErr else { return }
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
        // AVAudioSession: 显式关掉 voice processing,mode 用 measurement(绕开 VI DSP)
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(.playAndRecord, mode: .measurement, options: [.allowBluetooth, .defaultToSpeaker])
            try session.setPreferredInput(session.availableInputs?.first { $0.portType == .builtInMic })
            try session.setVoiceProcessingEnabled(false)   // 关键:关闭语音处理链
            try session.setActive(true)
            print("voiceProcessing:\(session.isVoiceProcessingEnabled) input:\(session.currentRoute.inputs.first?.portName ?? "?")")
        } catch { print("session setup: \(error)") }

        let capSession = AVCaptureSession()
        capSession.sessionPreset = .high
        let dev = AVCaptureDevice.default(.microphone, for: .audio, position: .unspecified)!
        capSession.addInput(try! AVCaptureDeviceInput(device: dev))
        let output = AVCaptureAudioDataOutput()
        output.setSampleBufferDelegate(Probe.shared, queue: DispatchQueue(label: "probe"))
        capSession.addOutput(output)
        capSession.startRunning()
        Thread.sleep(forTimeInterval: 3.0)
        let db = 20 * log10(max(Probe.shared.peak, 1e-10))
        print("frames=\(Probe.shared.frames) peak=\(String(format: "%.4f", Probe.shared.peak)) \(String(format: "%.1f", db))dB")
        exit(0)
    }
}
