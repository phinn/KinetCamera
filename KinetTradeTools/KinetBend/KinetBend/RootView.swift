import SwiftUI
import KitCore

/// 主题:工地暗色 + 高对比,戴手套/强光可读
enum BendTheme {
    static let bg = Color(red: 0.07, green: 0.075, blue: 0.09)
    static let card = Color(red: 0.13, green: 0.14, blue: 0.17)
    static let accent = Color(red: 1.0, green: 0.62, blue: 0.10)   // 安全橙
    static let accent2 = Color(red: 0.95, green: 0.80, blue: 0.20) // 警示黄
    static let text = Color(red: 0.95, green: 0.95, blue: 0.96)
    static let dim = Color(red: 0.60, green: 0.62, blue: 0.66)
}

enum BendMode: String, CaseIterable, Identifiable {
    case stubUp, offset, saddle3, saddle4, kick
    var id: String { rawValue }

    var title: String {
        switch self {
        case .stubUp: return String(localized: "mode.stubup")
        case .offset: return String(localized: "mode.offset")
        case .saddle3: return String(localized: "mode.saddle3")
        case .saddle4: return String(localized: "mode.saddle4")
        case .kick: return String(localized: "mode.kick")
        }
    }

    var symbol: String {
        switch self {
        case .stubUp: return "arrow.up.right"
        case .offset: return "arrow.zigzag.right"
        case .saddle3: return "circle.trianglebadge.inset.filled"
        case .saddle4: return "rectangle.on.rectangle"
        case .kick: return "arrow.turn.up.right"
        }
    }
}

/// 全局会话状态:管材选择 + 单位制
@MainActor
final class BendSession: ObservableObject {
    @Published var conduitType: String = "EMT"
    @Published var conduitID: String = "emt-3/4"
    @Published var unit: LengthUnit = .inchFraction

    let db = ConduitCatalog.load()
    var types: [String] { ["EMT", "RMC", "IMC"] }

    var specs: [ConduitSpec] { ConduitCatalog.specs(type: conduitType, database: db) }

    var currentSpec: ConduitSpec {
        specs.first { $0.id == conduitID } ?? specs.first!
    }

    func selectType(_ t: String) {
        conduitType = t
        if specs.first(where: { $0.id == conduitID }) == nil {
            conduitID = specs.first?.id ?? conduitID
        }
    }
}

struct RootView: View {
    @State private var mode: BendMode = .stubUp
    @StateObject private var session = BendSession()

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // 顶部:管材选择条(所有模式共用)
                ConduitBar(session: session)
                    .padding(.horizontal)
                    .padding(.top, 8)

                // 模式切换
                Picker("", selection: $mode) {
                    ForEach(BendMode.allCases) { m in
                        Label(m.title, systemImage: m.symbol).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .padding()

                // 计算器区
                ScrollView {
                    switch mode {
                    case .stubUp: StubUpView(session: session)
                    case .offset: OffsetView(session: session)
                    case .saddle3: Saddle3View()
                    case .saddle4: Saddle4View()
                    case .kick: KickView()
                    }
                }
            }
            .background(BendTheme.bg.ignoresSafeArea())
            .navigationTitle("KinetBend")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    UnitMenu(session: session)
                }
            }
        }
    }
}

// MARK: - 管材选择条

struct ConduitBar: View {
    @ObservedObject var session: BendSession

    var body: some View {
        HStack(spacing: 8) {
            ForEach(session.types, id: \.self) { t in
                Button {
                    withAnimation(.easeInOut(duration: 0.15)) { session.selectType(t) }
                } label: {
                    Text(t)
                        .font(.subheadline.bold())
                        .padding(.vertical, 8)
                        .frame(maxWidth: .infinity)
                        .background(session.conduitType == t ? BendTheme.accent : BendTheme.card)
                        .foregroundStyle(session.conduitType == t ? .black : BendTheme.text)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}

struct UnitMenu: View {
    @ObservedObject var session: BendSession

    var body: some View {
        Menu {
            ForEach(LengthUnit.allCases) { u in
                Button {
                    session.unit = u
                } label: {
                    if session.unit == u {
                        Label(u.label, systemImage: "checkmark")
                    } else {
                        Text(u.label)
                    }
                }
            }
        } label: {
            Text(session.unit.label)
                .font(.subheadline.bold().monospacedDigit())
        }
    }
}

// MARK: - 共享 UI 组件

struct NumberField: View {
    let label: String
    @Binding var value: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(BendTheme.dim)
            TextField("0", value: $value, format: .number)
                .keyboardType(.decimalPad)
                .font(.title2.bold().monospacedDigit())
                .padding(12)
                .background(BendTheme.card)
                .foregroundStyle(BendTheme.text)
                .clipShape(RoundedRectangle(cornerRadius: 12))
        }
    }
}

struct ResultRow: View {
    let label: String
    let value: String
    var highlight = false

    var body: some View {
        HStack {
            Text(label)
                .font(.subheadline)
                .foregroundStyle(highlight ? BendTheme.accent2 : BendTheme.dim)
            Spacer()
            Text(value)
                .font(highlight ? .title3.bold() : .title3.monospacedDigit())
                .foregroundStyle(highlight ? BendTheme.accent2 : BendTheme.text)
        }
        .padding(.vertical, 6)
    }
}

struct ResultCard<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(BendTheme.card)
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .padding(.horizontal)
    }
}

// MARK: - 90° Stub-Up

struct StubUpView: View {
    @ObservedObject var session: BendSession
    @State private var height: Double = 12

    var result: StubUpResult {
        BendMath.stubUp(height: height, spec: session.currentSpec)
    }

    var body: some View {
        VStack(spacing: 16) {
            NumberField(label: String(localized: "field.height"), value: $height)
                .padding(.horizontal)

            ResultCard {
                ResultRow(label: String(localized: "result.takeup"), value: result.takeUp.display(unit: session.unit))
                ResultRow(label: String(localized: "result.mark1"), value: result.mark1.display(unit: session.unit), highlight: true)
                ResultRow(label: String(localized: "result.mark2"), value: result.mark2.display(unit: session.unit))
            }

            BendDiagram(kind: .stubUp, marks: [result.mark1.decimalInches, result.mark2.decimalInches])
                .frame(height: 170)
                .padding(.horizontal)

            Text(String(localized: "hint.stubup"))
                .font(.footnote)
                .foregroundStyle(BendTheme.dim)
                .padding(.horizontal)
        }
    }
}

// MARK: - Offset

struct OffsetView: View {
    @ObservedObject var session: BendSession
    @State private var height: Double = 6
    @State private var angle: Double = 30

    var result: BendMath.OffsetResult {
        BendMath.offset(height: height, angleDegrees: angle, spec: session.currentSpec)
    }

    var body: some View {
        VStack(spacing: 16) {
            NumberField(label: String(localized: "field.offsetheight"), value: $height)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "field.angle"))
                    .font(.caption)
                    .foregroundStyle(BendTheme.dim)
                HStack {
                    Slider(value: $angle, in: 10...60, step: 2.5)
                        .tint(BendTheme.accent)
                    Text("\(angle, specifier: "%.1f")°")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(BendTheme.accent2)
                        .frame(width: 72, alignment: .trailing)
                }
                // 常用角快捷
                HStack(spacing: 8) {
                    ForEach([10.0, 22.5, 30.0, 45.0, 60.0], id: \.self) { a in
                        Button {
                            withAnimation(.easeInOut(duration: 0.12)) { angle = a }
                        } label: {
                            Text(a.truncatingRemainder(dividingBy: 1) == 0 ? "\(Int(a))°" : "\(a, specifier: "%.1f")°")
                                .font(.footnote.bold())
                                .padding(.vertical, 6)
                                .frame(maxWidth: .infinity)
                                .background(angle == a ? BendTheme.accent : BendTheme.card)
                                .foregroundStyle(angle == a ? .black : BendTheme.text)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
            .padding(.horizontal)

            ResultCard {
                ResultRow(label: String(localized: "result.multiplier"), value: String(format: "%.3f", result.multiplier))
                ResultRow(label: String(localized: "result.markspacing"), value: result.markSpacing.display(unit: session.unit), highlight: true)
                ResultRow(label: String(localized: "result.shrink"), value: result.shrink.display(unit: session.unit))
            }

            BendDiagram(kind: .offset, marks: [result.markSpacing.decimalInches])
                .frame(height: 150)
                .padding(.horizontal)
        }
    }
}

// MARK: - 3-Point Saddle

struct Saddle3View: View {
    @ObservedObject private var session = BendSession()
    @State private var width: Double = 4
    @State private var height: Double = 2

    var result: BendMath.SaddleResult {
        BendMath.saddle(obstacleWidth: width, obstacleHeight: height)
    }

    var body: some View {
        VStack(spacing: 16) {
            NumberField(label: String(localized: "field.obstaclewidth"), value: $width)
                .padding(.horizontal)
            NumberField(label: String(localized: "field.obstacleheight"), value: $height)
                .padding(.horizontal)

            ResultCard {
                ResultRow(label: String(localized: "result.centermark"), value: result.centerMarkOffset.display(unit: session.unit), highlight: true)
                ResultRow(label: String(localized: "result.sidemark"), value: result.sideMarkSpacing.display(unit: session.unit), highlight: true)
                ResultRow(label: String(localized: "result.angles"), value: "22.5°–45°–22.5°")
            }

            BendDiagram(kind: .saddle3, marks: [result.centerMarkOffset.decimalInches, result.sideMarkSpacing.decimalInches])
                .frame(height: 150)
                .padding(.horizontal)
        }
    }
}

// MARK: - 4-Point Saddle

struct Saddle4View: View {
    @ObservedObject private var session = BendSession()
    @State private var width: Double = 6
    @State private var height: Double = 3

    var result: BendMath.FourPointSaddleResult {
        BendMath.fourPointSaddle(obstacleWidth: width, obstacleHeight: height)
    }

    var body: some View {
        VStack(spacing: 16) {
            NumberField(label: String(localized: "field.obstaclewidth"), value: $width)
                .padding(.horizontal)
            NumberField(label: String(localized: "field.obstacleheight"), value: $height)
                .padding(.horizontal)

            ResultCard {
                ResultRow(label: String(localized: "result.risespacing"), value: result.riseSpacing.display(unit: session.unit), highlight: true)
                ResultRow(label: String(localized: "result.sidemark"), value: result.markSpacing.display(unit: session.unit), highlight: true)
                ResultRow(label: String(localized: "result.angles"), value: "22.5°–45°–45°–22.5°")
            }

            BendDiagram(kind: .saddle4, marks: [result.riseSpacing.decimalInches, result.markSpacing.decimalInches])
                .frame(height: 150)
                .padding(.horizontal)
        }
    }
}

// MARK: - Kick

struct KickView: View {
    @ObservedObject private var session = BendSession()
    @State private var height: Double = 4
    @State private var angle: Double = 45

    var result: BendMath.KickResult {
        BendMath.kick(height: height, angleDegrees: angle)
    }

    var body: some View {
        VStack(spacing: 16) {
            NumberField(label: String(localized: "field.kickheight"), value: $height)
                .padding(.horizontal)

            VStack(alignment: .leading, spacing: 6) {
                Text(String(localized: "field.angle"))
                    .font(.caption)
                    .foregroundStyle(BendTheme.dim)
                HStack {
                    Slider(value: $angle, in: 10...60, step: 2.5)
                        .tint(BendTheme.accent)
                    Text("\(angle, specifier: "%.1f")°")
                        .font(.title3.bold().monospacedDigit())
                        .foregroundStyle(BendTheme.accent2)
                        .frame(width: 72, alignment: .trailing)
                }
            }
            .padding(.horizontal)

            ResultCard {
                ResultRow(label: String(localized: "result.markdistance"), value: result.markDistance.display(unit: session.unit), highlight: true)
            }

            BendDiagram(kind: .kick, marks: [result.markDistance.decimalInches])
                .frame(height: 150)
                .padding(.horizontal)
        }
    }
}
