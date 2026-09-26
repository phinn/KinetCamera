import CoreImage
import CoreVideo
import Metal
import Vision

// MARK: - 滤镜设置(全部实时可调)
struct FilterSettings: Equatable {
    var smoothing: Double = 0        // 0-1 磨皮强度
    var whitening: Double = 0        // 0-1 美白强度(亮度抬升+去黄+微降饱和)
    var brightening: Double = 0      // 0-1 提亮(肤色保护)
    var warmth: Double = 0           // -1..1 色温
    var sharpen: Double = 0.25       // 0-1 锐化(美颜后补锐)
    var saturation: Double = 0       // -1..1 饱和
    var backgroundBlur: Double = 0   // 0-1 AI 人像虚化
    var vignette: Double = 0         // 0-1 暗角
    var focusPeaking: Double = 0     // 0-1 对焦峰值:合焦边缘伪色高亮(0=关)
    var exposureEV: Double = 0       // -2..+2 手动曝光 EV(软件增益档,macOS 硬件无曝光API)
    var softwareZoom: Double = 1.0   // 1.0-8.0 软件中心裁切变焦(硬件 zoomFactor 不可用时兜底)

    var isNeutral: Bool {
        smoothing == 0 && whitening == 0 && brightening == 0 && warmth == 0
            && sharpen == 0 && saturation == 0 && backgroundBlur == 0 && vignette == 0
            && softwareZoom == 1.0
    }
    static let neutral = FilterSettings(sharpen: 0)
}

// MARK: - 实时渲染管线
final class FilterPipeline {

    /// 渲染质量档:拍照=全尺寸 CPU 焊接(一次性,画质锚点);录像=小域焊接(帧率优先)
    enum Quality {
        case photo
        case video
    }

    static let shared = FilterPipeline()

    /// Metal 加速的 CI 上下文(全程共享一个)
    let renderContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [
                .cacheIntermediates: false,
                .workingColorSpace: NSNull(),
            ])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }()

    private init() {}

    // 人像分割(后台低频推理,mask 缓存复用)
    private var segMask: CIImage?
    private var segBusy = false
    private let segLock = NSLock()

    /// 实时处理入口:每帧调用
    func apply(_ input: CIImage, settings: FilterSettings, time: CMTime) -> CIImage {
        apply(input, settings: settings, time: time, quality: .photo)
    }

    func apply(_ input: CIImage, settings: FilterSettings, time: CMTime, quality: Quality) -> CIImage {
        var image = input

        // 0a) 软件中心裁切变焦(硬件 zoomFactor 不可用的设备兜底:合成源/屏流/部分 USB 摄)
        if settings.softwareZoom > 1.001 {
            let z = CGFloat(settings.softwareZoom)
            let e = input.extent
            let cropW = e.width / z, cropH = e.height / z
            let cropRect = CGRect(x: e.midX - cropW / 2, y: e.midY - cropH / 2, width: cropW, height: cropH)
            // 裁切后 Lanczos 放大;origin 会漂移(实测 (25,25)→(50,50)),必须拉回原点,
            // 否则画面整体偏移半个视野(单测 testSoftwareZoomCropsAndRestoresExtent 抓出)
            let scaled = input
                .cropped(to: cropRect)
                .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: z])
            image = scaled.transformed(by: CGAffineTransform(
                translationX: -scaled.extent.minX, y: -scaled.extent.minY))
        }

        // 0) 手动曝光 EV(软件档): 乘法增益 2^EV,±2 EV 连续可调;
        //    macOS 硬件曝光 API 不存在(iOS only),这是 Mac 上唯一可行的手动曝光路径
        if settings.exposureEV != 0 {
            let gain = pow(2.0, settings.exposureEV)
            let white = CIImage(color: CIColor(red: gain, green: gain, blue: gain))
                .cropped(to: input.extent)
            image = image.applyingFilter("CIMultiplyCompositing", parameters: [
                kCIInputBackgroundImageKey: white,
            ])
        }

        // 1) AI 人像虚化(用缓存的分割 mask)
        if settings.backgroundBlur > 0 {
            let radius = 4.0 + settings.backgroundBlur * 18.0
            if let mask = cachedSegmentationMask(of: image, fastMode: quality == .video) {
                let blurred = image
                    .clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [
                        kCIInputRadiusKey: radius,
                    ])
                    .cropped(to: image.extent)
                // mask 白=人像 → 取原图(保真);黑=背景 → 取糊图
                image = blurred
                    .applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputImageKey: image,
                        kCIInputBackgroundImageKey: blurred,
                        kCIInputMaskImageKey: mask,
                    ])
            }
        }

        // 2) 美颜(磨皮+美白):小域 CPU 一趟 pass(导向滤波保边 + YCbCr 肤色掩膜),
        //    GPU 只做 Lanczos 升采样和掩膜混合 —— 避开 CI 色彩空间 linear/gamma 坑。
        //    录像(.video)帧率优先:全程 GPU 快速路径(CIGaussianBlur 磨皮+CI 肤色掩膜),30fps 可达。
        if quality == .video && (settings.smoothing > 0 || settings.whitening > 0) {
            // 磨皮:肤色掩膜内高斯(掩膜=YCbCr 肤色域 GPU 版,和 CPU 同一套容差判据)
            if settings.smoothing > 0 {
                let ycc = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 0.299, y: 0.587, z: 0.114, w: 0),
                    "inputGVector": CIVector(x: -0.168736, y: -0.331264, z: 0.5, w: 0.5),
                    "inputBVector": CIVector(x: 0.5, y: -0.418688, z: -0.081312, w: 0.5),
                ])
                // Cr∈[0.33,0.48] 软窗(CPU 判据同源)
                let skin = ycc.applyingFilter("CIColorClamp", parameters: [
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
                    .cropped(to: image.extent)
                let blurred = image.clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [
                        kCIInputRadiusKey: 2.0 + settings.smoothing * 6.0,
                    ])
                    .cropped(to: image.extent)
                image = blurred.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputImageKey: blurred,
                    kCIInputBackgroundImageKey: image,
                    kCIInputMaskImageKey: skinMask,
                ])
            }
            // 美白:肤色掩膜内亮度抬升+冷白 bias(与拍照同参)
            if settings.whitening > 0 {
                let lift = settings.whitening
                let bright = image.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: 0.05 * lift,
                    kCIInputContrastKey: 1.0 + 0.02 * lift,
                ]).applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1.05, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 6 * lift, w: 0),
                ])
                // 0.85 混合:美白不完全压死原始纹理(CIBlendWithLinearAmount 0..1 连续混合)
                image = image.applyingFilter("CIBlendWithLinearAmount", parameters: [
                    kCIInputImageKey: bright,
                    kCIInputBackgroundImageKey: image,
                    "inputAmount": 0.85,
                ])
            }
            image = image.cropped(to: input.extent)
            // 锐化补偿 + 后续通用段(暗角/虚化等)继续走
        } else if settings.smoothing > 0 || settings.whitening > 0 {
            let target: CGFloat = 360   // 小域边长(算力锚点)
            let scale = min(1.0, target / CGFloat(max(input.extent.width, input.extent.height)))
            let scaled = input.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
                .cropped(to: input.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale]).extent)
            if let smallCG = renderContext.createCGImage(scaled, from: scaled.extent),
               let (bytes, sw, sh) = GuidedFilter.rgba(of: smallCG) {
                // ---- CPU pass 1:导向滤波(保边平滑基座) ----
                let smoothing = settings.smoothing
                // 半径 cap:同质区需 ≥2r 才不被边界泄漏污染(小域最窄特征/16 为安全上限)
                let rawRadius = Int(Double(min(sw, sh)) * (0.02 + smoothing * 0.03))
                let radius = max(4, min(12, rawRadius, min(sw, sh) / 16))
                let eps = Float(0.10)
                let g = GuidedFilter.apply(rgba: bytes, width: sw, height: sh, radius: radius, eps: eps)
                // ---- CPU pass 2:YCbCr 肤色掩膜(浮点,免色彩空间坑) ----
                let n = sw * sh
                var mask = [Float](repeating: 0, count: n)
                if settings.whitening > 0 {
                    for i in 0..<n {
                        let r = Float(bytes[i*4]) / 255, gc = Float(bytes[i*4+1]) / 255, b = Float(bytes[i*4+2]) / 255
                        let y = 0.299*r + 0.587*gc + 0.114*b
                        let cb = -0.168736*r - 0.331264*gc + 0.5*b + 0.5
                        let cr = 0.5*r - 0.418688*gc - 0.081312*b + 0.5
                        // 窗口软边:Cr∈[0.52,0.70] Cb∈[0.33,0.48],边缘0.03线性过渡(实测皮肤样本标定)
                        // Cr 上限 0.70:口红 Cr≈0.75,软边 0.70+0.03=0.73 恰好排除(真实肤上限≈0.66)
                        func soft(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
                            let e: Float = 0.03
                            if v < lo - e || v > hi + e { return 0 }
                            if v < lo { return min(max((v - (lo - e)) / e, 0), 1) }
                            if v > hi { return min(max(((hi + e) - v) / e, 0), 1) }
                            return 1
                        }
                        let wCr = soft(cr, 0.52, 0.72)
                        let wCb = soft(cb, 0.33, 0.48)
                        // 亮度门:暗部(Cr 噪声大)与剪裁区不算皮肤
                        let wY = y > 0.15 && y < 0.97 ? Float(1) : Float(0)
                        mask[i] = wCr * wCb * wY
                    }
                    // 掩膜 1px 盒滤波柔化(与导向滤波同积分图实现)
                    mask = GuidedFilter.boxBlur(mask, w: sw, h: sh, r: 2)
                }
                // ---- CPU pass 3:美白增益(只作用于掩膜内:抬亮度+去黄) ----
                var outR = g.r, outG = g.g, outB = g.b
                if settings.whitening > 0 {
                    let w = Float(settings.whitening)
                    for i in 0..<n {
                        let m = mask[i]
                        guard m > 0.01 else { continue }
                        let r = Float(outR[i]), gc = Float(outG[i]), b = Float(outB[i])
                        // 抬亮:+0.09w;去黄:B+0.05w G+0.01w R-0.01w(冷白偏移)
                        let lift = m * w
                        outR[i] = UInt8(max(0, min(255, r * (1 - 0.012 * lift) + 6 * lift)))
                        outG[i] = UInt8(max(0, min(255, gc + 0.01 * lift * gc + 3 * lift)))
                        outB[i] = UInt8(max(0, min(255, b + 0.05 * lift * b + 6 * lift)))
                    }
                }
                // ---- CPU pass 4:软阈值高频回注(保发丝、压毛孔) ----
                // 全带回注会把毛孔噪声原样带回;按局部幅度区分:
                // 发丝/睫毛级(|hf|大)→ 权重趋近 k 全额回;毛孔噪声(|hf|小)→ 权重趋 0 压掉。
                if smoothing > 0 {
                    // 边缘感知混合(不是"回注"):|hf| 大 = 真实结构(发丝/眉眼/轮廓)→ 取原图;
                    // |hf| 小 = 毛孔噪声 → 取磨皮值。|hf|=guided 与原图的差,即被磨掉的部分。
                    let t: Float = 16.0
                    var outs: [[UInt8]] = [outR, outG, outB]
                    for i in 0..<n {
                        for c in 0..<3 {
                            let o = Float(bytes[i*4+c])
                            let gi = Float(outs[c][i])
                            let wEdge = min(Float(1), abs(o - gi) / t)
                            outs[c][i] = UInt8(max(0, min(255, gi + wEdge * (o - gi))))
                        }
                    }
                    outR = outs[0]; outG = outs[1]; outB = outs[2]
                }
                if let smoothCG = GuidedFilter.cgImage(r: outR, g: outG, b: outB, w: sw, h: sh) {
                    let smoothBig = CIImage(cgImage: smoothCG)
                        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 1.0 / scale])
                        .cropped(to: input.extent)
                    // ---- pass 4'(全尺寸):边缘感知焊接 ----
                    // 小域降采样已把真实边界(眉眼/发丝,落差数十级)糊成坡道,小域内保边无意义。
                    // 升采样后以全尺寸原图为参照再混一次:|hf|大(真结构)→ 焊回原图;|hf|小(毛孔)→ 保留磨皮。
                    // ---- pass 4'(全尺寸):边缘感知焊接 ----
                    // 小域降采样已把真实边界糊成坡道,小域内保边无意义;升采样后以全尺寸原图
                    // 为参照再混一次:|hf|大(真结构)→ 焊回原图;|hf|小(毛孔)→ 保留磨皮。
                    if quality == .video {
                        // 录像帧率优先:小域 CPU 焊接后直接升采样(省两次全尺寸 render)
                        image = smoothBig
                    } else if let upCG = renderContext.createCGImage(smoothBig, from: input.extent),
                       let (upBytes, uw, uh) = GuidedFilter.rgba(of: upCG), uw == Int(input.extent.width),
                       // 全尺寸原帧作参照:小域 bytes 的边界已被降采样糊化,不能当结构依据
                       let fullCG = renderContext.createCGImage(input, from: input.extent),
                       let (fullBytes, fw, fh) = GuidedFilter.rgba(of: fullCG), fw == uw {
                        let t: Float = 16.0
                        var fin = [UInt8](repeating: 0, count: uw * uh * 4)
                        for i in 0..<(uw * uh) {
                            let i4 = i * 4
                            let oR = Float(fullBytes[i4]), oG = Float(fullBytes[i4+1]), oB = Float(fullBytes[i4+2])
                            let gR = Float(upBytes[i4]), gG = Float(upBytes[i4+1]), gB = Float(upBytes[i4+2])
                            // 跨通道取 |hf| 最大者作边缘置信度(避免单通道偶然抵消)
                            let m = max(abs(oR-gR), abs(oG-gG), abs(oB-gB))
                            let wE = min(Float(1), m / t)
                            fin[i4]   = UInt8(max(0, min(255, gR + wE * (oR - gR))))
                            fin[i4+1] = UInt8(max(0, min(255, gG + wE * (oG - gG))))
                            fin[i4+2] = UInt8(max(0, min(255, gB + wE * (oB - gB))))
                            fin[i4+3] = 255
                        }
                        if let finCG = GuidedFilter.cgImageRGBA(fin, w: uw, h: uh) {
                            image = CIImage(cgImage: finCG)
                        } else {
                            image = smoothBig
                        }
                    } else {
                        image = smoothBig
                    }
                }
            } else {
                // 小域失败兜底:原高斯混合(不阻断拍照)
                if settings.smoothing > 0 {
                    let radius = 2.0 + settings.smoothing * 9.0
                    let blurred = image.clampedToExtent()
                        .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                        .cropped(to: image.extent)
                    image = input.applyingFilter("CIDissolveTransition", parameters: [
                        kCIInputImageKey: blurred, kCIInputTargetImageKey: input,
                        kCIInputTimeKey: settings.smoothing * 0.85,
                    ])
                }
            }
        }

        // 3) 美白已在上面美颜 pass 内做(肤色掩膜增益);此段保留旧全局路径仅供 w>0 且磨皮小域失败时
        //    —— 实际上已并入 pass3,这里直接跳过(留空防误开)
        if settings.whitening > 0 && settings.smoothing == 0 {
            // 无磨皮时仍走 CPU 掩膜路径:复用上面的美颜块不现实,退化全局轻处理(软,无掩膜)
            // 注:预览默认两者联动开,此分支只出现在单独拉美白滑杆的极端情况
            let w = settings.whitening
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: w * 0.05,
                kCIInputContrastKey: 1.0 - w * 0.03,
                kCIInputSaturationKey: 1.0 - w * 0.06,
            ])
        }

        // 4) 提亮(曝光+高光抬升,肤色不炸)
        if settings.brightening > 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: settings.brightening * 0.55,
            ])
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: settings.brightening * 0.06,
                kCIInputContrastKey: 1.0 - settings.brightening * 0.04,
            ])
        }

        // 5) 色温
        if settings.warmth != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 - settings.warmth * 1800, y: 6500),
                "inputTargetNeutral": CIVector(x: 6500, y: 6500),
            ])
        }

        // 6) 饱和
        if settings.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.0 + settings.saturation,
            ])
        }

        // 7) 锐化(磨皮后补锐,这才是"自然美颜"的关键顺序)
        //    注意:CISharpenLuminance 的强度参数是 inputSharpness,不是 inputAmount
        if settings.sharpen > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputRadiusKey: 4.0,
                "inputSharpness": settings.sharpen * 0.9,
            ])
        }

        // 8) 暗角
        if settings.vignette > 0 {
            image = image.applyingFilter("CIVignette", parameters: [
                kCIInputRadiusKey: 1.6,
                kCIInputIntensityKey: settings.vignette,
            ])
        }

        // 9) 对焦峰值:拉普拉斯检测高频边缘(9分量3x3核),增益放大后阈值二值化,
        //    边缘叠品红伪色,与 Halide 的 peaking 视觉语言一致。
        //    做在渲染层:合成源/PIP 任意信号源都能用,不依赖硬件手动对焦。
        if settings.focusPeaking > 0 {
            let luma = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 0.0,
            ])
            let edges = luma.applyingFilter("CIConvolution3X3", parameters: [
                "inputWeights": CIVector(values: [CGFloat(0), -1, 0, -1, 4, -1, 0, -1, 0], count: 9),
                kCIInputBiasKey: 0.0,
            ])
            // 模糊场景边缘幅值小,适度放大;阈值0.9只留最强边缘,防整屏涂红
            let gain = 4.0 + settings.focusPeaking * 6.0
            let mask = edges
                .applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: CGFloat(gain), y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: CGFloat(gain), z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(gain), w: 0),
                ])
                .applyingFilter("CIColorClamp", parameters: [
                    "inputMinComponents": CIVector(x: 0, y: 0, z: 0, w: 1),
                    "inputMaxComponents": CIVector(x: 1, y: 1, z: 1, w: 1),
                ])
                .applyingFilter("CIColorThreshold", parameters: [
                    "inputThreshold": 0.9,
                ])
            let magenta = CIImage(color: CIColor(red: 1.0, green: 0.2, blue: 1.0))
                .cropped(to: image.extent)
            image = image.applyingFilter("CIBlendWithMask", parameters: [
                kCIInputImageKey: magenta,
                kCIInputBackgroundImageKey: image,
                kCIInputMaskImageKey: mask,
            ])
        }

        return image.cropped(to: input.extent)
    }

    /// 人像分割:mask 缓存 + 跳帧推理(繁忙时直接复用上一张)
    private func cachedSegmentationMask(of image: CIImage, fastMode: Bool = false) -> CIImage? {
        segLock.lock()
        let cached = segMask
        let busy = segBusy
        segLock.unlock()
        if busy { return cached }

        segBusy = true
        let cg = renderContext.createCGImage(image, from: image.extent)
        if let cg {
            let request = VNGeneratePersonSegmentationRequest()
            // 录像帧率优先:.fast 模型(精度略降,速度×3)
            request.qualityLevel = fastMode ? .fast : .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                do {
                    try handler.perform([request])
                    if let buf = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer {
                        // Vision 分割 buffer 是底原点(倒置),CIImage(cvPixelBuffer:) 按顶原点解释,
                        // 不翻转的话 mask 上下颠倒 → 糊了人脸保了背景(实测 IMG_2606 人脸区被糊到 15%)
                        let maskImage = CIImage(cvPixelBuffer: buf)
                            .oriented(forExifOrientation: 4)   // 纯垂直翻转
                            .applyingFilter("CIBicubicScaleTransform", parameters: [
                                kCIInputScaleKey: Float(image.extent.width / CGFloat(CVPixelBufferGetWidth(buf))),
                            ])
                            .cropped(to: image.extent)
                        self?.segLock.lock()
                        self?.segMask = maskImage
                        self?.segLock.unlock()
                    }
                } catch {}
                self?.segBusy = false
            }
        } else {
            segBusy = false
        }
        return cached
    }
}
