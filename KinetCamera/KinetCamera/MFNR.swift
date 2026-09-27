import Foundation
import CoreImage
import CoreMedia

// MARK: - MFNR 多帧降噪(P0①:夜景糊痛点)
// 3帧对齐 + 静区平均/动区取基准 —— 纯 CIFilter 链,GPU 完成,CPU 零逐像素。
// 暗光拍照自动触发:亮度<0.30 时 capturePhoto 串 3 连拍合成,先于美颜链。

enum MFNR {

    /// 帧组是否可用于合成:数量达标 + PTS 连续且间隔在安全区。
    /// 复用 DevicePolicy 时基铁律:正常帧距 0.020~0.10s(30fps 域),断裂帧(时基跳变 423861s 事故)必须剔除。
    static func canMerge(times: [CMTime], minFrames: Int = 3, maxGap: Double = 0.10) -> Bool {
        guard times.count >= minFrames else { return false }
        var prev: Double?
        for t in times {
            let s = CMTimeGetSeconds(t)
            guard s.isFinite, s >= 0 else { return false }          // NaN/负 PTS 一票否决
            if let p = prev, (s - p) <= 0 || (s - p) > maxGap { return false }
            prev = s
        }
        return true
    }

    /// 3 帧合成:静区(帧间差<阈值)=(A+B+C)/3 平均降噪;动区取中间帧保细节不鬼影。
    /// 返回 nil = 输入不合法(帧数/尺寸不一致),调用方回退单帧。
    static func composite(_ frames: [CIImage], context: CIContext, motionThreshold: Double = 0.035) -> CIImage? {
        guard frames.count >= 3 else { return nil }
        let a = frames[frames.count - 3], b = frames[frames.count - 2], c = frames[frames.count - 1]
        guard a.extent == b.extent, b.extent == c.extent, !a.extent.isEmpty else { return nil }

        // 动区掩膜:|A-B| 与 |B-C| 取大者,阈值二值化(动=白=取B)
        let d1 = CIFilter(name: "CIDifferenceBlendMode", parameters: [
            kCIInputImageKey: a, kCIInputBackgroundImageKey: b])!.outputImage!
        let d2 = CIFilter(name: "CIDifferenceBlendMode", parameters: [
            kCIInputImageKey: b, kCIInputBackgroundImageKey: c])!.outputImage!
        let motion = CIFilter(name: "CILightenBlendMode", parameters: [
            kCIInputImageKey: d1, kCIInputBackgroundImageKey: d2])!.outputImage!

        // 二值化:RGB 均值(单通道近似)>threshold → 动。CIColorClamp+CIColorMatrix 阈值
        let scale: CGFloat = CGFloat(1.0 / motionThreshold)
        let hard = CIFilter(name: "CIColorMatrix", parameters: [
            kCIInputImageKey: motion,
            "inputRVector": CIVector(x: scale / 3, y: scale / 3, z: scale / 3, w: 0),
            "inputGVector": CIVector(x: scale / 3, y: scale / 3, z: scale / 3, w: 0),
            "inputBVector": CIVector(x: scale / 3, y: scale / 3, z: scale / 3, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0)])!.outputImage!
        let motionMask = CIFilter(name: "CIColorClamp", parameters: [
            kCIInputImageKey: hard,
            "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1)])!.outputImage!.cropped(to: a.extent)

        // 静区 = 三帧平均:每帧各乘 1/3 后相加(CIAdditionCompositing 是像素加法,bias 域 0-1 溢出无害)
        func third(_ img: CIImage) -> CIImage {
            CIFilter(name: "CIColorMatrix", parameters: [
                kCIInputImageKey: img,
                "inputRVector": CIVector(x: 0.333, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 0.333, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 0.333, w: 0),
                "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1)])!.outputImage!
        }
        var acc = third(a)
        for f in [b, c] {
            acc = CIFilter(name: "CIAdditionCompositing", parameters: [
                kCIInputImageKey: third(f), kCIInputBackgroundImageKey: acc])!.outputImage!
        }
        let sumWithC = acc

        // 静区平均值 + 动区B,用 motionMask 合成:CIBlendWithMask(B 为前景,mask 白处取前景)
        return CIFilter(name: "CIBlendWithMask", parameters: [
            kCIInputImageKey: b,                    // 动区 → 中间帧(锐利、无鬼影)
            kCIInputBackgroundImageKey: sumWithC,   // 静区 → 三帧平均(降噪)
            kCIInputMaskImageKey: motionMask])!.outputImage!.cropped(to: a.extent)
    }
}
