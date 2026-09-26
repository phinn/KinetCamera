import CoreImage
import AppKit

@main
struct GFTest3 {
    static func main() {
        let img = NSImage(contentsOfFile: "/tmp/skin_card.png")!
        var rect = CGRect(x: 0, y: 0, width: 60, height: 60)
        let cg = img.cgImage(forProposedRect: &rect, context: nil, hints: nil)!
        let input = CIImage(cgImage: cg)
        print("input extent:", input.extent)
        let scale = min(1.0, 360.0 / CGFloat(max(input.extent.width, input.extent.height)))
        print("scale:", scale)
        let scaled = input.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: scale])
        print("scaled extent:", scaled.extent)
    }
}
