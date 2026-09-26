import Vision
import CoreImage
import Accelerate

// MARK: - AI 体检结果
struct AIAnalysis: Equatable {
    var blurScore: Double = 0       // 0(糊)-100(锐)
    var exposureScore: Double = 0   // 0(欠曝)-100(过曝),50 为佳
    var faceCount: Int = 0
    var compositionHint: String? = nil
    var suggestion: String? = nil   // 一句话建议
    var colorCast: Double = 0       // 色偏:R-B 通道均值差(0-255 域);>12 偏红,<-12 偏蓝

    static let empty = AIAnalysis()
}

// MARK: - 拍照体检报告(落盘 JSON 伴生文件,可复现)
struct CaptureReport: Codable, Equatable {
    var beforeBlur: Double
    var beforeExposure: Double
    var afterBlur: Double
    var afterExposure: Double
    var applied: [String]
    var improved: Bool
    var faceCount: Int
    var beforeColorCast: Double = 0
    var afterColorCast: Double = 0
}

/// 拍后体检:拉普拉斯方差测糊 + 亮度直方图测曝光 + Vision 人脸构图。
/// 全部 vDSP 加速,毫秒级,后台线程跑。
enum AIAnalyzer {

    static func analyze(_ image: CIImage, context: CIContext) -> AIAnalysis {
        var result = AIAnalysis.empty
        guard let cg = context.createCGImage(image, from: image.extent) else { return result }

        result.blurScore = sharpnessScore(cgImage: cg)
        result.exposureScore = exposureScore(cgImage: cg)
        result.colorCast = colorCast(cg)

        // 人脸(用于构图建议)
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([faceRequest])
        let faces = faceRequest.results ?? []
        result.faceCount = faces.count

        if faces.count == 1 {
            let box = faces[0].boundingBox   // 归一化,原点左下
            let cx = box.midX
            let cy = box.midY
            if cy < 0.30 {
                result.compositionHint = "人像偏下,建议上移镜头留出头顶空间"
            } else if cx < 0.35 {
                result.compositionHint = "人像偏左"
            } else if cx > 0.65 {
                result.compositionHint = "人像偏右"
            } else {
                result.compositionHint = "构图良好"
            }
        } else if faces.count > 1 {
            result.compositionHint = "画面中有 \(faces.count) 张人脸,注意都入镜"
        }

        // 综合建议
        var tips: [String] = []
        if result.blurScore < 30 { tips.append("画面偏糊,建议稳住或对焦") }
        if result.exposureScore < 25 { tips.append("欠曝,建议加光或提亮") }
        if result.exposureScore > 80 { tips.append("过曝,建议逆光补偿") }
        if result.colorCast > 20 { tips.append("画面偏暖/偏红") }
        if result.colorCast < -20 { tips.append("画面偏冷/偏蓝") }
        result.suggestion = tips.isEmpty ? "画质 OK,可拍" : tips.joined(separator:";")
        return result
    }

    /// 色偏检测:全图 R、B 通道均值差(0-255 域)。
    /// 白光下 R≈B,暖光源(钨丝灯)R>B 为正,冷光(阴天/屏幕)R<B 为负。
    /// 检测窗口下采样到 256 边,vDSP 均值,微秒级。
    static func colorCast(_ cgImage: CGImage) -> Double {
        let maxDim = 256
        let scale = min(1.0, Double(maxDim) / Double(max(cgImage.width, cgImage.height)))
        let w = max(Int(Double(cgImage.width) * scale), 8)
        let h = max(Int(Double(cgImage.height) * scale), 8)
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cgImage, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return 0 }
        var rSum = 0.0, bSum = 0.0
        let n = w * h
        for i in 0..<n {
            rSum += Double(rgba[i * 4])
            bSum += Double(rgba[i * 4 + 2])
        }
        return (rSum - bSum) / Double(n)
    }

    /// 色偏修正强度决策(纯函数,可单测):
    /// |cast| < 8 不动(噪声容差);8-20 轻度纠正;20-40 标准;>40 强纠正但封顶 0.35
    /// (强色偏往往混着光源光谱缺失,纠过头出灰尸脸,封顶留给用户手动调)
    static func whiteBalanceGain(forColorCast cast: Double) -> Double {
        let abs_cast = abs(cast)
        if abs_cast < 8 { return 0 }
        if abs_cast < 20 { return 0.18 }
        if abs_cast < 40 { return 0.35 }
        return 0.5
    }

    /// 拉普拉斯方差(经典清晰度指标,归一化到 0-100)
    static func sharpnessScore(cgImage: CGImage) -> Double {
        guard let gray = toGray(cgImage) else { return 50 }
        let w = gray.width, h = gray.height
        var lap = [Float](repeating: 0, count: w * h)
        var src = gray.pixels

        // 离散拉普拉斯: 4*I - 上 - 下 - 左 - 右
        for y in 1..<(h - 1) {
            let row = y * w
            for x in 1..<(w - 1) {
                let i = row + x
                lap[i] = 4 * src[i] - src[i - w] - src[i + w] - src[i - 1] - src[i + 1]
            }
        }
        var mean: Float = 0
        var variance: Float = 0
        vDSP_meanv(lap, 1, &mean, vDSP_Length(w * h))
        var centered = lap
        var negMean = -mean
        vDSP_vsadd(lap, 1, &negMean, &centered, 1, vDSP_Length(w * h))
        vDSP_svesq(centered, 1, &variance, vDSP_Length(w * h))
        variance /= Float(w * h)

        // 归一化像素(0-1)换算回 0-255 域再映射:variance_255 = variance_01 * 255²
        // 经验映射:0-255 域 variance 0→0分,>400→100分
        let variance255 = Double(variance) * 255.0 * 255.0
        let score = min(max(variance255 / 400.0, 0), 100)
        return score
    }

    /// 亮度直方图(均值+高光占比),映射到 0-100,50 为理想曝光
    static func exposureScore(cgImage: CGImage) -> Double {
        guard let gray = toGray(cgImage) else { return 50 }
        var hist = [Int](repeating: 0, count: 256)
        for p in gray.pixels {
            hist[min(Int(p * 255), 255)] += 1
        }
        let total = gray.pixels.count
        var sum: Double = 0
        var clippedHigh = 0
        var clippedLow = 0
        for (v, c) in hist.enumerated() {
            sum += Double(v) * Double(c)
            if v >= 250 { clippedHigh += c }
            if v <= 5 { clippedLow += c }
        }
        let mean = sum / Double(total)                 // 0-255
        let clipRatio = Double(clippedHigh + clippedLow) / Double(total)

        // 均值理想区间 100-160;越偏越扣分;削波额外惩罚
        let ideal: Double = 130
        let dev = abs(mean - ideal) / 130.0            // 0..1
        var score = 100.0 - dev * 90.0 - clipRatio * 120.0
        score = min(max(score, 0), 100)
        return score
    }

    // CGImage -> 灰度 Float 数组(最大 512 边,内部走 RGBA 转灰度)
    private static func toGray(_ cg: CGImage) -> (pixels: [Float], width: Int, height: Int)? {
        let maxDim = 512
        let scale = min(1.0, Double(maxDim) / Double(max(cg.width, cg.height)))
        let w = max(Int(Double(cg.width) * scale), 8)
        let h = max(Int(Double(cg.height) * scale), 8)
        return grayViaRGBA(cg, w: w, h: h)
    }

    /// 低分画面 → 修正链。返回(修正后图, 施加的修正名列表)。
    /// userSmoothing > 0.2 视为用户显式磨皮,自动美颜步跳过(防双重涂抹)。
    static func autoCorrect(_ image: CIImage, analysis: AIAnalysis, userSmoothing: Double = 0) -> (image: CIImage, appliedNames: [String]) {
        var out = image
        var applied: [String] = []

        if analysis.exposureScore < 35 {
            out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.8])
            out = out.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: 0.25])
            out = out.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.06])
            applied.append("提亮+0.8EV")
        } else if analysis.exposureScore > 78 {
            out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.55])
            out = out.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.1])
            applied.append("压高光-0.55EV")
        } else if analysis.exposureScore < 42 {
            out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.35])
            applied.append("轻提亮+0.35EV")
        }

        // 色偏自动白平衡:R-B 均值差驱动,通道增益反向补偿。
        // 用 CIColorMatrix(物理直观:cast>0 压 R 抬 B),不用 CITemperatureAndTint ——
        // 其 neutral 滑块有效域窄,超域输出全黑(harness 实测 neutral=11862 全黑)
        let wbGain = whiteBalanceGain(forColorCast: analysis.colorCast)
        if wbGain > 0 {
            // wbGain 0.12/0.24/0.35 → R、B 各反向收 |cast| 方向
            let rGain = analysis.colorCast > 0 ? 1.0 - wbGain : 1.0 + wbGain
            let bGain = analysis.colorCast > 0 ? 1.0 + wbGain : 1.0 - wbGain
            out = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(rGain), y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(bGain), w: 0),
            ])
            applied.append(analysis.colorCast > 0 ? "AI去暖(\(Int(analysis.colorCast)))" : "AI去冷(\(Int(analysis.colorCast)))")
        }

        if analysis.blurScore < 40 {
            // 锐化 + 微反差,拉克普拉斯方差
            out = out.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputRadiusKey: 6, "inputSharpness": 0.7,
            ])
            out = out.applyingFilter("CIColorControls", parameters: [kCIInputContrastKey: 1.05])
            applied.append("AI补锐")
        } else if analysis.blurScore < 55 {
            out = out.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputRadiusKey: 4, "inputSharpness": 0.4,
            ])
            applied.append("轻补锐")
        }

        if analysis.faceCount > 0 && analysis.exposureScore >= 35 && analysis.exposureScore <= 78 {
            out = out.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500, y: 6500),
            ])
            applied.append("人像色温中性化")
        }

        // 人像美颜修正:人脸在场 → 磨皮+肤色掩膜美白(质感层兜底)
        // 双重涂抹防线:用户滑杆显式开磨皮(≥0.2)时跳过
        if analysis.faceCount > 0 && userSmoothing < 0.2 {
            let skin = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
                "inputGVector": CIVector(x: -0.168736, y: -0.331264, z: 0.5, w: 0.5),
                "inputBVector": CIVector(x: 0.5, y: -0.418688, z: -0.081312, w: 0.5),
            ]).applyingFilter("CIColorClamp", parameters: [
                "inputMinComponents": CIVector(x: 0, y: 0.49, z: 0.33, w: 0),
                "inputMaxComponents": CIVector(x: 0, y: 0.75, z: 0.48, w: 1),
            ]).applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 0, y: 12.5, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 12.5, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: 12.5, w: 0),
                "inputBiasVector": CIVector(x: 0, y: -9.25, z: -7.06, w: 0),
            ])
            let skinMask = skin.clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 2.0])
                .cropped(to: out.extent)
            let polished = out.applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 5.0])
            out = polished.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputImageKey: polished,
                kCIInputBackgroundImageKey: out,
                kCIInputMaskImageKey: skinMask,
            ])
            applied.append("AI美颜(磨皮+肤色美白)")
        }
        return (out, applied)
    }

    /// 修正效果量化:对修正后图重打分(含色偏复测)
    static func rescore(_ image: CIImage, context: CIContext) -> (blur: Double, exposure: Double, colorCast: Double) {
        guard let cg = context.createCGImage(image, from: image.extent) else { return (0, 50, 0) }
        return (sharpnessScore(cgImage: cg), exposureScore(cgImage: cg), colorCast(cg))
    }

    /// 亮度均值(CIAreaAverage,AE 闭环用,微秒级)
    static func quickMean(_ image: CIImage, context: CIContext) -> Double {
        let extent = image.extent
        guard extent.width > 1, extent.height > 1 else { return 0 }
        let avg = image.applyingFilter("CIAreaAverage", parameters: [
            kCIInputExtentKey: CIVector(cgRect: extent),
        ])
        var pixel = [UInt8](repeating: 0, count: 4)
        context.render(avg, toBitmap: &pixel, rowBytes: 4,
                       bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                       format: .RGBA8, colorSpace: CGColorSpaceCreateDeviceRGB())
        // 相对亮度(Rec.601 加权,归一 0-1)
        return (Double(pixel[0]) * 0.299 + Double(pixel[1]) * 0.587 + Double(pixel[2]) * 0.114) / 255.0
    }

    /// 稳定路径:转 RGBA8 再 CPU 转灰度
    private static func grayViaRGBA(_ cg: CGImage, w: Int, h: Int) -> (pixels: [Float], width: Int, height: Int)? {
        var rgba = [UInt8](repeating: 0, count: w * h * 4)
        let ok = rgba.withUnsafeMutableBytes { ptr -> Bool in
            guard let ctx = CGContext(
                data: ptr.baseAddress,
                width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.interpolationQuality = .medium
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        var out = [Float](repeating: 0, count: w * h)
        for i in 0..<(w * h) {
            let r = Float(rgba[i * 4])
            let g = Float(rgba[i * 4 + 1])
            let b = Float(rgba[i * 4 + 2])
            out[i] = (r * 0.299 + g * 0.587 + b * 0.114) / 255.0
        }
        return (out, w, h)
    }
}
