import AVFoundation
import Foundation
@main struct Main {
    static func main() {
        let devices = AVCaptureDevice.devices(for: .video)
        print("视频设备总数: \(devices.count)")
        for d in devices {
            let fmt = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
            let fps = d.activeFormat.videoSupportedFrameRateRanges.map { Int($0.maxFrameRate) }.max() ?? 0
            print("- [\(d.uniqueID.prefix(24))] \(d.localizedName) | \(fmt.width)x\(fmt.height)@\(fps) | model=\(d.modelID)")
        }
        // iPhone 连续互通检查
        let iPhone = devices.filter { $0.modelID.contains("iPhone") || $0.localizedName.contains("iPhone") || $0.localizedName.contains("连续") }
        print("连续互通相机(Desk View/iPhone): \(iPhone.count)")
        exit(0)
    }
}
