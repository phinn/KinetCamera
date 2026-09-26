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

    // MARK: - 录像时基守卫(纯决策,可单测)
    // 423861s 成片根因:录制中设备切换,新设备帧 PTS 时基与旧设备断崖(小时级跳变),
    // append 全部 ok=1 但成片视频轨 duration 天文数字,播放器炸。
    // 守卫决策:与前帧 PTS 间隔落在「倒跳>0.2s」或「前跳>0.5s」(30fps 帧距 0.033s 的 15 倍)外
    // = 时基断裂,需要重对齐 session 起点。

    /// PTS 断裂判定:delta = 新帧PTS - 前帧PTS(秒)。
    /// 正常帧距 ≈ 0.033(30fps)~0.1(网络摄掉帧);>0.5s 或倒跳超 0.2s(允许轻微重排)即断裂。
    static func isPTSDiscontinuity(deltaSeconds: Double) -> Bool {
        deltaSeconds < -0.2 || deltaSeconds > 0.5
    }

    /// 音频 PTS 平移后守卫:平移到视频时间轴后仍须非负(负 PTS 触发 AVAssetWriter -16364)。
    /// 返回 nil = 丢弃该帧;返回值 = 安全 PTS。
    static func safeAudioPTS(shiftedPTS: Double) -> Double? {
        shiftedPTS.isFinite && shiftedPTS >= 0 ? shiftedPTS : nil
    }

    /// 帧环 PTS 独立性:合成源/屏流/真机摄多源并存时,帧环混入多时基帧会让
    /// 夜拍"运动补偿对齐"误判位移。决策:进环前检查与前帧 PTS 间隔,
    /// >0.5s 视为换源,丢弃旧环(防跨时基合成)。
    static func shouldResetFrameRing(newPTS: Double, lastPTS: Double?) -> Bool {
        guard let last = lastPTS else { return false }
        return abs(newPTS - last) > 0.5
    }

    /// 硬件变焦可用性:格式最大 zoom ≤ 1.01 视为不支持(部分 USB 摄像头/虚拟设备)。
    static func hardwareZoomAvailable(formatMaxZoom: Double) -> Bool {
        formatMaxZoom > 1.01
    }
}
