import AppKit
// 左右拼两张 PNG:make_ab_sidebyside <left> <right> <out> [top_label]
let a = CommandLine.arguments
guard a.count >= 4 else { print("usage: <left> <right> <out>"); exit(1) }
func load(_ p: String) -> CGImage {
    let img = NSImage(contentsOfFile: p)!
    var r = CGRect(x: 0, y: 0, width: Int(img.size.width), height: Int(img.size.height))
    return img.cgImage(forProposedRect: &r, context: nil, hints: nil)!
}
let l = load(a[1]), r = load(a[2])
let w = l.width + r.width + 8   // 中缝8px
let h = max(l.height, r.height)
let cs = CGColorSpaceCreateDeviceRGB()
let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
ctx.draw(l, in: CGRect(x: 0, y: 0, width: l.width, height: l.height))
ctx.draw(r, in: CGRect(x: l.width + 8, y: 0, width: r.width, height: r.height))
let out = ctx.makeImage()!
let rep = NSBitmapImageRep(cgImage: out)
try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: a[3]))
print("saved \(a[3]) \(w)x\(h)")
