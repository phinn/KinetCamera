import AVFoundation
import Foundation

// 最小相机探针:开 session + data output,3 秒统计帧数
final class Probe: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
    var count = 0
    let session = AVCaptureSession()
    let lock = NSLock()

    func run() {
        let devices = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera], mediaType: .video, position: .unspecified).devices
        print("devices: \(devices.map { $0.localizedName })")
        guard let cam = devices.first else { exit(2) }
        guard let input = try? AVCaptureDeviceInput(device: cam) else { print("input fail"); exit(3) }
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: DispatchQueue(label: "probe"))
        session.beginConfiguration()
        session.sessionPreset = .high
        if session.canAddInput(input) { session.addInput(input) }
        if session.canAddOutput(output) { session.addOutput(output) }
        session.commitConfiguration()
        session.startRunning()
        print("running=\(session.isRunning) connEnabled=\(output.connection(with: .video)?.isEnabled ?? false)")
        Thread.sleep(forTimeInterval: 3)
        lock.lock()
        print("frames in 3s: \(count)")
        lock.unlock()
        exit(count > 0 ? 0 : 1)
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func captureOutput(_ output: AVCaptureOutput, didDrop sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        print("drop!")
    }
}

print("auth:", AVCaptureDevice.authorizationStatus(for: .video).rawValue)
if AVCaptureDevice.authorizationStatus(for: .video) != .authorized {
    print("requesting...")
    let sem = DispatchSemaphore(value: 0)
    AVCaptureDevice.requestAccess(for: .video) { _ in sem.signal() }
    sem.wait()
}
Probe().run()
