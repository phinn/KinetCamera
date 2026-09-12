import SwiftUI

/// Canvas 弯管示意图:把 mark 距离标在管线走向上
struct BendDiagram: View {
    enum Kind { case stubUp, offset, saddle3, saddle4, kick }
    let kind: Kind
    /// 沿管方向的关键标记(英寸),按比例落位
    let marks: [Double]

    var body: some View {
        Canvas { context, size in
            let w = size.width
            let h = size.height
            let conduit = BendTheme.accent
            let ink = BendTheme.text
            let dim = BendTheme.dim

            func line(_ p1: CGPoint, _ p2: CGPoint, _ color: Color, width: CGFloat = 5) {
                var p = Path()
                p.move(to: p1)
                p.addLine(to: p2)
                context.stroke(p, with: .color(color), style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
            }

            switch kind {
            case .stubUp:
                // 水平进线 → 90° 上弯 → 竖直
                let baseY = h * 0.72
                let bendX = w * 0.42
                let topY = h * 0.18
                line(CGPoint(x: 24, y: baseY), CGPoint(x: bendX, y: baseY), conduit)
                line(CGPoint(x: bendX, y: baseY), CGPoint(x: bendX, y: topY), conduit)
                // mark 圆点
                for (i, x) in [w * 0.18, bendX].enumerated() {
                    let c = CGRect(x: x - 5, y: baseY - 5, width: 10, height: 10)
                    context.fill(Path(ellipseIn: c), with: .color(i == 0 ? BendTheme.accent2 : ink))
                }
                context.draw(Text("M1").font(.caption2.bold()), at: CGPoint(x: w * 0.18, y: baseY + 16))
                context.draw(Text("M2").font(.caption2.bold()), at: CGPoint(x: bendX + 4, y: baseY + 16))

            case .offset:
                // 之字:进线 → 斜上 → 平行
                let y1 = h * 0.70, y2 = h * 0.30
                let x0 = 24.0, x1 = w * 0.38, x2 = w * 0.62
                line(CGPoint(x: x0, y: y1), CGPoint(x: x1, y: y1), conduit)
                line(CGPoint(x: x1, y: y1), CGPoint(x: x2, y: y2), conduit)
                line(CGPoint(x: x2, y: y2), CGPoint(x: w - 24, y: y2), conduit)
                for x in [x1, x2] {
                    let c = CGRect(x: x - 5, y: (x == x1 ? y1 : y2) - 5, width: 10, height: 10)
                    context.fill(Path(ellipseIn: c), with: .color(BendTheme.accent2))
                }
                context.draw(Text("M1").font(.caption2.bold()), at: CGPoint(x: x1, y: y1 + 16))
                context.draw(Text("M2").font(.caption2.bold()), at: CGPoint(x: x2, y: y2 - 14))

            case .saddle3, .saddle4:
                // ∩ 形:进线 → 上折 → (平台) → 下折 → 出线
                let baseY = h * 0.72
                let topY = h * 0.22
                let xs: [CGFloat] = [w * 0.20, w * 0.40, w * 0.60, w * 0.80]
                line(CGPoint(x: 24, y: baseY), CGPoint(x: xs[0], y: baseY), conduit)
                line(CGPoint(x: xs[0], y: baseY), CGPoint(x: xs[1], y: topY), conduit)
                if case .saddle4 = kind {
                    line(CGPoint(x: xs[1], y: topY), CGPoint(x: xs[2], y: topY), conduit)
                } else {
                    line(CGPoint(x: xs[1], y: topY), CGPoint(x: xs[2], y: baseY), conduit)
                }
                line(CGPoint(x: xs[2], y: baseY), CGPoint(x: xs[3], y: baseY), conduit)
                for (i, pt) in [(xs[0], baseY), (xs[1], topY), (xs[2], baseY), (xs[3], baseY)].enumerated() {
                    let c = CGRect(x: pt.0 - 5, y: pt.1 - 5, width: 10, height: 10)
                    context.fill(Path(ellipseIn: c), with: .color(i % 2 == 0 ? BendTheme.accent2 : ink))
                }
                context.draw(Text("22.5°").font(.caption2), at: CGPoint(x: xs[0], y: baseY + 14))
                context.draw(Text("45°").font(.caption2), at: CGPoint(x: xs[1], y: topY - 12))
                context.draw(Text("22.5°").font(.caption2), at: CGPoint(x: xs[2], y: baseY + 14))

            case .kick:
                // 斜踢:墙点 → 斜线
                let x0 = w * 0.30, y0 = h * 0.72
                let x1 = w * 0.75, y1 = h * 0.25
                line(CGPoint(x: x0 - 60, y: y0), CGPoint(x: x0, y: y0), dim, width: 3)
                line(CGPoint(x: x0, y: y0), CGPoint(x: x1, y: y1), conduit)
                // 地面参考
                line(CGPoint(x: x0, y: y0 + 10), CGPoint(x: x1 + 20, y: y0 + 10), dim.opacity(0.4), width: 2)
                let c = CGRect(x: x0 - 5, y: y0 - 5, width: 10, height: 10)
                context.fill(Path(ellipseIn: c), with: .color(BendTheme.accent2))
                context.draw(Text("M").font(.caption2.bold()), at: CGPoint(x: x0, y: y0 + 22))
            }
        }
        .background(BendTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
    }
}
