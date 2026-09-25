import CoreImage
import CoreVideo
import Metal
import Vision

// MARK: - 滤镜设置(全部实时可调)
struct FilterSettings: Equatable {
    var smoothing: Double = 0        // 0-1 磨皮强度
    var brightening: Double = 0      // 0-1 提亮(肤色保护)
    var warmth: Double = 0           // -1..1 色温
    var sharpen: Double = 0.25       // 0-1 锐化(美颜后补锐)
    var saturation: Double = 0       // -1..1 饱和
    var backgroundBlur: Double = 0   // 0-1 AI 人像虚化
    var vignette: Double = 0         // 0-1 暗角

    var isNeutral: Bool {
        smoothing == 0 && brightening == 0 && warmth == 0
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

        // 3) 提亮(曝光+高光抬升,肤色不炸)
        if settings.brightening > 0 {
            image = image.applyingFilter("CIExposureAdjust", parameters: [
                kCIInputEVKey: settings.brightening * 0.55,
            ])
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputBrightnessKey: settings.brightening * 0.06,
                kCIInputContrastKey: 1.0 - settings.brightening * 0.04,
            ])
        }

        // 4) 色温
        if settings.warmth != 0 {
            image = image.applyingFilter("CITemperatureAndTint", parameters: [
                "inputNeutral": CIVector(x: 6500 - settings.warmth * 1800, y: 6500),
                "inputTargetNeutral": CIVector(x: 6500, y: 6500),
            ])
        }

        // 5) 饱和
        if settings.saturation != 0 {
            image = image.applyingFilter("CIColorControls", parameters: [
                kCIInputSaturationKey: 1.0 + settings.saturation,
            ])
        }

        // 6) 锐化(磨皮后补锐,这才是"自然美颜"的关键顺序)
        //    注意:CISharpenLuminance 的强度参数是 inputSharpness,不是 inputAmount
        if settings.sharpen > 0 {
            image = image.applyingFilter("CISharpenLuminance", parameters: [
                kCIInputRadiusKey: 4.0,
                "inputSharpness": settings.sharpen * 0.9,
            ])
        }

        // 7) 暗角
        if settings.vignette > 0 {
            image = image.applyingFilter("CIVignette", parameters: [
                kCIInputRadiusKey: 1.6,
                kCIInputIntensityKey: settings.vignette,
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
