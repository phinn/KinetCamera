import Foundation

@main
struct GFTest {
    static func main() {
        let W = 100, H = 100
        var rgba = [UInt8](repeating: 0, count: W*H*4)
        for y in 0..<H { for x in 0..<W {
            let i = (y*W+x)*4
            if x < 30 { rgba[i]=40; rgba[i+1]=60; rgba[i+2]=160 }   // 蓝块
            else { rgba[i]=200; rgba[i+1]=150; rgba[i+2]=120 }      // 肤色
            rgba[i+3]=255
        }}
        let g = GuidedFilter.apply(rgba: rgba, width: W, height: H, radius: 8, eps: 0.0225)
        func px(_ x: Int, _ y: Int) -> (Int,Int,Int) { (Int(g.r[y*W+x]), Int(g.g[y*W+x]), Int(g.b[y*W+x])) }
        print("蓝块中心(10,50):", px(10,50), "期望(40,60,160)")
        print("肤色中心(60,50):", px(60,50), "期望(200,150,120)")
        print("边界(28,50):", px(28,50), "(边界泄漏带)")
        print("边界(35,50):", px(35,50))
    }
}
