import Foundation
import AppKit
import CoreGraphics

@main
struct GFTest2 {
    static func main() {
        let img = NSImage(contentsOfFile: "/tmp/skin_card.png")!
        var rect = CGRect(x: 0, y: 0, width: 60, height: 60)
        let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        guard let (bytes, w, h) = GuidedFilter.rgba(of: cg) else { print("read fail"); return }
        print("小域尺寸:", w, h)
        // 蓝块原 40:160 x 40:240 (全尺寸720p) → 小域 x * (360/1280) = 11..67, y * (360/720)=20..80
        let scale = Double(w) / 1280.0
        let bx = Int(140 * scale), by = Int(100 * scale)   // 蓝块中心
        func orig(_ x: Int, _ y: Int) -> (Int,Int,Int) { let i=(y*w+x)*4; return (Int(bytes[i]), Int(bytes[i+1]), Int(bytes[i+2])) }
        let g = GuidedFilter.apply(rgba: bytes, width: w, height: h, radius: 11, eps: 0.0225)
        func out(_ x: Int, _ y: Int) -> (Int,Int,Int) { (Int(g.r[y*w+x]), Int(g.g[y*w+x]), Int(g.b[y*w+x])) }
        print("蓝块中心 orig:", orig(bx,by), "→ GF:", out(bx,by))
        print("蓝块另一点 orig:", orig(bx+10,by+10), "→ GF:", out(bx+10,by+10))
    }
}
