import CoreImage
import CoreGraphics
import Foundation
import AppKit

// 防抖单元测试:真实帧 + 已知位移序列(模拟手抖) → 对齐合成 vs 朴素叠加
// 判据:边缘梯度能量(越高越锐)。手抖=全局平移,对齐后应恢复至接近原帧

@main
struct SteadyTest {
    static func main() {
        run()
    }

    static func run() {
func loadCG(_ path: String) -> CGImage? {
    guard let img = NSImage(contentsOfFile: path) else { return nil }
    var rect = CGRect(x: 0, y: 0, width: img.size.width, height: img.size.height)
    return img.cgImage(forProposedRect: &rect, context: nil, hints: nil)
}

func saveCG(_ cg: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: cg)
    guard let data = rep.representation(using: .png, properties: [:]) else { return }
    try? data.write(to: URL(fileURLWithPath: path))
}

// 边缘梯度能量:灰度差分绝对值和(归一化到 0-1 域/像素)
func edgeEnergy(_ cg: CGImage) -> Double {
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                              space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return 0 }
    ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
    guard let data = ctx.data else { return 0 }
    let p = data.assumingMemoryBound(to: UInt8.self)
    var sum = 0
    for y in 0..<h { for x in 1..<w { sum += abs(Int(p[y*w+x]) - Int(p[y*w+x-1])) } }
    for y in 1..<h { for x in 0..<w { sum += abs(Int(p[y*w+x]) - Int(p[(y-1)*w+x])) } }
    return Double(sum) / Double(w * h * 255)
}

// 模拟手抖:生成位移副本(抖动序列,幅度 ±2px,人手 @30fps 典型值)
func shifted(_ cg: CGImage, dx: Int, dy: Int) -> CGImage? {
    let w = cg.width, h = cg.height
    guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                              space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    ctx.setFillColor(CGColor(gray: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
    ctx.draw(cg, in: CGRect(x: CGFloat(dx), y: CGFloat(dy), width: CGFloat(w), height: CGFloat(h)))
    return ctx.makeImage()
}

guard CommandLine.arguments.count >= 2, let src = loadCG(CommandLine.arguments[1]) else {
    print("usage: steady_test <image.png>"); exit(1)
}

// 8 帧手抖序列:静止位置+随机小位移(真实手持抖动模式)
let jitter: [(Int, Int)] = [(0,0), (1,0), (-1,1), (2,-1), (-2,0), (0,2), (1,-2), (-1,-1)]
let frames = jitter.compactMap { shifted(src, dx: $0.0, dy: $0.1) }
print("注入抖动帧: \(frames.count) 帧, 序列 \(jitter)")

let comp = FrameCompositor.motionCompensatedAverage(frames, gain: 1.0, maxShift: 3)
guard let aligned = comp.image, let naive = comp.naiveImage else {
    print("合成失败 kept=\(comp.kept)"); exit(1)
}

let e0 = edgeEnergy(src)
let eNaive = edgeEnergy(naive)
let eAligned = edgeEnergy(aligned)

print("── 手抖 ±2px × 8帧 ──")
print(String(format: "原帧边缘能量:      %.4f (基准)", e0))
print(String(format: "朴素叠加(无防抖): %.4f (损失 %.1f%%)", eNaive, (1 - eNaive/e0) * 100))
print(String(format: "对齐合成(防抖):   %.4f (恢复 %.1f%% 的损失)", eAligned, (eAligned - eNaive) / (e0 - eNaive) * 100))
print("对齐残差: \(String(format: "%.4f", comp.residual)) | 未对齐残差: \(String(format: "%.4f", comp.naiveResidual)) | kept=\(comp.kept) 弃=\(comp.dropped)")
print("估计位移 vs 真实位移(y 翻转比对):")
for (i, off) in comp.offsets.enumerated() {
    let trueJ = jitter[i < jitter.count ? i : 0]
    // 期望补偿 = -抖动量;CG 绘制时 dy 再翻转一次,因此比对取 -trueJ.1
    let ok = off.dx == -trueJ.0 && off.dy == -(-trueJ.1)
    print("  帧\(i): 估计(\(off.dx),\(off.dy)) 真实补偿(\(-trueJ.0),\(trueJ.1)) \(ok ? "✓" : "✗")")
}
saveCG(naive, "/tmp/steady_naive.png")
saveCG(aligned, "/tmp/steady_aligned.png")
print("输出: /tmp/steady_naive.png /tmp/steady_aligned.png")
    }
}
