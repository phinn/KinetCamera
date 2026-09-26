import AVFoundation
import Foundation

let devices = AVCaptureDevice.devices(for: .video)
print("视频设备总数: \(devices.count)")
for d in devices {
    let fmt = CMVideoFormatDescriptionGetDimensions(d.activeFormat.formatDescription)
    let conn = d.isConnected ? "在线" : "离线"
    print("- \(d.localizedName) | \(d.uniqueID.prefix(24)) | \(fmt.width)x\(fmt.height) | \(conn)")
}
