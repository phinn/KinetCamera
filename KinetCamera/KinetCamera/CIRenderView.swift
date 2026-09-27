import MetalKit
import CoreImage

/// MTKView + CIImage 渲染桥:滤镜后的帧上屏
final class CIRenderView: MTKView {

    var inputCIImage: CIImage? {
        didSet {
            #if os(macOS)
            needsDisplay = true
            #else
            setNeedsDisplay(bounds)
            #endif
        }
    }
    private(set) var drawCount = 0
    private(set) var lastDrawError = ""

    private let commandQueue: MTLCommandQueue?
    // 上屏专用 CIContext:与美颜处理链(FilterPipeline.shared.renderContext)分离。
    // 根因:CIContext 内部 surface 缓存有锁,主线程 draw 的 render 与 videoQueue 的美颜/录像写帧
    // 共享同一 context 时互相等锁 —— 模拟器软渲染放大暴露,主线程卡在
    // GetSurfaceFromCacheAndFill → dispatch_sync(实测 sample 栈),表现为 UI 卡死。
    // 同一 MTLDevice 下两个 context 共享纹理/池,无额外拷贝开销。
    private let context: CIContext

    override init(frame frameRect: CGRect, device: MTLDevice?) {
        let dev = device ?? MTLCreateSystemDefaultDevice()
        commandQueue = dev?.makeCommandQueue()
        context = CIRenderView.makeContext(dev)
        super.init(frame: frameRect, device: dev)
        commonInit()
    }

    required init(coder: NSCoder) {
        let dev = MTLCreateSystemDefaultDevice()
        commandQueue = dev?.makeCommandQueue()
        context = CIRenderView.makeContext(dev)
        super.init(coder: coder)
        commonInit()
    }

    private static func makeContext(_ dev: MTLDevice?) -> CIContext {
        if let dev {
            return CIContext(mtlDevice: dev, options: [
                .cacheIntermediates: false,
                .workingColorSpace: NSNull(),
            ])
        }
        return CIContext(options: [.cacheIntermediates: false])
    }

    private func commonInit() {
        framebufferOnly = false
        enableSetNeedsDisplay = true
        isPaused = true       // 帧驱动:来一帧画一帧,不空转
        autoResizeDrawable = true
        clearColor = MTLClearColor(red: 0.04, green: 0.04, blue: 0.05, alpha: 1)
    }

    override func draw(_ rect: CGRect) {
        drawCount &+= 1
        guard let drawable = currentDrawable else {
            lastDrawError = "no drawable"
            return
        }
        guard let queue = commandQueue else {
            lastDrawError = "no queue"
            return
        }
        guard let image = inputCIImage else {
            lastDrawError = "no image"
            return
        }
        guard let commandBuffer = queue.makeCommandBuffer() else {
            lastDrawError = "no cmdbuf"
            return
        }
        lastDrawError = ""

        // aspect-fill 适配 drawable 尺寸(拆解表达式,避免推断超时)
        let layerSize = drawable.layer.drawableSize
        let target = CGRect(x: 0, y: 0, width: layerSize.width, height: layerSize.height)
        let extent = image.extent
        let extentW = Double(extent.width)
        let extentH = Double(extent.height)
        let scaleX = Double(target.width) / extentW
        let scaleY = Double(target.height) / extentH
        let scale = max(scaleX, scaleY)
        let drawW = extentW * scale
        let drawH = extentH * scale
        let tx = (Double(target.width) - drawW) / 2.0
        let ty = (Double(target.height) - drawH) / 2.0

        let scaleTransform = CGAffineTransform(scaleX: CGFloat(scale), y: CGFloat(scale))
        let translateTransform = CGAffineTransform(translationX: CGFloat(tx), y: CGFloat(ty))
        let scaled = image
            .transformed(by: scaleTransform)
            .transformed(by: translateTransform)

        // 先手动 clear(letterbox 区域为底色),再让 CI 渲染(SDK 27 已移除 rpd 重载)
        let rpd = MTLRenderPassDescriptor()
        rpd.colorAttachments[0].texture = drawable.texture
        rpd.colorAttachments[0].loadAction = .clear
        rpd.colorAttachments[0].storeAction = .store
        rpd.colorAttachments[0].clearColor = clearColor
        if let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: rpd) {
            encoder.endEncoding()
        }

        context.render(scaled,
                       to: drawable.texture,
                       commandBuffer: commandBuffer,
                       bounds: scaled.extent,
                       colorSpace: CGColorSpaceCreateDeviceRGB())
        commandBuffer.addCompletedHandler { [weak self] _ in
            DispatchQueue.main.async {
                self?.lastDrawError = "completed ok"
            }
        }
        // status: 0=enqueued 1=committed 2=scheduled 3=completed
        lastDrawError = "pre-present status=\(commandBuffer.status.rawValue)"
        commandBuffer.commit()
        commandBuffer.waitUntilScheduled()   // 确保 CI 写完调度再上屏,防撕裂
        drawable.present()
        lastDrawError = "post-commit status=\(commandBuffer.status.rawValue)"
    }
}
