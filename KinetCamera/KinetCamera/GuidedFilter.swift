import Accelerate
import CoreGraphics

// MARK: - 导向滤波(Edge-Preserving smoothing,美颜磨皮核心)
// 数学:q = a·I + b;a = cov(I,P)/(var(I)+ε);b = meanP - a·meanI(I=guide灰度,P=各彩色通道)
// 实现走积分图 O(1) 盒滤波,小域(≤420px)CPU vDSP,升采样后 GPU 混合 —— 实时美颜 SDK 通行做法。
// 保边原理:同质区 a→0 输出区域均值(抹平),边缘区 var(I) 大 → a→1 输出≈guide(边缘保住)。

enum GuidedFilter {

    struct Result {
        let r: [UInt8], g: [UInt8], b: [UInt8]
        let width: Int, height: Int
    }

    /// 灰度引导的彩色导向滤波。小域输入(把全帧 Lanczos 降到 ~360px 后喂进来)。
    static func apply(rgba: [UInt8], width: Int, height: Int, radius: Int = 8, eps: Float = 0.02) -> Result {
        let n = width * height
        var R = [Float](repeating: 0, count: n)
        var G = [Float](repeating: 0, count: n)
        var B = [Float](repeating: 0, count: n)
        var I = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let r = Float(rgba[i*4]), g = Float(rgba[i*4+1]), b = Float(rgba[i*4+2])
            R[i] = r / 255; G[i] = g / 255; B[i] = b / 255
            I[i] = (r * 0.299 + g * 0.587 + b * 0.114) / 255   // Rec.601 灰度 guide
        }

        // 积分图:II, IR, IG, IB, IIR(=I²), IIP 等展开成 6 张表
        var boxI = boxBlur(I, w: width, h: height, r: radius)
        let boxR = boxBlur(R, w: width, h: height, r: radius)
        let boxG = boxBlur(G, w: width, h: height, r: radius)
        let boxB = boxBlur(B, w: width, h: height, r: radius)

        // 每通道算 a_c 与 b_c:a 共享(用灰度协方差),b 彩色 —— 折中速度与色彩
        var meanII = I
        for i in 0..<n { meanII[i] *= I[i] }
        let boxII = boxBlur(meanII, w: width, h: height, r: radius)

        var A = [Float](repeating: 0, count: n)
        var bR = [Float](repeating: 0, count: n)
        var bG = [Float](repeating: 0, count: n)
        var bB = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let varI = max(boxII[i] - boxI[i] * boxI[i], 0)
            // cov(I, P_c) ≈ varI · corr(I, P_c):用 I 与 P_c 的联合二阶矩
            // 简化:a_c 用 varI 直接缩放 —— guide 自相关时 a=varI/(varI+ε) 平滑系数
            let a = varI / (varI + eps)
            A[i] = a
            bR[i] = boxR[i] - a * boxI[i]
            bG[i] = boxG[i] - a * boxI[i]
            bB[i] = boxB[i] - a * boxI[i]
        }
        let sA = boxBlur(A, w: width, h: height, r: radius)
        let sBR = boxBlur(bR, w: width, h: height, r: radius)
        let sBG = boxBlur(bG, w: width, h: height, r: radius)
        let sBB = boxBlur(bB, w: width, h: height, r: radius)

        var outR = [UInt8](repeating: 0, count: n)
        var outG = [UInt8](repeating: 0, count: n)
        var outB = [UInt8](repeating: 0, count: n)
        for i in 0..<n {
            let gi = I[i]
            outR[i] = UInt8(max(0, min(255, (sA[i] * gi + sBR[i]) * 255)))
            outG[i] = UInt8(max(0, min(255, (sA[i] * gi + sBG[i]) * 255)))
            outB[i] = UInt8(max(0, min(255, (sA[i] * gi + sBB[i]) * 255)))
        }
        _ = boxI
        return Result(r: outR, g: outG, b: outB, width: width, height: height)
    }

    /// 盒滤波(积分图 O(1) 每像素)
    static func boxBlur(_ src: [Float], w: Int, h: Int, r: Int) -> [Float] {
        var integral = [Double](repeating: 0, count: (w + 1) * (h + 1))
        for y in 0..<h {
            var rowSum = 0.0
            for x in 0..<w {
                rowSum += Double(src[y * w + x])
                integral[(y + 1) * (w + 1) + (x + 1)] = integral[y * (w + 1) + (x + 1)] + rowSum
            }
        }
        var out = [Float](repeating: 0, count: w * h)
        for y in 0..<h {
            let y0 = max(y - r, 0), y1 = min(y + r, h - 1)
            for x in 0..<w {
                let x0 = max(x - r, 0), x1 = min(x + r, w - 1)
                let area = Double((x1 - x0 + 1) * (y1 - y0 + 1))
                let s = integral[(y1 + 1) * (w + 1) + (x1 + 1)] - integral[y0 * (w + 1) + (x1 + 1)]
                    - integral[(y1 + 1) * (w + 1) + x0] + integral[y0 * (w + 1) + x0]
                out[y * w + x] = Float(s / area)
            }
        }
        return out
    }

    /// CGImage → RGBA 字节数组(小域)
    static func rgba(of cg: CGImage) -> (bytes: [UInt8], w: Int, h: Int)? {
        let w = cg.width, h = cg.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return nil }
        let p = data.assumingMemoryBound(to: UInt8.self)
        return (Array(UnsafeBufferPointer(start: p, count: w * h * 4)), w, h)
    }

    /// RGBA 字节 → CGImage(小域)
    static func cgImage(r: [UInt8], g: [UInt8], b: [UInt8], w: Int, h: Int) -> CGImage? {
        var rgba = [UInt8](repeating: 255, count: w * h * 4)
        for i in 0..<(w * h) {
            rgba[i*4] = r[i]; rgba[i*4+1] = g[i]; rgba[i*4+2] = b[i]
        }
        return rgba.map { $0 }.withContiguousStorageIfAvailable { buf in
            CGContext(data: UnsafeMutableRawPointer(mutating: buf.baseAddress), width: w, height: h,
                      bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        } ?? nil
    }
}
