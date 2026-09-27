import SwiftUI
import MetalKit
import AVFoundation

@main
struct KinetCameraApp: App {
    var body: some Scene {
        WindowGroup {
            #if os(macOS)
            ContentView()
                .frame(minWidth: 960, minHeight: 640)
            #else
            ContentView()
            #endif
        }
        #if os(macOS)
        .windowStyle(.automatic)
        .commands {
            CommandGroup(after: .newItem) {
                Button("拍照") { NotificationCenter.default.post(name: .kinetCapturePhoto, object: nil) }
                    .keyboardShortcut("3", modifiers: .command)
                Button("录制/停止") { NotificationCenter.default.post(name: .kinetToggleRecord, object: nil) }
                    .keyboardShortcut("4", modifiers: .command)
                Button("夜景模式") { NotificationCenter.default.post(name: .kinetCaptureNight, object: nil) }
                    .keyboardShortcut("5", modifiers: .command)
                Button("连拍×10") { NotificationCenter.default.post(name: .kinetCaptureBurst, object: nil) }
                    .keyboardShortcut("6", modifiers: .command)
                Button("曝光锁定") { NotificationCenter.default.post(name: .kinetToggleAELock, object: nil) }
                    .keyboardShortcut("l", modifiers: .command)
                Button("回溯快门") { NotificationCenter.default.post(name: .kinetCaptureRetro, object: nil) }
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        #endif
    }
}

extension Notification.Name {
    static let kinetCapturePhoto = Notification.Name("kinetCapturePhoto")
    static let kinetToggleRecord = Notification.Name("kinetToggleRecord")
    static let kinetCaptureNight = Notification.Name("kinetCaptureNight")
    static let kinetCaptureSteady = Notification.Name("kinetCaptureSteady")
    static let kinetCaptureHDR = Notification.Name("kinetCaptureHDR")
    static let kinetCaptureRetro = Notification.Name("kinetCaptureRetro")
    static let kinetCaptureBurst = Notification.Name("kinetCaptureBurst")
    static let kinetToggleAELock = Notification.Name("kinetToggleAELock")
}

// MARK: - 主界面
struct ContentView: View {
    @StateObject private var vm = CameraViewModel()

    var body: some View {
        HStack(spacing: 0) {
            // 主预览区
            ZStack {
                PreviewView(vm: vm)
                VStack {
                    Spacer()
                    if vm.showGrid { GridOverlay().allowsHitTesting(false) }
                }
                VStack {
                    Spacer()
                    HUDView(vm: vm)
                }

                // 画中画小窗(右上角)
                VStack {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            ForEach(vm.manager.pipDeviceIDs, id: \.self) { id in
                                PIPPreviewView(image: vm.pipFrames[id])
                                    .frame(width: 168, height: 94)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .stroke(Color.white.opacity(0.35), lineWidth: 1)
                                    )
                                Text(vm.manager.devices.first { $0.uniqueID == id }?.localizedName ?? "画中画")
                                    .font(.caption2)
                                    .foregroundColor(.white.opacity(0.8))
                                    .padding(-4)
                            }
                        }
                        .padding(.trailing, 14)
                        .padding(.top, 14)
                    }
                    Spacer()
                }
            }
            .layoutPriority(1)

            // 右侧面板
            SidePanelView(vm: vm)
                .frame(width: 300)
        }
        .background(Color.black)
        .preferredColorScheme(.dark)
        .onAppear {
            AutomationServer.shared.start(vm: vm)
        }
        .onReceive(NotificationCenter.default.publisher(for: .kinetCapturePhoto)) { _ in
            vm.capturePhoto()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kinetToggleRecord)) { _ in
            vm.manager.isRecording ? vm.stopRecording() : vm.startRecording()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kinetCaptureNight)) { _ in
            vm.captureNight()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kinetCaptureSteady)) { _ in
            vm.captureSteady()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kinetCaptureHDR)) { _ in
            vm.captureHDR()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kinetCaptureBurst)) { _ in
            vm.captureBurst()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kinetCaptureRetro)) { _ in
            vm.captureRetro()
        }
        .onReceive(NotificationCenter.default.publisher(for: .kinetToggleAELock)) { _ in
            vm.manager.toggleAELock()
        }
        .onOpenURL { url in
            // kinetcamera:// 真机验收控制面:devicectl process openURL 即可驱动,
            // 不依赖端口转发(USB 无 iproxy 时唯一的远程控制通道)
            Self.handleDeepLink(url, vm: vm)
        }
    }

    /// 深链路由:kinetcamera://action?param=value,动作与 /action HTTP 路由同语义
    static func handleDeepLink(_ url: URL, vm: CameraViewModel) {
        let host = url.host ?? url.pathComponents.dropFirst().first ?? ""
        let comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let q = { (k: String) -> String? in
            comps?.queryItems?.first { $0.name == k }?.value
        }
        DispatchQueue.main.async {
            switch host {
            case "switch":
                if let id = q("id") { vm.switchDevice(id) }
            case "capture":
                vm.capturePhoto()
            case "record":
                vm.manager.isRecording ? vm.stopRecording() : vm.startRecording()
            case "beauty":
                if let s = q("s") { vm.settings.smoothing = Double(s) ?? 0 }
                if let w = q("w") { vm.settings.whitening = Double(w) ?? 0 }
                if let sh = q("sh") { vm.settings.sharpen = Double(sh) ?? 0 }
            case "pip":
                if let id = q("id") { vm.togglePIP(id) }
            case "zoom":
                if let f = q("f") { vm.setZoom(Double(f) ?? 1) }
            default:
                break
            }
        }
    }
}

// MARK: - 画中画小窗渲染
#if os(macOS)
struct PIPPreviewView: NSViewRepresentable {
    let image: CIImage?

    func makeNSView(context: Context) -> CIRenderView {
        CIRenderView(frame: .zero)
    }
    func updateNSView(_ nsView: CIRenderView, context: Context) {
        nsView.inputCIImage = image
    }
}

// MARK: - 预览
struct PreviewView: NSViewRepresentable {
    let vm: CameraViewModel

    func makeNSView(context: Context) -> CIRenderView {
        let v = CIRenderView(frame: .zero)
        vm.attach(v)
        return v
    }
    func updateNSView(_ nsView: CIRenderView, context: Context) {}
}
#endif

#if os(iOS)
import UIKit
struct PIPPreviewView: UIViewRepresentable {
    let image: CIImage?
    func makeUIView(context: Context) -> CIRenderView { CIRenderView(frame: .zero) }
    func updateUIView(_ v: CIRenderView, context: Context) { v.inputCIImage = image }
}
struct PreviewView: UIViewRepresentable {
    let vm: CameraViewModel
    func makeUIView(context: Context) -> CIRenderView {
        let v = CIRenderView(frame: .zero)
        vm.attach(v)
        return v
    }
    func updateUIView(_ v: CIRenderView, context: Context) {}
}
#endif

// MARK: - 网格(三分线)
struct GridOverlay: View {
    var body: some View {
        GeometryReader { geo in
            Path { p in
                for i in 1...2 {
                    p.move(to: CGPoint(x: geo.size.width * CGFloat(i) / 3, y: 0))
                    p.addLine(to: CGPoint(x: geo.size.width * CGFloat(i) / 3, y: geo.size.height))
                    p.move(to: CGPoint(x: 0, y: geo.size.height * CGFloat(i) / 3))
                    p.addLine(to: CGPoint(x: geo.size.width, y: geo.size.height * CGFloat(i) / 3))
                }
            }
            .stroke(Color.white.opacity(0.25), lineWidth: 0.7)
        }
    }
}

// MARK: - 底部 HUD
struct HUDView: View {
    @ObservedObject var vm: CameraViewModel

    var body: some View {
        HStack(spacing: 24) {
            // 摄像头选择
            Menu {
                ForEach(vm.manager.devices, id: \.uniqueID) { dev in
                    Button(dev.localizedName) { vm.switchDevice(dev.uniqueID) }
                }
            } label: {
                Label(currentCameraName, systemImage: "camera.on.rectangle")
            }
            .frame(width: 170)

            Spacer()

            // 录像状态
            if vm.manager.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    Text(timeString(vm.manager.recordingSeconds))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.red)
                    // 录音静音实时告警:持续 ≥3s 无声音输入时出现
                    if vm.audioSilentWarning {
                        HStack(spacing: 3) {
                            Image(systemName: "speaker.slash.fill")
                            Text("静音")
                        }
                        .font(.caption)
                        .foregroundColor(.orange)
                        .help("麦克风无声音输入,请检查输入设备或系统声音设置")
                        .transition(.opacity)
                    }
                }
            }

            Spacer()

            // 快门 + 录像 + 夜景/连拍/AE锁
            HStack(spacing: 20) {
                Button {
                    vm.captureNight()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "moon.stars.fill").font(.title3)
                        Text("夜景").font(.caption2)
                    }
                    .foregroundColor(.yellow)
                }
                .help("夜景模式:8帧时域平均降噪 ⌘5")

                Button {
                    vm.captureBurst()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: "burst.fill").font(.title3)
                        Text("连拍").font(.caption2)
                    }
                    .foregroundColor(.white)
                }
                .help("连拍10张,AI选最清晰 ⌘6")

                Button {
                    vm.capturePhoto()
                } label: {
                    ZStack {
                        Circle().stroke(Color.white, lineWidth: 3).frame(width: 64, height: 64)
                        Circle().fill(Color.white).frame(width: 52, height: 52)
                    }
                }
                .buttonStyle(.plain)
                .help("拍照 ⌘3")

                Button {
                    vm.manager.isRecording ? vm.stopRecording() : vm.startRecording()
                } label: {
                    ZStack {
                        Circle().fill(vm.manager.isRecording ? Color.red : Color.white.opacity(0.22))
                            .frame(width: 48, height: 48)
                        RoundedRectangle(cornerRadius: vm.manager.isRecording ? 5 : 24)
                            .fill(vm.manager.isRecording ? Color.white : Color.red)
                            .frame(width: vm.manager.isRecording ? 18 : 30,
                                   height: vm.manager.isRecording ? 18 : 30)
                            .animation(.easeInOut(duration: 0.18), value: vm.manager.isRecording)
                    }
                }
                .buttonStyle(.plain)
                .help("录制 ⌘4")

                Button {
                    vm.manager.toggleAELock()
                } label: {
                    VStack(spacing: 2) {
                        Image(systemName: vm.manager.isAELocked ? "lock.fill" : "lock.open")
                            .font(.title3)
                        Text("AE锁").font(.caption2)
                    }
                    .foregroundColor(vm.manager.isAELocked ? .orange : .white.opacity(0.75))
                }
                .help("曝光锁定 ⌘L(锁定当前测光,逆光/舞台灯不再跳)")
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
    }

    private var currentCameraName: String {
        vm.manager.devices.first { $0.uniqueID == vm.manager.activeDeviceID }?.localizedName ?? "选择摄像头"
    }

    private func timeString(_ t: Double) -> String {
        String(format: "%02d:%02d", Int(t) / 60, Int(t) % 60)
    }
}

// MARK: - Preview(三摄切换/变焦/录像状态的 UI 逻辑验证,mock 状态直灌 HUD)
// manager 含 AVCaptureSession 无法注入 mock → HUD 依赖的读路径抽成协议,HUD 只吃协议。
// Preview 用 mock 实现灌四种场景:三摄/录像中/无设备/变焦中。

/// HUD 依赖的 manager 只读面(协议化,mock 可替身)
protocol HUDManagerModel: ObservableObject {
    var devices: [AVCaptureDevice] { get }
    var activeDeviceID: String? { get }
    var isSessionRunning: Bool { get }
    var isRecording: Bool { get }
    var recordingSeconds: Double { get }
    var zoomFactor: Double { get }
    var zoomIsHardware: Bool { get }
    var isAELocked: Bool { get }
}

extension CameraManager: HUDManagerModel {}

#Preview("HUD·三摄+变焦") {
    let devices = MockCameraHUD.makeFakeDevices(count: 3)
    return HUDPreviewHost(manager: MockCameraHUD(
        devices: devices, active: devices[1].uniqueID,
        zoom: 2.5, zoomHW: false, recording: false))
        .frame(width: 720, height: 80)
        .background(Color.black)
}

#Preview("HUD·录像中(变焦/切换禁用)") {
    let devices = MockCameraHUD.makeFakeDevices(count: 2)
    return HUDPreviewHost(manager: MockCameraHUD(
        devices: devices, active: devices[0].uniqueID,
        zoom: 1.0, zoomHW: true, recording: true, recordingSeconds: 63.4))
        .frame(width: 720, height: 80)
        .background(Color.black)
}

#Preview("HUD·无设备降级") {
    HUDPreviewHost(manager: MockCameraHUD(devices: [], active: nil, zoom: 1, zoomHW: false, recording: false))
        .frame(width: 720, height: 80)
        .background(Color.black)
}

/// Preview 专用 mock:实现协议只读面;AVCaptureDevice 无法构造,用真实枚举兜底
final class MockCameraHUD: HUDManagerModel {
    @Published var devices: [AVCaptureDevice]
    @Published var activeDeviceID: String?
    @Published var isSessionRunning: Bool
    @Published var isRecording: Bool
    @Published var recordingSeconds: Double
    @Published var zoomFactor: Double
    @Published var zoomIsHardware: Bool
    @Published var isAELocked: Bool

    init(devices: [AVCaptureDevice], active: String?, zoom: Double, zoomHW: Bool,
         recording: Bool, recordingSeconds: Double = 0) {
        self.devices = devices
        self.activeDeviceID = active
        self.isSessionRunning = !devices.isEmpty
        self.isRecording = recording
        self.recordingSeconds = recordingSeconds
        self.zoomFactor = zoom
        self.zoomIsHardware = zoomHW
        self.isAELocked = false
    }

    /// Preview 设备假数据源:枚举系统真实设备(Preview 进程能跑 AVFoundation 枚举),
    /// 数量不足则复用现有设备补齐 —— 保持在 Preview 沙盒里零硬件写操作。
    static func makeFakeDevices(count: Int) -> [AVCaptureDevice] {
        let real = AVCaptureDevice.devices(for: .video)
        guard !real.isEmpty else { return [] }
        var out = real
        while out.count < count { out.append(real[out.count % real.count]) }
        return Array(out.prefix(count))
    }
}

/// HUD 直连 mock manager 的宿主(HUDView 本身吃 CameraViewModel,
/// Preview 用 mock manager 构造一个只展示状态的轻量宿主,绕开真会话)
struct HUDPreviewHost: View {
    @ObservedObject var manager: MockCameraHUD

    var body: some View {
        HStack(spacing: 24) {
            Menu {
                ForEach(manager.devices, id: \.uniqueID) { dev in
                    Button(dev.localizedName) {}
                }
            } label: {
                Label(manager.devices.first { $0.uniqueID == manager.activeDeviceID }?.localizedName ?? "选择摄像头",
                      systemImage: "camera.on.rectangle")
            }
            .frame(width: 170)
            .disabled(manager.isRecording)   // 录像中切换禁用(与 DevicePolicy 守卫一致)

            Spacer()

            if manager.isRecording {
                HStack(spacing: 6) {
                    Circle().fill(Color.red).frame(width: 10, height: 10)
                    Text(String(format: "%02d:%02d", Int(manager.recordingSeconds) / 60, Int(manager.recordingSeconds) % 60))
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(.red)
                }
            }

            Spacer()

            HStack(spacing: 16) {
                Image(systemName: "minus.magnifyingglass")
                Text(String(format: "%.1fx", manager.zoomFactor))
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(manager.zoomIsHardware ? .green : .orange)
                Image(systemName: "plus.magnifyingglass")
                Text(manager.zoomIsHardware ? "硬件" : "软件")
                    .font(.caption2).foregroundColor(.secondary)
            }
            .opacity(manager.isRecording ? 0.4 : 1.0)
        }
        .padding(.horizontal, 24)
    }
}

// MARK: - 右侧面板
struct SidePanelView: View {
    @ObservedObject var vm: CameraViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                // AI 体检卡
                GroupBox(label: Label("AI 体检", systemImage: "sparkles")) {
                    VStack(alignment: .leading, spacing: 8) {
                        scoreRow("清晰度", vm.lastAnalysis.blurScore, goodHigh: true)
                        scoreRow("曝光", vm.lastAnalysis.exposureScore, goodHigh: false)
                        HStack {
                            Label("人脸 \(vm.lastAnalysis.faceCount)", systemImage: "face.dashed")
                            Spacer()
                        }
                        .font(.caption)
                        if let hint = vm.lastAnalysis.compositionHint {
                            Text(hint).font(.caption).foregroundColor(.secondary)
                        }
                        if let tip = vm.lastAnalysis.suggestion {
                            Text(tip)
                                .font(.callout.weight(.medium))
                                .foregroundColor(tip.hasPrefix("画质 OK") ? .green : .orange)
                        }
                        if let r = vm.lastCaptureReport {
                            Divider()
                            VStack(alignment: .leading, spacing: 3) {
                                Text("最近成片修正报告").font(.caption.weight(.semibold))
                                Text(String(format: "清晰度 %.0f → %.0f  曝光 %.0f → %.0f  色偏 %+.0f → %+.0f",
                                            r.beforeBlur, r.afterBlur, r.beforeExposure, r.afterExposure,
                                            r.beforeColorCast, r.afterColorCast))
                                    .font(.caption2.monospacedDigit())
                                    .foregroundColor(r.improved ? .green : .secondary)
                                if !r.applied.isEmpty {
                                    Text(r.applied.joined(separator: " · "))
                                        .font(.caption2).foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 4)
                }

                // 美颜
                GroupBox(label: Label("自然美颜", systemImage: "wand.and.stars")) {
                    VStack(spacing: 10) {
                        slider("磨皮", $vm.settings.smoothing)
                        slider("瘦脸", $vm.settings.faceSlim)
                        slider("美白", $vm.settings.whitening)
                        slider("提亮", $vm.settings.brightening)
                        slider("锐化", $vm.settings.sharpen, range: 0...1)
                        HStack {
                            Text("色温").font(.caption).frame(width: 56, alignment: .leading)
                            Slider(value: $vm.settings.warmth, in: -1...1)
                            Text(String(format: "%+.0f", vm.settings.warmth * 100))
                                .font(.caption.monospacedDigit()).frame(width: 34)
                        }
                        HStack {
                            Text("饱和").font(.caption).frame(width: 56, alignment: .leading)
                            Slider(value: $vm.settings.saturation, in: -1...1)
                            Text(String(format: "%+.0f", vm.settings.saturation * 100))
                                .font(.caption.monospacedDigit()).frame(width: 34)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // AI 修正(档位开关 + 实时报告)
                GroupBox(label: Label("AI 修正", systemImage: "wand.and.rays")) {
                    VStack(alignment: .leading, spacing: 6) {
                        // 档位开关卡片:每类修正独立启停,关掉的项拍照时不再自动触发
                        ForEach(AICorrectionKind.allCases, id: \.self) { kind in
                            Toggle(isOn: Binding(
                                get: { vm.aiToggles[kind] ?? true },
                                set: { vm.aiToggles[kind] = $0 })) {
                                HStack {
                                    Text(kind.rawValue).font(.caption)
                                    Spacer()
                                    if (vm.aiToggles[kind] ?? true) == false {
                                        Text("已停用").font(.caption2).foregroundColor(.orange)
                                    }
                                }
                            }
                            .toggleStyle(.switch)
                            .controlSize(.mini)
                        }
                        Divider()
                        // 最近成片:AI 实际做了什么(实时明细)
                        if let r = vm.lastCaptureReport, !r.applied.isEmpty {
                            Text("最近成片修正明细").font(.caption2.weight(.semibold))
                            ForEach(r.applied, id: \.self) { item in
                                HStack(spacing: 4) {
                                    Image(systemName: "checkmark.circle.fill")
                                        .font(.caption2).foregroundColor(.green)
                                    Text(item).font(.caption2)
                                }
                            }
                        } else {
                            Text("最近一张无需修正").font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                // AI 画面
                GroupBox(label: Label("AI 画面", systemImage: "person.and.background.dotted")) {
                    VStack(spacing: 10) {
                        slider("人像虚化", $vm.settings.backgroundBlur)
                        slider("暗角", $vm.settings.vignette)
                        HStack {
                            Text("变焦").font(.caption).frame(width: 56, alignment: .leading)
                            Slider(value: Binding(
                                get: { vm.zoom },
                                set: { vm.setZoom($0) }), in: 1...8)
                            Text(String(format: "%.1fx", vm.zoom))
                                .font(.caption.monospacedDigit()).frame(width: 38)
                        }
                        HStack {
                            // 档位快拍:防手滑跳变,带缓动动画(痛点:变焦跳变生硬)
                            ForEach([1.0, 2.0, 4.0, 8.0], id: \.self) { z in
                                Button(String(format: "%g×", z)) {
                                    vm.setZoom(z)
                                }
                                .font(.caption.monospacedDigit())
                                .buttonStyle(.bordered)
                                .tint(abs(vm.zoom - z) < 0.01 ? .accentColor : .gray)
                            }
                            Spacer()
                            Text(vm.zoomIsHardware ? "硬件变焦" : "软件裁切")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        // 镜头位快切(iOS 三摄位:0.5×/1×/5× 硬件镜头,非数码裁切)
                        #if os(iOS)
                        if !vm.manager.lensCandidates.isEmpty {
                            HStack {
                                Text("镜头位").font(.caption).frame(width: 56, alignment: .leading)
                                ForEach(vm.manager.lensCandidates, id: \.device.uniqueID) { cand in
                                    Button(cand.label) {
                                        vm.manager.switchDevice(to: cand.device.uniqueID)
                                    }
                                    .font(.caption.monospacedDigit())
                                    .buttonStyle(.borderedProminent)
                                    .tint(vm.manager.activeDeviceID == cand.device.uniqueID ? .accentColor : .gray)
                                }
                                Spacer()
                            }
                        }
                        #endif
                        Toggle("三分线网格", isOn: $vm.showGrid)
                            .font(.caption)
                    }
                    .padding(.vertical, 4)
                }

                // 手动曝光 / 对焦(专业档)
                GroupBox(label: Label("手动曝光 / 对焦", systemImage: "camera.aperture")) {
                    VStack(spacing: 10) {
                        HStack {
                            Text("曝光EV").font(.caption).frame(width: 56, alignment: .leading)
                            Slider(value: $vm.aeBiasEV, in: vm.exposureBiasRange)
                            Text(String(format: "%+.1f", vm.aeBiasEV))
                                .font(.caption.monospacedDigit()).frame(width: 40)
                        }
                        HStack {
                            Button(vm.aeBiasEV == 0 ? "" : "EV归零") { vm.aeBiasEV = 0 }
                                .font(.caption)
                                .disabled(vm.aeBiasEV == 0)
                            Spacer()
                            Button(vm.isFocusLocked ? "解除对焦锁" : "锁定对焦") {
                                vm.toggleFocusLock()
                            }
                            .font(.caption)
                            Button(vm.settings.focusPeaking > 0 ? "关闭峰值" : "对焦峰值") {
                                vm.setFocusPeaking(vm.settings.focusPeaking == 0)
                            }
                            .font(.caption)
                        }
                    }
                    .padding(.vertical, 4)
                }

                // 多摄画中画
                if vm.manager.devices.count > 1 {
                    GroupBox(label: Label("多摄像头(\(vm.manager.devices.count))", systemImage: "rectangle.on.rectangle")) {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(vm.manager.devices, id: \.uniqueID) { dev in
                                let isMain = dev.uniqueID == vm.manager.activeDeviceID
                                let isPIP = vm.manager.pipDeviceIDs.contains(dev.uniqueID)
                                HStack {
                                    Image(systemName: isMain ? "video.fill" : (isPIP ? "rectangle.inset.filled" : "video"))
                                        .foregroundColor(isMain ? .green : (isPIP ? .accentColor : .secondary))
                                    Text(dev.localizedName)
                                        .font(.caption)
                                        .lineLimit(1)
                                    Spacer()
                                    if !isMain {
                                        Button(isPIP ? "移除" : "画中画") { vm.togglePIP(dev.uniqueID) }
                                            #if os(macOS)
                                            .buttonStyle(.link)
                                            #endif
                                            .font(.caption)
                                        Button("设为主摄") { vm.switchDevice(dev.uniqueID) }
                                            #if os(macOS)
                                            .buttonStyle(.link)
                                            #endif
                                            .font(.caption)
                                    } else {
                                        Text("主摄").font(.caption2).foregroundColor(.green)
                                    }
                                }
                            }
                            Text("画中画最多 3 路;iPhone 可通过连续互通相机直接接入")
                                .font(.caption2).foregroundColor(.secondary)
                        }
                        .padding(.vertical, 4)
                    }
                }

                // 保存结果
                if let path = vm.lastSavedPath {
                    GroupBox(label: Label("最近保存", systemImage: "square.and.arrow.down")) {
                        Text(path)
                            .font(.caption2.monospaced())
                            .foregroundColor(.secondary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                // 状态
                if vm.manager.authorizationDenied {
                    Label("相机权限被拒绝,请到系统设置 > 隐私与安全性 > 相机 中开启",
                          systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.red)
                        .font(.caption)
                } else if !vm.manager.isSessionRunning {
                    ProgressView().scaleEffect(0.7)
                    Text("启动摄像头…").font(.caption).foregroundColor(.secondary)
                }
            }
            .padding(14)
        }
    }

    @ViewBuilder
    private func scoreRow(_ name: String, _ value: Double, goodHigh: Bool) -> some View {
        HStack {
            Text(name).font(.caption).frame(width: 44, alignment: .leading)
            ProgressView(value: value, total: 100)
                .progressViewStyle(.linear)
                .tint(color(for: value, goodHigh: goodHigh))
            Text(String(format: "%.0f", value))
                .font(.caption.monospacedDigit()).frame(width: 26)
        }
    }

    private func color(for v: Double, goodHigh: Bool) -> Color {
        let good = goodHigh ? v : (50 - abs(v - 50) * 2)
        if good >= 60 { return .green }
        if good >= 35 { return .orange }
        return .red
    }

    private func slider(_ name: String, _ binding: Binding<Double>, range: ClosedRange<Double> = 0...1) -> some View {
        HStack {
            Text(name).font(.caption).frame(width: 56, alignment: .leading)
            Slider(value: binding, in: range)
            Text(String(format: "%.0f", binding.wrappedValue * 100))
                .font(.caption.monospacedDigit()).frame(width: 30)
        }
    }
}
