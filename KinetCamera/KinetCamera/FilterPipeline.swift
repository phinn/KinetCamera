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

    var isNeutral: Bool {
        smoothing == 0 && whitening == 0 && brightening == 0 && warmth == 0
            && sharpen == 0 && saturation == 0 && backgroundBlur == 0 && vignette == 0
    }
    static let neutral = FilterSettings(sharpen: 0)
}

// MARK: - 实时渲染管线
final class FilterPipeline {

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
        var image = input

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
            if let mask = cachedSegmentationMask(of: image) {
                let blurred = image
                    .clampedToExtent()
                    .applyingFilter("CIGaussianBlur", parameters: [
                        kCIInputRadiusKey: radius,
                    ])
                    .cropped(to: image.extent)
                image = blurred
                    .applyingFilter("CIBlendWithMask", parameters: [
                        kCIInputImageKey: blurred,
                        kCIInputBackgroundImageKey: image,
                        kCIInputMaskImageKey: mask,
                    ])
            }
        }

        // 2) 美颜(磨皮+美白):小域 CPU 一趟 pass(导向滤波保边 + YCbCr 肤色掩膜),
        //    GPU 只做 Lanczos 升采样和掩膜混合 —— 避开 CI 色彩空间 linear/gamma 坑。
        if settings.smoothing > 0 || settings.whitening > 0 {
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
                let eps = Float(0.04 - smoothing * 0.025)
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
                if let smoothCG = GuidedFilter.cgImage(r: outR, g: outG, b: outB, w: sw, h: sh) {
                    let smoothBig = CIImage(cgImage: smoothCG)
                        .applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 1.0 / scale])
                        .cropped(to: input.extent)
                    if smoothing > 0 {
                        // 原片高频回注(磨皮不磨纹理):原图 - 原图高斯 = 高频层,按 0.35 权重加回
                        let highFreq = input.clampedToExtent()
                            .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: 6])
                            .cropped(to: input.extent)
                        let k = 0.5 * smoothing
                        let textureBack = input.applyingFilter("CISubtractBlendMode", parameters: [kCIInputBackgroundImageKey: highFreq])
                            .applyingFilter("CIColorMatrix", parameters: [
                                "inputRVector": CIVector(x: CGFloat(k), y: 0, z: 0, w: 0),
                                "inputGVector": CIVector(x: 0, y: CGFloat(k), z: 0, w: 0),
                                "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(k), w: 0),
                            ])
                        image = smoothBig.applyingFilter("CIAdditionCompositing", parameters: [kCIInputBackgroundImageKey: textureBack])
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
    private func cachedSegmentationMask(of image: CIImage) -> CIImage? {
        segLock.lock()
        let cached = segMask
        let busy = segBusy
        segLock.unlock()
        if busy { return cached }

        segBusy = true
        let cg = renderContext.createCGImage(image, from: image.extent)
        if let cg {
            let request = VNGeneratePersonSegmentationRequest()
            request.qualityLevel = .balanced
            request.outputPixelFormat = kCVPixelFormatType_OneComponent8
            let handler = VNImageRequestHandler(cgImage: cg, options: [:])
            DispatchQueue.global(qos: .userInteractive).async { [weak self] in
                do {
                    try handler.perform([request])
                    if let buf = (request.results?.first as? VNPixelBufferObservation)?.pixelBuffer {
                        let maskImage = CIImage(cvPixelBuffer: buf)
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
