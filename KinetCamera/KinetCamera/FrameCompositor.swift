import CoreImage
import CoreGraphics
import Foundation

/// 多帧合成公共栈:夜景 / 防抖 / HDR 三入口共用
/// - motionCompensatedAverage:灰度 SAD 块匹配对齐 + 时域平均(夜景增益版/防抖原亮度版)
/// - hdrToneMap:堆栈降噪 + 阴影 γ 恢复 + 高光软肩
/// 全部 UInt32 整型累加,无浮点噪声引入;逐帧残差如实写进 applied 报告
enum FrameCompositor {

    struct CompositeResult {
        let image: CGImage?
        let kept: Int          // 参与合成的帧数
        let dropped: Int       // 运动超窗弃用帧数
        let residual: Double   // 对齐后帧间平均残差 0-1(越低越稳)
        let naiveResidual: Double // 零对齐(直接叠)残差,与 residual 的比值=对齐收益
        let offsets: [(dx: Int, dy: Int)]
        let naiveImage: CGImage?  // 未对齐直接平均的诊断图(防抖 A/B 用,不入相册)
    }

    /// 运动补偿时域平均
    /// - maxShift: 对齐搜索半径(px)。夜景2px/防抖3px;超窗帧弃用防鬼影
    /// - gain: 平均后增益(夜景1.9回拉亮度;防抖1.0保持原亮度)
    /// 同时产出 naive(未对齐直接平均)图与残差,供防抖效果量化
    static func motionCompensatedAverage(_ cgs: [CGImage], gain: Float, maxShift: Int = 2) -> CompositeResult {
        let empty = CompositeResult(image: nil, kept: 0, dropped: 0, residual: 1, naiveResidual: 1, offsets: [], naiveImage: nil)
        guard let first = cgs.first else {
            return empty
        }
        let w = first.width, h = first.height

        // CGImage → 灰度字节数组(对齐/残差都算在灰度域)
        func grayBytes(_ cg: CGImage) -> [UInt8]? {
            guard let ctx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return nil }
            ctx.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = ctx.data else { return nil }
            return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h))
        }
        let grays = cgs.compactMap { grayBytes($0) }
        guard grays.count == cgs.count else {
            return empty
        }

        // 参考帧 = 首帧;每帧在 ±maxShift 内搜 SAD 最小平移
        let refGray = grays[0]
        func sadAt(_ g: [UInt8], dx: Int, dy: Int) -> Int {
            var sum = 0
            var y = 2
            while y < h - 2 {
                var x = 2
                while x < w - 2 {
                    let ry = y + dy, rx = x + dx
                    if ry >= 0, ry < h, rx >= 0, rx < w {
                        sum += abs(Int(g[y * w + x]) - Int(refGray[ry * w + rx]))
                    }
                    x += 4
                }
                y += 4
            }
            return sum
        }

        var offsets: [(dx: Int, dy: Int)] = []
        var droppedMotion = 0
        var residualSum = 0
        var residualSamples = 0
        for g in grays {
            var best = (dx: 0, dy: 0, sad: sadAt(g, dx: 0, dy: 0))
            for dy in -maxShift...maxShift {
                for dx in -maxShift...maxShift where dx != 0 || dy != 0 {
                    let s = sadAt(g, dx: dx, dy: dy)
                    if s < best.sad { best = (dx, dy, s) }
                }
            }
            let shift = max(abs(best.dx), abs(best.dy))
            // 平移打满搜索窗 → 运动过猛,弃帧防鬼影
            if shift >= maxShift { droppedMotion += 1; continue }
            offsets.append((best.dx, best.dy))
            residualSum += best.sad
            let samples = ((h - 4) / 4) * ((w - 4) / 4)
            residualSamples += samples
        }
        let kept = offsets.count
        let residual = residualSamples > 0 ? Double(residualSum) / Double(residualSamples) / 255.0 : 1.0
        // naive 残差:不做对齐直接叠的帧间差(衡量实际运动量,防抖收益的分母)
        var naiveSum = 0
        for g in grays.dropFirst() {
            naiveSum += sadAt(g, dx: 0, dy: 0)
        }
        let naiveResidual = grays.count > 1
            ? Double(naiveSum) / (Double(grays.count - 1) * Double(residualSamples / max(grays.count, 1))) / 255.0
            : 1.0
        guard kept >= 4 else {
            return CompositeResult(image: nil, kept: kept, dropped: droppedMotion, residual: residual,
                                   naiveResidual: naiveResidual, offsets: offsets, naiveImage: nil)
        }

        // 按估计平移对齐后整型累加 + 未对齐直接累加(诊断图)
        let outCtx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        guard let outCtx else {
            return CompositeResult(image: nil, kept: kept, dropped: droppedMotion, residual: residual,
                                   naiveResidual: naiveResidual, offsets: offsets, naiveImage: nil)
        }

        var acc = [UInt32](repeating: 0, count: w * h * 4)
        var naiveAcc = [UInt32](repeating: 0, count: w * h * 4)
        for (idx, cg) in cgs.enumerated() {
            outCtx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            outCtx.setFillColor(CGColor(gray: 0, alpha: 1))
            outCtx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            let off = idx < offsets.count ? offsets[idx] : (dx: 0, dy: 0)
            // 行空间位移(y向下) → CG 空间(y向上):dy 必须取反,否则垂直方向反向错位
            outCtx.draw(cg, in: CGRect(x: CGFloat(off.dx), y: CGFloat(-off.dy), width: CGFloat(w), height: CGFloat(h)))
            guard let data = outCtx.data else { continue }
            let p = data.assumingMemoryBound(to: UInt8.self)
            for i in 0..<(w * h * 4) { acc[i] &+= UInt32(p[i]) }

            // naive 路径:同一帧,平移强制清零(未补偿直接叠)
            outCtx.clear(CGRect(x: 0, y: 0, width: w, height: h))
            outCtx.fill(CGRect(x: 0, y: 0, width: w, height: h))
            outCtx.draw(cg, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))
            guard let nd = outCtx.data else { continue }
            let np = nd.assumingMemoryBound(to: UInt8.self)
            for i in 0..<(w * h * 4) { naiveAcc[i] &+= UInt32(np[i]) }
        }

        // 平均 + 增益(对齐版 / naive 版同参数)
        var outBytes = [UInt8](repeating: 0, count: w * h * 4)
        var naiveBytes = [UInt8](repeating: 0, count: w * h * 4)
        let denom = Float(kept)
        let nDenom = Float(cgs.count)
        for i in 0..<(w * h * 4) {
            let avg = Float(acc[i]) / denom
            outBytes[i] = UInt8(max(0, min(255, Int(avg * gain))))
            let nAvg = Float(naiveAcc[i]) / nDenom
            naiveBytes[i] = UInt8(max(0, min(255, Int(nAvg * gain))))
        }
        func toCG(_ bytes: [UInt8]) -> CGImage? {
            bytes.withUnsafeBytes { ptr -> CGImage? in
                guard let c = CGContext(
                    data: UnsafeMutableRawPointer(mutating: ptr.baseAddress),
                    width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
                return c.makeImage()
            }
        }
        return CompositeResult(
            image: toCG(outBytes), kept: kept, dropped: droppedMotion,
            residual: residual, naiveResidual: naiveResidual,
            offsets: offsets, naiveImage: toCG(naiveBytes))
    }

    /// HDR:多帧堆栈降噪(压噪声底) + 阴影 γ 恢复 + 高光软肩
    /// 诚实边界:单帧 8bit 已剪裁的信息救不回,不宣称扩真实动态范围;
    /// 提阴影后的噪声由堆栈平均压掉(噪声∝1/√帧数)
    static func hdrToneMap(_ cgs: [CGImage]) -> (image: CGImage?, stats: String) {
        let comp = motionCompensatedAverage(cgs, gain: 1.6, maxShift: 2)
        guard let base = comp.image else {
            return (nil, "HDR失败:kept=\(comp.kept) 弃=\(comp.dropped)")
        }
        // 阴影恢复 γ:暗部抬升;高光软肩:接近255处软压缩防死白;1D LUT 查表免逐像素 pow
        let gamma = Float(1.0) / (1.0 + 0.5 * 1.2)   // shadows=0.5
        let shoulderStart: Float = 0.82
        var lut = [UInt8](repeating: 0, count: 256)
        for v in 0...255 {
            let x = Float(v) / 255.0
            var y = powf(x, gamma)
            if y > shoulderStart {
                let t = (y - shoulderStart) / (1.0 - shoulderStart)
                let s = 0.10 * shoulderStart
                y = shoulderStart + s + (1.0 - shoulderStart - s) * (t * t * (3.0 - 2.0 * t) * 0.35 + t * 0.65)
            }
            lut[v] = UInt8(max(0, min(255, Int(y * 255.0))))
        }
        // 查表重映射
        let w = base.width, h = base.height
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return (nil, "HDR失败:解码") }
        ctx.draw(base, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let data = ctx.data else { return (nil, "HDR失败:解码") }
        let p0 = data.assumingMemoryBound(to: UInt8.self)
        var outBytes = [UInt8](repeating: 0, count: w * h * 4)
        var i = 0
        for _ in 0..<(w * h) {
            outBytes[i] = lut[Int(p0[i])]; outBytes[i + 1] = lut[Int(p0[i + 1])]
            outBytes[i + 2] = lut[Int(p0[i + 2])]; outBytes[i + 3] = p0[i + 3]
            i += 4
        }
        let image = outBytes.withUnsafeBytes { ptr -> CGImage? in
            guard let c = CGContext(
                data: UnsafeMutableRawPointer(mutating: ptr.baseAddress),
                width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
            return c.makeImage()
        }
        let stats = "对齐残差\(String(format: "%.3f", comp.residual))/naive\(String(format: "%.3f", comp.naiveResidual)), kept\(comp.kept) 弃\(comp.dropped)"
        return (image, stats)
    }
}
