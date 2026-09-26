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

        // 2) 磨皮:高斯模糊与原图按强度混合(上限0.85,永远保留一点真实纹理)
        if settings.smoothing > 0 {
            let radius = 2.0 + settings.smoothing * 9.0
            let blurred = image
                .clampedToExtent()
                .applyingFilter("CIGaussianBlur", parameters: [kCIInputRadiusKey: radius])
                .cropped(to: image.extent)
            image = input.applyingFilter("CIDissolveTransition", parameters: [
                kCIInputImageKey: blurred,
                kCIInputTargetImageKey: input,
                kCIInputTimeKey: settings.smoothing * 0.85,
            ])
        }

        // 3) 美白:亮度抬升 + 去黄(B通道抬升压 R) + 微降饱和防塑料感
        //    实现用 CILinearToSRGBToneCurve 近似 sRGB 曲线抬亮,再用 CIColorMatrix 去黄
        if settings.whitening > 0 {
            let w = settings.whitening
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: w * 0.10,          // 黑位抬升
                kCIInputContrastKey: 1.0 - w * 0.03,      // 轻微降对比,肤色更透
                kCIInputSaturationKey: 1.0 - w * 0.10,    // 去黄的第一层:降饱和
            ])
            image = image.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0.02 * w, z: 1 + 0.04 * w, w: 0), // B 通道微增益+吃一点 G
                "inputBiasVector": CIVector(x: 0, y: 0.01 * w, z: 0.03 * w, w: 0),  // 整体冷白偏移
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
