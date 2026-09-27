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
    var faceSlim: Double = 0         // 0-1 瘦脸(Vision 下颌 landmark 驱动的局部 warp)

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
    /// 最近一次小域 CPU pass 估计的噪声 σ(0-255 域),pass4' 全尺寸焊接共用
    private var lastNoiseSigma: Float = 5.3
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

        // 0b) 瘦脸:Vision 下颌 landmark 驱动的局部几何 warp(两侧脸颊向中线收)
        if settings.faceSlim > 0, let faceRect = cachedFaceRect(of: image) {
            image = applyFaceSlim(image, faceRect: faceRect, strength: settings.faceSlim)
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
                // 强度参与混合(此前 s 只进 radius,4→12px 早饱和 → 同帧 SSIM 0.995 的根因):
                // 先用常数灰 mask 把"磨皮模糊图 vs 原图"消融到 α(s),再叠肤色掩膜空间限定。
                // 常数灰 mask + CIBlendWithMask = amount 混合(已验证通路;BlendWithLinearAmount 在
                // macOS 27 对 BlendWithMask 输出求值返回空 extent,禁用)。
                let alphaS = 0.55 + settings.smoothing * 0.45
                let amountMask = CIImage(color: CIColor(red: CGFloat(alphaS), green: CGFloat(alphaS), blue: CGFloat(alphaS)))
                    .cropped(to: image.extent)
                let faded = blurred.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputImageKey: blurred,
                    kCIInputBackgroundImageKey: image,
                    kCIInputMaskImageKey: amountMask,
                ])
                // faded = α·blur + (1-α)·原图(全图);再按肤色掩膜混回原图 → 只磨肤区
                image = faded.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputImageKey: faded,
                    kCIInputBackgroundImageKey: image,
                    kCIInputMaskImageKey: skinMask,
                ])
            }
            // 美白:肤色掩膜内亮度抬升+冷白 bias(与拍照同参)
            if settings.whitening > 0 {
                // gamma 0.7 感知化:w=0.6 → 实际 0.7(线性 0.6 在亮肤上 R-B 位移仅 ~6 级,肉眼难辨)
                let lift = pow(settings.whitening, 0.7)
                let bright = image.applyingFilter("CIColorControls", parameters: [
                    kCIInputBrightnessKey: 0.07 * lift,
                    kCIInputContrastKey: 1.0 + 0.02 * lift,
                ]).applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: 1, y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: 1, z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: 1.05, w: 0),
                    "inputBiasVector": CIVector(x: 0, y: 0, z: 6 * lift, w: 0),
                ])
                // 0.85 混合:美白不完全压死原始纹理。
                // 不用 CIBlendWithLinearAmount / CISourceOverCompositing —— macOS 27 上二者
                // 对被 CIBlendWithMask 处理过的图求值返回空 extent(step_bench 实测归零)。
                // 常数灰 mask + CIBlendWithMask 等价于 amount 混合,已验证可行。
                let constMask = CIImage(color: CIColor(red: 0.85, green: 0.85, blue: 0.85))
                    .cropped(to: image.extent)
                image = image.applyingFilter("CIBlendWithMask", parameters: [
                    kCIInputImageKey: bright,
                    kCIInputBackgroundImageKey: image,
                    kCIInputMaskImageKey: constMask,
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
                // ---- CPU pass 3:美白增益已迁移到 pass5(全尺寸焊接后)----
                // 2026-09-27 根因:美白在小域做,升采样后被边缘焊接当噪声差焊回原图,B+14 被吃成 +2
                var outR = g.r, outG = g.g, outB = g.b
                // ---- CPU pass 2.5:噪声水平估计(自适应保边阈值的基础) ----
                // 高频残差 MAD×1.4826 = 稳健 σ 估计(MAD 对结构边缘不敏感,均值会被发丝拉高)
                // σ_255 = 噪声标准差(0-255 域)。暗光高 ISO → σ 大 → 阈值 t 大(压噪优先);
                // 棚拍/好光 → σ 小 → t 小(毛孔细节保留)。t = 3σ:3 倍标准差外的才当结构。
                var absDevs = [Float](repeating: 0, count: n)
                for i in 0..<n {
                    let r0 = Float(bytes[i*4]); let g0 = Float(g.r[i]); let b0 = Float(bytes[i*4+2])
                    let gray = 0.299 * r0 + 0.587 * Float(g.g[i]) + 0.114 * b0
                    let grayS = 0.299 * g0 + 0.587 * Float(g.g[i]) + 0.114 * Float(g.b[i])
                    absDevs[i] = abs(gray - grayS)
                }
                absDevs.sort()
                let medianDev = absDevs[n / 2]
                let noiseSigma = medianDev * 1.4826
                // 小域已把噪声平均掉一部分(Lanczos 降采样率 scale),换算回全尺寸域的 σ
                // 全尺寸磨皮值 = 小域升采样,其噪声 ≈ 小域σ × (1/scale) × 插值增益(≈1)
                let fullSigma = noiseSigma / Float(scale)
                let adaptiveT = max(Float(8), fullSigma * 3)
                lastNoiseSigma = fullSigma
                if quality == .photo { NSLog("[KinetCamera] noiseEstimate smallDomain=%.2f full=%.2f t=%.1f", noiseSigma, fullSigma, adaptiveT) }

                // ---- CPU pass 4:软阈值高频回注(保发丝、压毛孔) ----
                // 全带回注会把毛孔噪声原样带回;按局部幅度区分:
                // 发丝/睫毛级(|hf|大)→ 权重趋近 k 全额回;毛孔噪声(|hf|小)→ 权重趋 0 压掉。
                if smoothing > 0 {
                    // 软阈值:2.5σ 以内视为噪声全额压掉,超出部分按比例回注(真结构 |hf|>>σ 全回)
                    let thr: Float = max(Float(8), fullSigma * 1.5)
                    var outs: [[UInt8]] = [outR, outG, outB]
                    for i in 0..<n {
                        for c in 0..<3 {
                            let o = Float(bytes[i*4+c])
                            let gi = Float(outs[c][i])
                            let hf = abs(o - gi)
                            let wEdge = hf > thr ? (hf - thr) / hf : 0
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
                        // 软阈值(与 pass4 同源):2.5σ 内压掉,超出按比例回注
                        let thr: Float = max(8, lastNoiseSigma * 1.5)
                        // 强度 α 直接决定磨皮与原图最终配比(此前恒=1,s 形同虚设)
                        let alpha = 0.35 + 0.65 * Float(settings.smoothing)
                        var fin = [UInt8](repeating: 0, count: uw * uh * 4)
                        for i in 0..<(uw * uh) {
                            let i4 = i * 4
                            let oR = Float(fullBytes[i4]), oG = Float(fullBytes[i4+1]), oB = Float(fullBytes[i4+2])
                            let gR = Float(upBytes[i4]), gG = Float(upBytes[i4+1]), gB = Float(upBytes[i4+2])
                            // 跨通道取 |hf| 最大者作边缘置信度(避免单通道偶然抵消)
                            let m = max(abs(oR-gR), abs(oG-gG), abs(oB-gB))
                            let wE = m > thr ? (m - thr) / m : 0
                            // 焊接结果与原图按 α 混:α 低 → 向原图回退,s 高 → 全量磨皮
                            fin[i4]   = UInt8(max(0, min(255, (gR + wE * (oR - gR)) * alpha + oR * (1 - alpha))))
                            fin[i4+1] = UInt8(max(0, min(255, (gG + wE * (oG - gG)) * alpha + oG * (1 - alpha))))
                            fin[i4+2] = UInt8(max(0, min(255, (gB + wE * (oB - gB)) * alpha + oB * (1 - alpha))))
                            fin[i4+3] = 255
                        }
                        // ---- CPU pass 5:全尺寸美白(焊接之后,不被 wE 吃掉)----
                        if settings.whitening > 0 {
                            let w = Float(pow(settings.whitening, 0.7))   // gamma 0.7 感知化
                            for i in 0..<(uw * uh) {
                                let i4 = i * 4
                                let r = Float(fin[i4]) / 255, gc = Float(fin[i4+1]) / 255, b = Float(fin[i4+2]) / 255
                                let y = 0.299*r + 0.587*gc + 0.114*b
                                let cb = -0.168736*r - 0.331264*gc + 0.5*b + 0.5
                                let cr = 0.5*r - 0.418688*gc - 0.081312*b + 0.5
                                func soft(_ v: Float, _ lo: Float, _ hi: Float) -> Float {
                                    let e: Float = 0.03
                                    if v < lo - e || v > hi + e { return 0 }
                                    if v < lo { return min(max((v - (lo - e)) / e, 0), 1) }
                                    if v > hi { return min(max(((hi + e) - v) / e, 0), 1) }
                                    return 1
                                }
                                let m = soft(cr, 0.52, 0.72) * soft(cb, 0.33, 0.48) * (y > 0.15 && y < 0.97 ? 1 : 0)
                                guard m > 0.01 else { continue }
                                let lift = m * w
                                // 去黄主刀:B +14w(冷白偏移)+ R -2.5%w;抬亮 G +4w。w=1 → R-B 位移约 -18 级
                                let nr = r * 255 * (1 - 0.025 * lift) + 4 * lift
                                let ng = gc * 255 * (1 + 0.015 * lift) + 4 * lift
                                let nb = b * 255 * (1 + 0.10 * lift) + 14 * lift
                                fin[i4]   = UInt8(max(0, min(255, nr)))
                                fin[i4+1] = UInt8(max(0, min(255, ng)))
                                fin[i4+2] = UInt8(max(0, min(255, nb)))
                            }
                        }
                        if quality == .photo { NSLog("[KinetWeld] welded n=\(uw*uh) alpha=\(alpha) whitened=\(settings.whitening > 0)") }
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

        // 3) 美白已在上面美颜 pass 内做(肤色掩膜增益,单开美白同样走 CPU pass —— 180 行分支条件
        //    本就是 smoothing>0 || whitening>0)。旧全局 CIColorControls 退化分支已删除:
        //    它在 CPU pass 之后叠加执行造成双重美白,且无掩膜污染背景(实测单开美白背景墙 +8.4 亮度),
        //    contrast 线性域还与 AIAnalyzer 踩的同族坑相邻(09-26 复查)。

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

    // MARK: - 瘦脸(Vision 人脸框 + CPU 位移场双线性 warp)
    // CIWarpKernel 在 macOS 27 上 apply 恒返回 nil(最小复现 warptest2 三种 roi/参数全 NIL,
    // 与 CITemperatureAndTint 全黑同批 CI 框架回归),故瘦脸走 CPU 域 —— 与美颜 CPU pass 同域,
    // 脸框一次检测 + 位移场一次遍历,1080p 拍照链实测 ~8ms,video 链可扛 30fps。

    private var cachedFace: (rect: CGRect, extent: CGRect)?

    /// 检测最大人脸框(像素域,CI 坐标原点左下)。同帧 extent 不变时复用,避免每帧跑 Vision。
    func cachedFaceRect(of image: CIImage) -> CGRect? {
        if let c = cachedFace, c.extent == image.extent {
            // 坑:0脸时缓存 CGRect.null —— 缓存命中直接返回会把 null 框(非nil)漏给下游,
            // 瘦脸/五官锚定全走 guard 失败静默失效(实测 slim 输出与 before 逐字节相同)。
            return c.rect.isNull ? nil : c.rect
        }
        guard let cg = renderContext.createCGImage(image, from: image.extent) else { return nil }
        let req = VNDetectFaceLandmarksRequest()
        let handler = VNImageRequestHandler(cgImage: cg, options: [:])
        try? handler.perform([req])
        guard let face = (req.results ?? []).max(by: { $0.boundingBox.width < $1.boundingBox.width }) else {
            cachedFace = (CGRect.null, image.extent)
            return nil
        }
        // 坑:某些合成/低质图上 Vision 返回 inf/NaN bbox(实测合成肤色样张 bbox=(inf,inf,0,0)),
        // 乘 extent 后仍是 inf 框,非 nil 地漏给下游瘦脸/五官锚定,全部 guard 失败静默失效。
        if face.boundingBox.width.isNaN || face.boundingBox.width.isInfinite || face.boundingBox.width <= 0
            || face.boundingBox.height.isNaN || face.boundingBox.height.isInfinite || face.boundingBox.height <= 0 {
            cachedFace = (CGRect.null, image.extent)
            return nil
        }
        // VN 归一化(原点左下)→ CI 像素域(原点左下,同向直接乘)
        let e = image.extent
        let b = face.boundingBox
        let rect = CGRect(x: b.origin.x * e.width,
                          y: b.origin.y * e.height,
                          width: b.width * e.width,
                          height: b.height * e.height)
        cachedFace = (rect, image.extent)
        return rect
    }

    /// 瘦脸:脸颊带(脸框下半 55%,下颌区)内像素向中轴水平收拢。
    /// 位移场:水平高斯(σ=0.42 半脸宽)× 垂直带窗(脸底=1 线性降到脸中 0)。
    /// 峰值位移 = 0.045 × strength × 脸宽(0.8 档 ≈ 3.6% 脸宽)。BGRA 一趟双线性采样。
    fileprivate func applyFaceSlim(_ image: CIImage, faceRect: CGRect, strength: Double) -> CIImage {
        let e = image.extent
        let W = Int(e.width), H = Int(e.height)
        guard W > 0, H > 0,
              let cg = renderContext.createCGImage(image, from: e),
              let data = cg.dataProvider?.data, let ptr = CFDataGetBytePtr(data) else { return image }
        let bytes = ptr
        let bpr = cg.bytesPerRow
        let bpp = cg.bitsPerPixel / 8
        guard bpp == 4 else { return image }

        // 脸框(图像坐标 y 向下:flip)
        let fx = max(0, faceRect.minX - e.minX), fy = max(0, e.height - (faceRect.maxY - e.minY))
        let fw = min(faceRect.width, e.width - fx), fh = min(faceRect.height, e.height - fy)
        guard fw > 8, fh > 8 else { return image }
        let cx = fx + fw / 2
        let peakShift = 0.045 * strength * fw   // 中轴处最大内收

        var out = [UInt8](repeating: 0, count: W * H * 4)
        let bandTop = fy + fh * 0.45            // 脸颊带顶(下颌区上沿)
        let bandBottom = fy + fh * 0.999        // 脸框底
        let sigmaX = 0.42 * fw / 2

        func sample(_ x: Double, _ y: Double) -> (UInt8, UInt8, UInt8, UInt8) {
            let xi = min(W - 2, max(0, Int(x))), yi = min(H - 2, max(0, Int(y)))
            let fx1 = min(Double(W - 2), max(0, x)), fy1 = min(Double(H - 2), max(0, y))
            let dx = fx1 - Double(xi), dy = fy1 - Double(yi)
            func px(_ xx: Int, _ yy: Int) -> Int { (yy * bpr) + (xx * bpp) }
            let o00 = px(xi, yi), o10 = px(xi + 1, yi), o01 = px(xi, yi + 1), o11 = px(xi + 1, yi + 1)
            var rgba = [UInt8](repeating: 0, count: 4)
            for c in 0..<4 {
                let v00 = Double(bytes[o00 + c]), v10 = Double(bytes[o10 + c])
                let v01 = Double(bytes[o01 + c]), v11 = Double(bytes[o11 + c])
                let v = v00 * (1 - dx) * (1 - dy) + v10 * dx * (1 - dy) + v01 * (1 - dx) * dy + v11 * dx * dy
                rgba[c] = UInt8(max(0, min(255, v.rounded())))
            }
            return (rgba[0], rgba[1], rgba[2], rgba[3])
        }

        for y in Int(bandTop)..<Int(bandBottom) {
            let t = (Double(y) - bandTop) / (bandBottom - bandTop)   // 0=带顶 1=带底
            let bandW = 0.35 + 0.65 * t                               // 下颌处最强
            for x in Int(fx)..<Int(fx + fw) {
                let dxp = Double(x) - cx
                let g = exp(-0.5 * (dxp * dxp) / (sigmaX * sigmaX))
                let shift = peakShift * g * bandW * (dxp >= 0 ? 1 : -1)
                let src = sample(Double(x) + shift, Double(y))        // 采样位移后的源点
                let o = (y * W + x) * 4
                out[o] = src.0; out[o + 1] = src.1; out[o + 2] = src.2; out[o + 3] = src.3
            }
        }
        // 脸域外直接拷贝
        for y in 0..<H {
            let inBand = y >= Int(bandTop) && y < Int(bandBottom)
            let rowOff = y * W * 4
            if inBand {
                for x in 0..<Int(fx) { let o = rowOff + x * 4; let s = y * bpr + x * bpp
                    out[o] = bytes[s]; out[o+1] = bytes[s+1]; out[o+2] = bytes[s+2]; out[o+3] = bytes[s+3] }
                for x in Int(fx + fw)..<W { let o = rowOff + x * 4; let s = y * bpr + x * bpp
                    out[o] = bytes[s]; out[o+1] = bytes[s+1]; out[o+2] = bytes[s+2]; out[o+3] = bytes[s+3] }
            } else {
                out.withUnsafeMutableBytes { dst in
                    memcpy(dst.baseAddress! + rowOff, bytes + y * bpr, W * 4)
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
        guard let finalCG = outCG else { return image }
        return CIImage(cgImage: finalCG)
    }
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
