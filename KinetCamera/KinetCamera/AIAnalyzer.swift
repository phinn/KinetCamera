import Vision
import CoreImage
import Accelerate

// MARK: - AI 体检结果
struct AIAnalysis: Equatable {
    var blurScore: Double = 0       // 0(糊)-100(锐)
    var exposureScore: Double = 0   // 曝光质量分:0(烂)-100(理想),高分=好。方向判断用 exposureBias
    var exposureBias: Double = 0    // 曝光偏移:-1(严重欠)..0(理想)..+1(严重过)
    var faceCount: Int = 0
    var compositionHint: String? = nil
    var suggestion: String? = nil   // 一句话建议
    var colorCast: Double = 0       // 色偏:R-B 通道均值差(0-255 域);>12 偏红,<-12 偏蓝
    var brightness: Double = 0      // 帧均值亮度 0-1(场景自适应决策输入)
    var tiltAngle: Double = 0       // 水平倾角(度,正=画面向左倾);|角度|>1.2 自动转正
    var fisheyeHint: Double = 0     // 广角畸变线索 0-1(人脸贴边+宽高比异常时升高)
    var faceRect: CGRect? = nil     // 主脸归一化 bbox(原点左下;脸区加权选帧/再对焦策略输入)
    var backlight: Double = 0       // 逆光强度 0-1(脸区亮度比全局暗 >2EV 时升高;P0-3 脸优先曝光输入)

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

/// AI 修正分类(用户可独立开关的档位)。rawValue = UI/持久化 key。
enum AICorrectionKind: String, CaseIterable, Codable {
    case exposure = "曝光修正"        // 暗光增强/提亮/压高光/轻提亮
    case whiteBalance = "白平衡"      // 去暖/去冷 + 链尾二次白平衡
    case leveling = "水平校正"
    case distortion = "畸变校正"
    case sharpen = "AI补锐"
    case facePolish = "人像质感兜底"  // 人脸在场的链内磨皮美白(与用户滑杆美颜互补)

    /// 该档位在 applied 报告里的显示名前缀(用于报告行 ↔ 档位映射)
    var appliedMarkers: [String] {
        switch self {
        case .exposure: return ["暗光增强", "提亮+", "压高光", "轻提亮"]
        case .whiteBalance: return ["AI去暖", "AI去冷", "二次白平衡"]
        case .leveling: return ["水平校正"]
        case .distortion: return ["广角畸变校正"]
        case .sharpen: return ["AI补锐", "轻补锐"]
        case .facePolish: return ["AI美颜"]
        }
    }
}

/// 拍后体检:拉普拉斯方差测糊 + 亮度直方图测曝光 + Vision 人脸构图。
/// 全部 vDSP 加速,毫秒级,后台线程跑。
enum AIAnalyzer {
    /// 后台分析专用 CIContext:analyze 在 utility Task 跑,原共享 FilterPipeline.renderContext
    /// 会与主线程 draw / videoQueue 美颜链互等 CIContext 内部锁(模拟器软渲染下 UI 卡实测)。
    static let analysisContext: CIContext = {
        if let dev = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: dev, options: [
                .cacheIntermediates: false,
                .workingColorSpace: NSNull(),
            ])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()


    static func analyze(_ image: CIImage, context: CIContext) -> AIAnalysis {
        var result = AIAnalysis.empty
        guard let cg = context.createCGImage(image, from: image.extent) else { return result }

        result.blurScore = sharpnessScore(cgImage: cg)
        result.exposureScore = exposureScore(cgImage: cg)
        result.exposureBias = exposureBias(cgImage: cg)
        result.colorCast = colorCast(cg)
        result.brightness = exposureStats(cgImage: cg).mean / 255.0   // 场景自适应决策输入

        // 人脸(用于构图建议)
        let faceRequest = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([faceRequest])
        let faces = faceRequest.results ?? []
        result.faceCount = faces.count
        result.faceRect = faces.first?.boundingBox   // 主脸 bbox(脸区加权/对焦策略共用)

        // P0-3 逆光检测:脸区均值 vs 全局均值,脸暗 ≥2EV(4x)= 逆光(AE 对背景测光把脸压黑)
        if let face = result.faceRect {
            let stats = backlightStats(cgImage: cg, faceRect: face)
            // faceMean 是 0-1 域(toGray 归一),防除零 clamp 0.05(过亮脸 clamp 1 会让 ratio 恒 <1,
            // 逆光永远检不出 —— 首测 2.8x 实际场景打出 0.67 的单位 bug)
            if stats.faceMean > 0.02 {
                let ratio = stats.globalMean / max(stats.faceMean, 0.05)
                if ratio > 2.0 {
                    result.backlight = min(1.0, (ratio - 2.0) / 4.0)
                }
            }
        }

        // 水平倾角(Vision 官方 horizon 检测):|tilt|>1.2° 才值得自动转正,
        // 小角度日常手持抖动不动它(转正必裁画面,小于阈值的裁切无收益)
        let horizonReq = VNDetectHorizonRequest()
        try? handler.perform([horizonReq])
        if let obs = (horizonReq.results as? [VNHorizonObservation])?.first {
            result.tiltAngle = Double(obs.angle) * 180 / .pi   // 弧度→度
        }

        // 广角畸变线索:人脸贴近画面边缘(Vision 归一化框,左/右 20% 内)且宽高比异常大
        // —— 前置广角拍半身像时边缘人脸横向拉伸,是自拍畸变痛点的可检测信号
        if let face = faces.first {
            let edgeDist = min(face.boundingBox.minX, 1.0 - face.boundingBox.maxX)
            if edgeDist < 0.20 && face.boundingBox.width > 0.18 {
                result.fisheyeHint = min(1.0, Double((0.20 - edgeDist) / 0.20) * (face.boundingBox.width / 0.30))
            }
        }

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

    /// 逆光检测统计:脸区均值 vs 全局均值(0-255 灰度)。
    /// 脸区用归一化 bbox(原点左下 → CG 像素坐标翻转 Y),下采样 256 边算力微秒级。
    static func backlightStats(cgImage: CGImage, faceRect: CGRect) -> (faceMean: Double, globalMean: Double) {
        guard let g = toGray(cgImage) else { return (0, 0) }
        let (px, w, h) = g
        // Vision bbox 原点左下,CG 图像原点左上 → Y 翻转
        let x0 = max(0, Int(faceRect.minX * CGFloat(w)))
        let x1 = min(w - 1, Int(faceRect.maxX * CGFloat(w)))
        let y0 = max(0, Int((1.0 - faceRect.maxY) * CGFloat(h)))
        let y1 = min(h - 1, Int((1.0 - faceRect.minY) * CGFloat(h)))
        guard x1 > x0, y1 > y0 else { return (0, 0) }
        var faceSum = 0.0
        var faceN = 0.0
        for y in y0...y1 {
            let row = y * w
            for x in x0...x1 { faceSum += Double(px[row + x]); faceN += 1 }
        }
        var globalSum = 0.0
        for v in px { globalSum += Double(v) }
        guard faceN > 0 else { return (0, 0) }
        return (faceSum / faceN, globalSum / Double(px.count))
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
        // 连续比例式:cast 是 R-B 均值差(0-255 域),目标把 R/B 拉到公共均值。
        // 旧分档(0.18/0.35/0.5)对强暖图过校翻转到偏冷(none 档实测 22.8→-26.7),
        // 连续式 gain=|cast|/2/(meanR+meanB) 近似 —— 简化为 |cast|/300,上下限钳制。
        let abs_cast = abs(cast)
        if abs_cast < 6 { return 0 }
        // 强暖图实测:比例式 55.8 cast 只修到 36.7(美白层抬 R 部分抵消),除数收紧到 220
        return min(0.30, abs_cast / 220.0)
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

        // 归一化像素(0-1)换算回 0-255 域。注意 toGray 已下采样到 ≤512 边,
        // 下采样后高频能量按比例衰减,512 域实测:清晰 raw ≈ 250,轻度糊 ≈ 150,重度糊 < 60。
        // 旧系数 /400 是全分辨率域经验值,导致真实照片全挤 0-0.7 分、UI 显示"清晰度0"、
        // 且 blurScore<55 的修正触发条件恒真(每张都强制走修正链)。
        // 新系数 /2.5:512 域 250(清晰)→100 分,150(轻糊)→60,60(重糊)→24。
        let variance255 = Double(variance) * 255.0 * 255.0
        let score = min(max(variance255 / 2.5, 0), 100)
        return score
    }

    /// 人脸 ROI 清晰度分数(P0②:脸区加权选帧)。
    /// 全图 Laplacian 会被背景纹理/天空污染 —— 抓拍选帧要看"脸糊不糊"而不是"图糊不糊"。
    /// - faceRect: Vision 归一化 bbox(原点左下),转换到灰度图像素域取 ROI 重算
    /// - 无脸/ROI 退化 → 回退全图分(调用方无需特判)
    static func sharpnessScore(cgImage: CGImage, faceRect: CGRect?) -> Double {
        guard let faceRect, faceRect.width > 0.01, faceRect.height > 0.01 else {
            return sharpnessScore(cgImage: cgImage)
        }
        guard let gray = toGray(cgImage) else { return 50 }
        let w = gray.width, h = gray.height
        // Vision 原点左下 → 像素域原点左上;外扩 20%(下颌/发际一起看)
        let px = faceRect.minX * CGFloat(w)
        let pw = faceRect.width * CGFloat(w)
        let ph = faceRect.height * CGFloat(h)
        let py = (1 - faceRect.maxY) * CGFloat(h)
        let ex = max(0, px - pw * 0.2), ey = max(0, py - ph * 0.2)
        let ew = min(CGFloat(w), px + pw * 1.2) - ex
        let eh = min(CGFloat(h), py + ph * 1.2) - ey
        guard ew > 8, eh > 8 else { return sharpnessScore(cgImage: cgImage) }
        let src = gray.pixels
        var sum: Float = 0
        var count = 0
        // ROI 内 4 邻域 Laplacian 绝对值均值(高频能量,同 sharpnessScore 判据域)
        for y in max(1, Int(ey))..<min(h - 1, Int(ey + eh)) {
            let row = y * w
            for x in max(1, Int(ex))..<min(w - 1, Int(ex + ew)) {
                let i = row + x
                let lap = 4 * src[i] - src[i - w] - src[i + w] - src[i - 1] - src[i + 1]
                sum += abs(lap)
                count += 1
            }
        }
        guard count > 0 else { return sharpnessScore(cgImage: cgImage) }
        let meanLap = Double(sum / Float(count)) * 255.0
        // |lap|均值与 variance 域换算:|lap|均值在清晰脸区实测 ~6-14(255 域),糊脸 ~2-4。
        // 映射:14→100 分,2→0 分线性。
        return min(max((meanLap - 2.0) / 12.0 * 100.0, 0), 100)
    }

    /// 亮度直方图(均值+高光占比),映射到 0-100,50 为理想曝光
    static func exposureScore(cgImage: CGImage) -> Double {
        let (mean, clipRatio, _) = exposureStats(cgImage: cgImage)

        // 均值理想区间 100-160;越偏越扣分;削波额外惩罚
        let ideal: Double = 130
        let dev = abs(mean - ideal) / 130.0            // 0..1
        var score = 100.0 - dev * 90.0 - clipRatio * 120.0
        score = min(max(score, 0), 100)
        return score
    }

    /// 曝光偏移估计:-1(严重欠)..0(理想)..+1(严重过),驱动 autoCorrect 方向。
    /// 与 exposureScore(质量分)严格分离 —— 质量分高低 ≠ 过/欠曝方向,
    /// 旧代码拿质量分 >78 当"过曝"是方向性 bug(高分恰恰是接近理想)。
    static func exposureBias(cgImage: CGImage) -> Double {
        exposureStats(cgImage: cgImage).bias
    }

    private static func exposureStats(cgImage: CGImage) -> (mean: Double, clipRatio: Double, bias: Double) {
        guard let gray = toGray(cgImage) else { return (130, 0, 0) }
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
        // bias:均值偏移为主,削波方向加权(高光削波→偏亮,暗部削波→偏暗)
        let ideal: Double = 130
        var bias = (mean - ideal) / ideal
        bias += Double(clippedHigh - clippedLow) / Double(total) * 0.5
        return (mean, clipRatio, min(max(bias, -1), 1))
    }

    // CGImage -> 灰度 Float 数组(最大 512 边,内部走 RGBA 转灰度)
    private static func toGray(_ cg: CGImage) -> (pixels: [Float], width: Int, height: Int)? {
        let maxDim = 512
        let scale = min(1.0, Double(maxDim) / Double(max(cg.width, cg.height)))
        let w = max(Int(Double(cg.width) * scale), 8)
        let h = max(Int(Double(cg.height) * scale), 8)
        return grayViaRGBA(cg, w: w, h: h)
    }

    /// 帧间运动量(0-255 级灰度平均绝对差,P0-1 运动模糊对策输入)。
    /// >18 视为明显运动(宠物跑动/手抖),拍照链自动切连拍选锐。
    /// 实现:两帧各降采样 128px 灰度,逐像素 |a-b| 均值。算力 <1ms。
    static func motionScore(_ a: CIImage, _ b: CIImage, context: CIContext) -> Double {
        guard let cgA = context.createCGImage(a, from: a.extent),
              let cgB = context.createCGImage(b, from: b.extent) else { return 0 }
        let w = 128, h = max(8, w * cgA.height / max(cgA.width, 1))
        guard let ga = grayViaRGBA(cgA, w: w, h: h),
              let gb = grayViaRGBA(cgB, w: w, h: h) else { return 0 }
        var sum = 0.0
        for i in 0..<ga.pixels.count { sum += abs(Double(ga.pixels[i] - gb.pixels[i])) }
        return sum / Double(ga.pixels.count) * 255.0
    }

    /// 低分画面 → 修正链。返回(修正后图, 施加的修正名列表)。
    /// userSmoothing > 0.2 视为用户显式磨皮,自动美颜步跳过(防双重涂抹)。
    static func autoCorrect(_ image: CIImage, analysis: AIAnalysis, userSmoothing: Double = 0,
                            enabled: Set<AICorrectionKind> = Set(AICorrectionKind.allCases)) -> (image: CIImage, appliedNames: [String]) {
        var out = image
        var applied: [String] = []

        // 方向判断用 exposureBias(过/欠曝方向),不再用质量分 —— 旧代码 quality>78 被当
        // "过曝"压光是方向性 bug:高分恰恰是接近理想,导致白背景正常照片被反向压光/提亮。
        // 暗光增强档(bias < -0.45,严重欠曝)≠ 普通提亮:亮度拉起 + 降噪 + 局部对比,
        // 避免暗部噪声一起放大(普通欠曝只提亮不降噪)
        // P0-3 逆光修正(2026-09-28):脸区比全局暗 ≥2EV 时,对人脸区域局部提亮(EV 1.2 + gamma 0.8),
        // 背景不动 —— 全局提亮会把亮背景推到过曝。修正强度随 backlight 分级,轻逆光只 EV。
        if enabled.contains(.exposure), analysis.backlight > 0.15, let face = analysis.faceRect {
            let ext = out.extent
            // 脸区中心与半径(归一化 → 像素;半径放宽 1.4x 把发际/肩颈一起罩住)
            let cx = ext.minX + face.midX * ext.width
            let cy = ext.minY + face.midY * ext.height
            let r0 = max(face.width, face.height) * ext.width * 0.5
            let r1 = r0 * 1.4
            let faceMask = CIImage(color: CIColor.white).cropped(to: ext)
                .applyingFilter("CIRadialGradient", parameters: [
                    "inputCenter": CIVector(x: cx, y: cy),
                    "inputRadius0": r0,
                    "inputRadius1": r1,
                    "inputColor0": CIColor.white,
                    "inputColor1": CIColor.black,
                ])
                .cropped(to: ext)
            // 脸区提亮强度:轻逆光(0.15-0.35)只 EV 0.8;重逆光(>0.35)EV 1.2 + gamma 0.8
            let heavy = analysis.backlight > 0.35
            var lifted = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: heavy ? 1.2 : 0.8])
            if heavy {
                lifted = lifted.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.8])
            }
            out = lifted.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputImageKey: lifted,
                kCIInputBackgroundImageKey: out,
                kCIInputMaskImageKey: faceMask,
            ])
            applied.append(heavy ? "AI逆光救援(脸区提亮+gamma)" : "AI逆光补偿(脸区提亮)")
        }
        if enabled.contains(.exposure), analysis.exposureBias < -0.45 {
            out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 1.3])
            out = out.applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.78])   // 抬暗部少压高光
            out = out.applyingFilter("CINoiseReduction", parameters: ["inputNoiseLevel": 0.06, "inputSharpness": 0.6])
            out = out.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: 0.3])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.96])
            applied.append("暗光增强(亮度+降噪+对比)")  // 对比微调用gamma替代。坑:CIColorControls contrast线性域暗部clamp纯黑(黑格62→0)/CIToneCurve mac27全黑,双弃  // 提亮放大的色偏由链尾终末二次WB统一收敛
        } else if enabled.contains(.exposure), analysis.exposureBias < -0.18 {
            out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.8])
            out = out.applyingFilter("CIVibrance", parameters: [kCIInputAmountKey: 0.25])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.96])
            applied.append("提亮+0.8EV")
        } else if enabled.contains(.exposure), analysis.exposureBias > 0.18 {
            out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: -0.55])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.96])
            applied.append("压高光-0.55EV")
        } else if enabled.contains(.exposure), analysis.exposureBias < -0.08 {
            out = out.applyingFilter("CIExposureAdjust", parameters: [kCIInputEVKey: 0.35])
            applied.append("轻提亮+0.35EV")
        }

        // 色偏自动白平衡:R-B 均值差驱动,通道增益反向补偿。
        // 用 CIColorMatrix(物理直观:cast>0 压 R 抬 B),不用 CITemperatureAndTint ——
        // 其 neutral 滑块有效域窄,超域输出全黑(harness 实测 neutral=11862 全黑)
        let wbGain = whiteBalanceGain(forColorCast: analysis.colorCast)
        if enabled.contains(.whiteBalance), wbGain > 0 {
            // wbGain 0.12/0.24/0.35 → R、B 各反向收 |cast| 方向
            let rGain = analysis.colorCast > 0 ? 1.0 - wbGain : 1.0 + wbGain
            let bGain = analysis.colorCast > 0 ? 1.0 + wbGain : 1.0 - wbGain
            out = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(rGain), y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(bGain), w: 0),
            ])
            applied.append(analysis.colorCast > 0 ? "AI去暖(\(Int(analysis.colorCast)))" : "AI去冷(\(Int(analysis.colorCast)))")
        }

        // 水平校正:Vision horizon 检测的倾角,|θ|>1.2° 转正。
        // 放在曝光/白平衡之后、锐化之前:几何变换会重采样,先锐化会被插值糊掉
        // 坑1(macOS 27 实测):CIStraightenFilter 旋转角不可靠 —— 对 level 图 inputAngle=+6°
        //   实际画面转出 -11.4°(蓝线金标准测量,内部内接矩形适配干扰),用它转正反而加倍歪。
        // 坑2:CIStraightenFilter 不重置 extent 原点,链上前置 filter 平移过 extent 时
        //   再按 extent*0.94 内缩 crop 会把裁窗错位到画面外(黑边)。
        // 修法:弃用 CIStraightenFilter,显式 CGAffineTransform(rotationAngle) 旋转 +
        //   extent 归零 + 中心 94% 裁切。CGAffineTransform 行为已用蓝线几何验证:
        //   Vision 读 +6.5° 的图,rotationAngle=+6.5° 精确转正(0.00°),同号修正。
        if enabled.contains(.leveling), abs(analysis.tiltAngle) > 1.2 {
            let theta = CGFloat(analysis.tiltAngle * .pi / 180)
            // 绕图像中心旋转(标准做法):先平移中心到原点 → 旋转 → 平移回。
            // 坑:直接 transformed(rotationAngle) 是绕原点转,内容会甩出 extent;再归零 extent 时
            // 内容中心与 extent 中心不对齐,内接 crop 仍会裁进透明区(PNG 出对角黑三角)。
            let ext = out.extent
            let cx = ext.midX, cy = ext.midY
            var t = CGAffineTransform(translationX: -cx, y: -cy)
            t = t.rotated(by: theta)
            t = t.translatedBy(x: cx, y: cy)
            let rotated = out.transformed(by: t)
            // 无黑边内接矩形(绕中心旋转,内容中心=extent中心):
            // safe_w = W·cosθ - H·sinθ, safe_h = H·cosθ - W·sinθ
            let W = ext.width, H = ext.height
            let c = abs(cos(theta)), s = abs(sin(theta))
            let sw = max(W * c - H * s, W * 0.5), sh = max(H * c - W * s, H * 0.5)
            let cropRect = CGRect(x: rotated.extent.midX - sw / 2, y: rotated.extent.midY - sh / 2,
                                  width: sw, height: sh).integral
            out = rotated
                .cropped(to: cropRect)
                .transformed(by: CGAffineTransform(translationX: -cropRect.minX, y: -cropRect.minY))
            applied.append("水平校正(\(Int(analysis.tiltAngle.rounded()))°)")
        }

        // 广角畸变轻校:人脸贴边+fisheyeHint 高时,反向桶形径向映射把边缘鼓出的形变压回。
        // 不用 CIBulgeDistortion —— macOS 27 上 distortion 家族(CIBulge/Twirl/Pinch/CircleSplash)
        // 最小复现全部 extent=0/Abort,同批回归。自写 CPU 径向映射,与瘦脸 warp 同源技术。
        // 轻度(≤0.22)宁可欠修不可过修 —— 盲校正过修会把直门框修弯
        if enabled.contains(.distortion), analysis.fisheyeHint > 0.45 {
            let k1 = -0.22 * min(analysis.fisheyeHint, 1.0)
            if let fixed = radialDistortionCorrect(out, k1: k1) {
                out = fixed
                applied.append("广角畸变校正")
            }
        }

        if enabled.contains(.sharpen), analysis.blurScore < 40 {
            // 锐化 + 微反差,拉克普拉斯方差
            out = out.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputRadiusKey: 6, "inputSharpness": 0.7,
            ])
            .applyingFilter("CIGammaAdjust", parameters: ["inputPower": 0.96])
            applied.append("AI补锐")
        } else if enabled.contains(.sharpen), analysis.blurScore < 55 {
            out = out.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputRadiusKey: 4, "inputSharpness": 0.4,
            ])
            applied.append("轻补锐")
        }

        // 人像色温中性化分支已删除(2026-09-26 harness 铁证):
        // macOS 27 上 CITemperatureAndTint 连 neutral=6500 标准域也输出全黑(lum 183→0),
        // 之前只发现 neutral>1.2万全黑,实际是"任意域随机全黑",不可信。
        // 色温修正已由上方 CIColorMatrix WB gain 分级覆盖,此分支冗余且危险。

        // 人像美颜修正:人脸在场 → 磨皮+肤色掩膜美白(质感层兜底)
        // 双重涂抹防线:用户滑杆显式开磨皮(≥0.2)时跳过
        if enabled.contains(.facePolish), analysis.faceCount > 0 && userSmoothing < 0.2 {
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

        // 终末二次 WB:提亮/Gamma/降噪都会放大原色偏(harness 实测提亮使 cast -6→-28),
        // 主链 WB 在曝光修正【之前】测的 cast 已过时。对最终输出重测色偏,残差 ≥8 再补一轮。
        let finalCast = colorCast(cgOfOrEmpty(out))
        // 除数 120(主链 220 的收紧版):终末残差要求一次收敛到 |cast|<8,不再迭代
        let finalGain = min(0.30, abs(finalCast) / 120.0)
        if enabled.contains(.whiteBalance), finalGain > 0 && abs(finalCast) >= 8 {
            let rr = finalCast > 0 ? 1.0 - finalGain : 1.0 + finalGain
            let bb = finalCast > 0 ? 1.0 + finalGain : 1.0 - finalGain
            out = out.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: CGFloat(rr), y: 0, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(bb), w: 0),
            ])
            applied.append("二次白平衡(\(Int(finalCast)))")
        }
        return (out, applied)
    }

        // 暗光二次测偏用的兜底:colorCast 需要 CGImage
        private static func cgOfOrEmpty(_ image: CIImage) -> CGImage {
            sharedContext().createCGImage(image, from: image.extent)
                ?? CGContext(data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                             space: CGColorSpaceCreateDeviceRGB(),
                             bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
        }

    /// 反向桶形径向畸变校正(CPU 位移场双线性采样,与瘦脸 warp 同源技术):
    /// 输出像素 p 处采样输入的 p' = c + dir·r·(1+k1·r²),k1<0 边缘内收,压回广角外鼓。
    /// 全图均匀处理(广角畸变本就是径向全域现象),无滤波副作用。
    static func radialDistortionCorrect(_ image: CIImage, k1: Double) -> CIImage? {
        guard k1 != 0 else { return nil }   // k1<0=压回广角外鼓;k1>0=造桶形(harness 预畸变用)
        let e = image.extent
        let W = Int(e.width), H = Int(e.height)
        guard W > 16, H > 16,
              let cg = sharedContext().createCGImage(image, from: e),
              let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return nil }
        let bytes = ptr
        let bpr = cg.bytesPerRow
        let bpp = cg.bitsPerPixel / 8
        guard bpp == 4 else { return nil }

        let cx = Double(W) / 2, cy = Double(H) / 2
        let maxR = (cx * cx + cy * cy).squareRoot()
        var out = [UInt8](repeating: 0, count: W * H * 4)
        out.withUnsafeMutableBytes { (raw: UnsafeMutableRawBufferPointer) in
            let dst = raw.baseAddress!.bindMemory(to: UInt8.self, capacity: W * H * 4)
            for y in 0..<H {
                let dy = Double(y) - cy
                let rowOff = y * W * 4
                for x in 0..<W {
                    let dx = Double(x) - cx
                    let r = (dx * dx + dy * dy).squareRoot() / maxR
                    // 采样位置:反向桶形 —— r 越大往里收得越多
                    let sf = 1.0 + k1 * r * r
                    let sx = cx + dx * sf
                    let sy = cy + dy * sf
                    let o = rowOff + x * 4
                    if sx < 0 || sx >= Double(W - 1) || sy < 0 || sy >= Double(H - 1) {
                        continue   // 出界留黑边(转正后走 inset 裁切,最终成片无黑边)
                    }
                    // 双线性插值
                    let x0 = Int(sx), y0 = Int(sy)
                    let fx = sx - Double(x0), fy = sy - Double(y0)
                    let s00 = (y0 * W + x0) * 4
                    let s10 = s00 + 4
                    let s01 = s00 + W * 4
                    let s11 = s01 + 4
                    let rowB = y0 * bpr, rowB1 = rowB + bpr
                    for ch in 0..<3 {
                        let p00 = Double(bytes[rowB + x0 * bpp + ch])
                        let p10 = Double(bytes[rowB + (x0 + 1) * bpp + ch])
                        let p01 = Double(bytes[rowB1 + x0 * bpp + ch])
                        let p11 = Double(bytes[rowB1 + (x0 + 1) * bpp + ch])
                        let top = p00 + (p10 - p00) * fx
                        let bot = p01 + (p11 - p01) * fx
                        dst[o + ch] = UInt8(max(0, min(255, (top + (bot - top) * fy).rounded())))
                    }
                    dst[o + 3] = bytes[rowB + x0 * bpp + 3]
                }
            }
        }
        var outCG: CGImage?
        out.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let ctx = CGContext(data: UnsafeMutableRawPointer(mutating: raw.baseAddress),
                                      width: W, height: H, bitsPerComponent: 8, bytesPerRow: W * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            outCG = ctx.makeImage()
        }
        guard let finalCG = outCG else { return nil }
        return CIImage(cgImage: finalCG)
    }

    private static func sharedContext() -> CIContext {
        if let c = _sharedContext { return c }
        let c = CIContext(options: [.useSoftwareRenderer: false])
        _sharedContext = c
        return c
    }
    private static var _sharedContext: CIContext?

    /// 修正效果量化:对修正后图重打分(含色偏复测+曝光偏移)
    static func rescore(_ image: CIImage, context: CIContext) -> (blur: Double, exposure: Double, colorCast: Double, bias: Double) {
        guard let cg = context.createCGImage(image, from: image.extent) else { return (0, 50, 0, 0) }
        return (sharpnessScore(cgImage: cg), exposureScore(cgImage: cg), colorCast(cg), exposureBias(cgImage: cg))
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
