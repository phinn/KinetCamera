import CoreGraphics
import ImageIO
import Foundation
import UniformTypeIdentifiers

// KinetCamera App 图标生成器
// 设计语言:深色空间感底 + 三摄镜头组(呼应"把几个摄像头都用上")+ 取景框高光
// 产出:单源 1024x1024 PNG(macOS icns / iOS AppIcon 共用母版)
// 复跑:xcrun swiftc -O -o /tmp/gen_icon KinetCamera/scripts/gen_icon.swift && /tmp/gen_icon

let size = 1024
let s = CGFloat(size)
let cs = CGColorSpace(name: CGColorSpace.sRGB)!
let ctx = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                    bytesPerRow: 0, space: cs,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

// ── 背景:深空径向渐变(摄影 App 的"暗房"语汇)────────────────
let bgColors = [CGColor(srgbRed: 0.10, green: 0.115, blue: 0.15, alpha: 1),
                CGColor(srgbRed: 0.032, green: 0.038, blue: 0.062, alpha: 1)] as CFArray
let bgGrad = CGGradient(colorsSpace: cs, colors: bgColors, locations: [0, 1])!
ctx.drawRadialGradient(bgGrad,
                       startCenter: CGPoint(x: s*0.5, y: s*0.62), startRadius: 0,
                       endCenter: CGPoint(x: s*0.5, y: s*0.5), endRadius: s*0.75,
                       options: [.drawsAfterEndLocation])

// ── 细噪点纹理(避免大平面死色,成像质感)────────────────
ctx.setBlendMode(.overlay)
for _ in 0..<2600 {
    let x = CGFloat.random(in: 0..<s), y = CGFloat.random(in: 0..<s)
    let a = CGFloat.random(in: 0...0.05)
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: a))
    ctx.fill(CGRect(x: x, y: y, width: 2, height: 2))
}
ctx.setBlendMode(.normal)

// ── 主镜头组:三摄呈品字排布(超广角/广角/长焦)────────────────
// 镜头通用画法:外环(金属渐变)→ 玻璃深底 → 镜片反光弧 → 内瞳 + 紫膜镀膜反光
func drawLens(center: CGPoint, radius: CGFloat, tint: (CGFloat, CGFloat, CGFloat)) {
    let r = radius
    // 外金属环
    let ringColors = [CGColor(srgbRed: 0.52, green: 0.55, blue: 0.62, alpha: 1),
                      CGColor(srgbRed: 0.16, green: 0.175, blue: 0.22, alpha: 1),
                      CGColor(srgbRed: 0.40, green: 0.43, blue: 0.50, alpha: 1)] as CFArray
    let ringGrad = CGGradient(colorsSpace: cs, colors: ringColors, locations: [0, 0.55, 1])!
    ctx.saveGState()
    // 环体:clip 外圆后铺径向渐变(金属立体感)
    ctx.saveGState()
    ctx.addArc(center: center, radius: r, startAngle: 0, endAngle: .pi*2, clockwise: false)
    ctx.clip()
    ctx.drawRadialGradient(ringGrad, startCenter: center, startRadius: r*0.5,
                           endCenter: center, endRadius: r,
                           options: [.drawsAfterEndLocation])
    ctx.restoreGState()

    // 玻璃深底
    ctx.setFillColor(CGColor(srgbRed: 0.02, green: 0.025, blue: 0.045, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: center.x - r*0.86, y: center.y - r*0.86,
                               width: r*1.72, height: r*1.72))

    // 内环细线
    ctx.setStrokeColor(CGColor(srgbRed: 0.22, green: 0.25, blue: 0.32, alpha: 0.85))
    ctx.setLineWidth(r*0.032)
    ctx.strokeEllipse(in: CGRect(x: center.x - r*0.72, y: center.y - r*0.72,
                                 width: r*1.44, height: r*1.44))

    // 镜片紫膜镀膜反光(斜向弧)
    ctx.saveGState()
    ctx.addArc(center: center, radius: r*0.62, startAngle: .pi*0.15, endAngle: .pi*0.85, clockwise: false)
    ctx.addArc(center: center, radius: r*0.30, startAngle: .pi*0.85, endAngle: .pi*0.15, clockwise: true)
    ctx.closePath()
    ctx.clip()
    let coatColors = [CGColor(srgbRed: tint.0, green: tint.1, blue: tint.2, alpha: 0.55),
                      CGColor(srgbRed: tint.0*0.4, green: tint.1*0.4, blue: tint.2*0.4, alpha: 0.05)] as CFArray
    let coatGrad = CGGradient(colorsSpace: cs, colors: coatColors, locations: [0, 1])!
    ctx.drawLinearGradient(coatGrad,
                           start: CGPoint(x: center.x - r*0.7, y: center.y - r*0.7),
                           end: CGPoint(x: center.x + r*0.7, y: center.y + r*0.7),
                           options: [])
    ctx.restoreGState()

    // 内瞳
    ctx.setFillColor(CGColor(srgbRed: 0.01, green: 0.012, blue: 0.02, alpha: 1))
    ctx.fillEllipse(in: CGRect(x: center.x - r*0.30, y: center.y - r*0.30,
                               width: r*0.60, height: r*0.60))
    // 瞳上高光点
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.85))
    ctx.fillEllipse(in: CGRect(x: center.x - r*0.18, y: center.y + r*0.02,
                               width: r*0.14, height: r*0.14))
    ctx.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.35))
    ctx.fillEllipse(in: CGRect(x: center.x + r*0.06, y: center.y - r*0.20,
                               width: r*0.07, height: r*0.07))
}

// 品字三摄:上长焦(青紫膜)、左下超广角(琥珀膜)、右下广角(洋红膜)
let bigR: CGFloat = s * 0.230
let smallR: CGFloat = s * 0.130
let cx = s * 0.5
drawLens(center: CGPoint(x: cx, y: s*0.660), radius: bigR, tint: (0.45, 0.75, 1.0))                    // 主摄:青蓝
drawLens(center: CGPoint(x: s*0.290, y: s*0.335), radius: smallR, tint: (1.0, 0.80, 0.35))             // 超广角:琥珀
drawLens(center: CGPoint(x: s*0.735, y: s*0.300), radius: smallR*0.88, tint: (1.0, 0.45, 0.80))        // 长焦:洋红

// ── 取景框四角(相机语言,亮青高光)────────────────
let accent = CGColor(srgbRed: 0.35, green: 0.90, blue: 1.0, alpha: 0.80)
ctx.setStrokeColor(accent)
ctx.setLineWidth(s*0.018)
ctx.setLineCap(.round)
let m = s*0.095           // 边距
let arm = s*0.070         // 臂长
let corners: [(CGPoint, CGPoint, CGPoint)] = [
    // (外角, 臂1终点, 臂2终点) — 左下、右下(底角更近边,视觉重心稳)
    (CGPoint(x: m, y: m), CGPoint(x: m+arm, y: m), CGPoint(x: m, y: m+arm)),
    (CGPoint(x: s-m, y: m), CGPoint(x: s-m-arm, y: m), CGPoint(x: s-m, y: m+arm)),
]
for (c, a1, a2) in corners {
    ctx.move(to: a1); ctx.addLine(to: c); ctx.addLine(to: a2)
    ctx.strokePath()
}
// 底部中央快门条(拍照键意象)
ctx.setFillColor(accent)
let sbW = s*0.16, sbH = s*0.020
let sbRect = CGRect(x: cx - sbW/2, y: s*0.085 - sbH/2, width: sbW, height: sbH)
ctx.addPath(CGPath(roundedRect: sbRect, cornerWidth: sbH/2, cornerHeight: sbH/2, transform: nil))
ctx.fillPath()

// ── 顶部环境高光(玻璃面板感)────────────────
ctx.saveGState()
ctx.addRect(CGRect(x: 0, y: 0, width: s, height: s))
ctx.clip()
let sheenColors = [CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.10),
                   CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 0.0)] as CFArray
let sheen = CGGradient(colorsSpace: cs, colors: sheenColors, locations: [0, 1])!
ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: s*0.35), options: [])
ctx.restoreGState()

// ── 导出 1024 PNG ────────────────────────
let img = ctx.makeImage()!
let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "AppIcon-1024.png"
let url = URL(fileURLWithPath: outPath)
let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil)!
CGImageDestinationAddImage(dest, img, nil)
CGImageDestinationFinalize(dest)
print("OK \(outPath) \(size)x\(size)")
