import AVFoundation
import Foundation

// 相机硬件能力探针(macOS 面):内置摄 vs Continuity Camera
// 编译期已实锤 unavailable(iOS only):lensPosition/setFocusModeLocked(lensPosition:)/
//   lensPositionRange/isVideoBinned/lensAperture/Format.supportedFocusModes
// 本探针输出 macOS 上真实可查的:对焦/曝光模式、RAW photo 输出能力(AVCapturePhotoOutput)

let devices = AVCaptureDevice.devices(for: .video)
print("=== 设备能力探针(macOS 27 SDK) ===")
for d in devices {
    print("\n【\(d.localizedName)】 id=\(d.uniqueID.prefix(12))")
    let fmodes: [AVCaptureDevice.FocusMode] = [.continuousAutoFocus, .autoFocus, .locked]
    print("  focusMode: \(fmodes.filter { d.isFocusModeSupported($0) }.map { "\($0)" }.joined(separator: ","))")
    let emodes: [AVCaptureDevice.ExposureMode] = [.continuousAutoExposure, .autoExpose, .locked, .custom]
    print("  exposureMode: \(emodes.filter { d.isExposureModeSupported($0) }.map { "\($0)" }.joined(separator: ","))")
    print("  高质量拍照: \(d.activeFormat.isHighPhotoQualitySupported)")
    let formats = d.formats
    print("  formats: \(formats.count) 个")
    // RAW 能力走 photoOutput:
    let out = AVCapturePhotoOutput()
    if let session = try? AVCaptureSession() {
        session.beginConfiguration()
        if let input = try? AVCaptureDeviceInput(device: d), session.canAddInput(input) {
            session.addInput(input)
            if session.canAddOutput(out) {
                session.addOutput(out)
                print("  ★ photoOutput.availableRawPhotoPixelFormatTypes: \(out.availableRawPhotoPixelFormatTypes.isEmpty ? "空(RAW不可用)" : "\(out.availableRawPhotoPixelFormatTypes.count) 个(RAW可用)")")
                print("  ★ isHighResolutionCaptureEnabled: \(out.isHighResolutionCaptureEnabled)")
            } else { print("  ★ photoOutput 不能挂(canAddOutput=false)") }
        } else { print("  ★ deviceInput 创建失败") }
        session.commitConfiguration()
    }
    // .locked 对焦真实调用:
    if d.isFocusModeSupported(.locked) {
        do {
            try d.lockForConfiguration()
            d.focusMode = .locked
            print("  ★ focusMode=.locked 设置成功")
            d.unlockForConfiguration()
        } catch { print("  ★ focusMode=.locked 抛错: \(error)") }
    }
}
if devices.isEmpty { print("(无设备)") }
