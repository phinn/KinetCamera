import CoreImage
import Vision
import AppKit

@main
struct FaceQuant {
    static func main() {
        for path in Array(CommandLine.arguments.dropFirst()) {
            guard let img = CIImage(contentsOf: URL(fileURLWithPath: path)) else {
                print("\(path): LOAD_FAIL"); continue
            }
            let req = VNDetectFaceRectanglesRequest()
            let handler = VNImageRequestHandler(ciImage: img)
            try? handler.perform([req])
            guard let face = req.results?.first else {
                print("\(path): NO_FACE"); continue
            }
            let obs = face.boundingBox
            // VN 坐标(左下原点,归一化)→ 像素
            let e = img.extent
            let fx = Int(obs.origin.x * e.width)
            let fw = Int(obs.width * e.width)
            let fy = Int((1 - obs.origin.y - obs.height) * e.height)
            let fh = Int(obs.height * e.height)
            print("\(path): face=(\(fx),\(fy),\(fw)x\(fh)) conf=\(face.confidence)")
            // 脸框内肤域统计
            let ctx = CIContext()
            guard let cg = ctx.createCGImage(img, from: e) else { continue }
            let w = cg.width, h = cg.height
            var buf = [UInt8](repeating: 0, count: w*h*4)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ctx2 = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4,
                                 space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            ctx2.draw(cg, in: CGRect(x: 0, y: 0, width: w, height: h))
            var n=0; var hf=0.0; var rb=0.0
            // 脸框外扩30%(脸颊/下颌)
            let x0=max(1,fx-fw*3/10), x1=min(w-2,fx+fw+fw*3/10)
            let y0=max(1,fy-fh*3/10), y1=min(h-2,fy+fh+fh*3/10)
            for y in stride(from: Int(y0), to: Int(y1), by: 2) {
                for x in stride(from: Int(x0), to: Int(x1), by: 2) {
                    let i=(y*w+x)*4
                    let r=Int(buf[i]), g=Int(buf[i+1]), b=Int(buf[i+2])
                    if r>80 && r>g+10 && g>b+3 {
                        n+=1; rb += Double(r-b)
                        let il=((y*w+x-1)*4)
                        hf += abs(Double(r)-Double(buf[il])) + abs(Double(g)-Double(buf[((y-1)*w+x)*4+1]))
                    }
                }
            }
            if n>0 { print("  skin n=\(n) hf=\(hf/Double(n)) R-B=\(rb/Double(n))") }
            else { print("  skin n=0 (框内无肤色像素)") }
        }
    }
}
