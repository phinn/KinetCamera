import Foundation
import CoreGraphics

/// 多摄切换/变焦的纯决策逻辑。无硬件依赖、无 session 副作用,全部可单测。
/// CameraManager 在主线程调用这些函数后,才去动 AVCaptureSession。
enum DevicePolicy {

    /// 主摄切换守卫:
    /// - 录像中禁止切换(防 AVAssetWriter 写坏文件)
    /// - 同设备重复切换 = no-op(防会话无谓重建,重建即 200ms 黑屏)
    /// - 目标设备必须在线(防切向已拔出的摄像头导致 session 空转)
    static func canSwitch(isRecording: Bool, current: String?, target: String, liveDevices: [String]) -> Bool {
        if isRecording { return false }
        if target == current { return false }
        return liveDevices.contains(target)
    }

    /// 主摄掉线/启动时的接管:现值仍在线则保持(不乱跳),否则接管第一台在线设备。
    static func fallbackActive(current: String?, devices: [String]) -> String? {
        if let c = current, devices.contains(c) { return c }
        return devices.first
    }

    /// PIP 清理:已离线设备从 PIP 列表摘除(防成片合成引用死源出黑块);
    /// 屏流伪设备不在 live 枚举里,永不清除。
    static func stalePIPs(pips: [String], liveDevices: [String], screenPseudoID: String) -> [String] {
        pips.filter { $0 != screenPseudoID && !liveDevices.contains($0) }
    }

    /// 变焦钳制:下限 1.0(不缩),上限取「格式上限」与「8.0 画质红线」较小者。
    /// >8x 数码放大糊穿,宁可给不到也不出马赛克。
    static func clampZoom(_ factor: Double, formatMax: Double) -> Double {
        let qualityCeiling = 8.0
        let upper = min(formatMax, qualityCeiling)
        return min(max(1.0, factor), max(1.0, upper))
    }

    /// 硬件变焦可用性:格式最大 zoom ≤ 1.01 视为不支持(部分 USB 摄像头/虚拟设备)。
    static func hardwareZoomAvailable(formatMaxZoom: Double) -> Bool {
        formatMaxZoom > 1.01
    }
}
