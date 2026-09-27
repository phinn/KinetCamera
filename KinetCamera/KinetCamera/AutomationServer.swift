import Foundation
import Network
import CoreImage
#if canImport(AppKit)
import AppKit
#endif
import AVFoundation

/// 本地 loopback 自动化接口(仅绑定 127.0.0.1,外部不可达):
/// GET  /status                    → JSON 运行态(设备/会话/PIP/帧计数/AI 分数/最近产物)
/// POST /capture                   → 与 ⌘3 完全同路径触发拍照
/// POST /record                    → 与 ⌘4 完全同路径触发录像开关
/// POST /frame?mode=raw|processed  → 返回当前帧 PNG(原始 / 过完整美颜链)
final class AutomationServer {

    static let shared = AutomationServer()
    private let port: UInt16 = 17877
    private var listener: NWListener?
    private weak var vm: CameraViewModel?
    private let queue = DispatchQueue(label: "com.kinet.automation")

    func start(vm: CameraViewModel) {
        self.vm = vm
        guard listener == nil else { return }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        #if os(iOS)
        // iOS 真机验收:绑通配接口(同 Wi-Fi 的 Mac 可驱动实录/三摄切换);LocalNetwork 权限由 Info.plist 声明
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "0.0.0.0", port: NWEndpoint.Port(rawValue: port)!)
        #else
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        #endif
        guard let l = try? NWListener(using: params) else {
            NSLog("[KinetAutomation] listener create failed")
            return
        }
        listener = l
        l.newConnectionHandler = { [weak self] conn in
            self?.accept(conn)
        }
        l.start(queue: queue)
        NSLog("[KinetAutomation] listening on 127.0.0.1:%d", port)
    }

    private func accept(_ conn: NWConnection) {
        conn.start(queue: queue)
        readRequest(conn, buffer: Data())
    }

    /// 简易 HTTP:收齐 header + Content-Length body 后路由
    private func readRequest(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, done, error in
            guard let self else { conn.cancel(); return }
            var buf = buffer
            if let data = data { buf.append(data) }
            if let headerEnd = buf.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buf.subdata(in: buf.startIndex..<headerEnd.lowerBound)
                let header = String(decoding: headerData, as: UTF8.self)
                let contentLength = self.parseContentLength(header)
                let bodyStart = headerEnd.upperBound
                let bodySoFar = buf.count - bodyStart
                if bodySoFar >= contentLength {
                    let body = buf.subdata(in: bodyStart..<buf.startIndex + bodyStart + contentLength)
                    let requestLine = header.components(separatedBy: "\r\n").first ?? ""
                    self.route(requestLine: requestLine, body: body, conn: conn)
                } else {
                    self.readRequest(conn, buffer: buf)
                }
            } else if done || error != nil {
                conn.cancel()
            } else {
                self.readRequest(conn, buffer: buf)
            }
        }
    }

    private func parseContentLength(_ header: String) -> Int {
        for line in header.components(separatedBy: "\r\n") {
            let parts = line.lowercased().split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmed == "content-length" {
                return Int(parts[1].trimmed) ?? 0
            }
        }
        return 0
    }

    private func route(requestLine: String, body: Data, conn: NWConnection) {
        let tokens = requestLine.components(separatedBy: " ")
        let method = tokens.count > 0 ? tokens[0] : ""
        let target = tokens.count > 1 ? tokens[1] : ""
        let path = target.components(separatedBy: "?").first ?? target

        switch (method, path) {
        case ("GET", "/status"):
            // 走 main.async 取状态后应答,避免在主线程场景下 main.sync 自死锁
            DispatchQueue.main.async { [weak self] in
                guard let self else { conn.cancel(); return }
                self.reply(conn, json: self.statusJSON())
            }
        case ("POST", "/capture"):
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .kinetCapturePhoto, object: nil)
            }
            reply(conn, json: "{\"ok\":true,\"action\":\"capture\"}")
        case ("POST", "/record"):
            // /record                 → toggle(兼容既有脚本)
            // /record?action=start    → 幂等启动(已在录则回 already,不误停)
            // /record?action=stop     → 幂等停止(未在录则回 idle)
            var action = "toggle"
            if let r = target.range(of: "action=") {
                action = target[r.upperBound...].components(separatedBy: "&").first ?? "toggle"
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let vm = self.vm else { conn.cancel(); return }
                switch action {
                case "start":
                    if vm.manager.isRecording {
                        self.reply(conn, json: "{\"ok\":true,\"action\":\"already-recording\"}")
                    } else {
                        NotificationCenter.default.post(name: .kinetStartRecord, object: nil)
                        self.reply(conn, json: "{\"ok\":true,\"action\":\"start\"}")
                    }
                case "stop":
                    if vm.manager.isRecording {
                        NotificationCenter.default.post(name: .kinetStopRecord, object: nil)
                        self.reply(conn, json: "{\"ok\":true,\"action\":\"stop\"}")
                    } else {
                        self.reply(conn, json: "{\"ok\":true,\"action\":\"idle\"}")
                    }
                default:
                    NotificationCenter.default.post(name: .kinetToggleRecord, object: nil)
                    self.reply(conn, json: "{\"ok\":true,\"action\":\"record-toggle\"}")
                }
            }
        case ("POST", "/night"):
            DispatchQueue.main.async { [weak self] in
                self?.vm?.captureNight()   // 直调 vm:通知路径依赖 SwiftUI 场景挂载,后台启动时视图树不存活会丢
            }
            reply(conn, json: "{\"ok\":true,\"action\":\"night\"}")
        case ("POST", "/steady"):
            DispatchQueue.main.async { [weak self] in
                self?.vm?.captureSteady()
            }
            reply(conn, json: "{\"ok\":true,\"action\":\"steady\"}")
        case ("POST", "/hdr"):
            DispatchQueue.main.async { [weak self] in
                self?.vm?.captureHDR()
            }
            reply(conn, json: "{\"ok\":true,\"action\":\"hdr\"}")
        case ("POST", "/burst"):
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .kinetCaptureBurst, object: nil)
            }
            reply(conn, json: "{\"ok\":true,\"action\":\"burst\"}")
        case ("POST", "/video"):
            // /video?preset=hd1080p30|uhd4k60 —— 录像质量档切换(录制中拒绝)
            var preset = ""
            if let r = target.range(of: "preset=") {
                preset = target[r.upperBound...].components(separatedBy: "&").first ?? ""
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let vm = self.vm else { conn.cancel(); return }
                guard let q = CameraManager.RecordingQuality(rawValue: preset) else {
                    self.reply(conn, json: "{\"error\":\"bad preset, expect hd1080p30|uhd4k60\"}")
                    return
                }
                vm.manager.setRecordingQuality(q)
                self.reply(conn, json: "{\"ok\":true,\"preset\":\"\(q.rawValue)\",\"fps\":\(q.fps)}")
            }
        case ("POST", "/zoom"):
            // 变焦: /zoom?f=2.5 (硬件 zoomFactor 优先,软件裁切兜底) / /zoom?f=1 复位
            var f = 1.0
            if let r = target.range(of: "f=") {
                let s = target[r.upperBound...].components(separatedBy: "&").first ?? ""
                f = Double(s) ?? 1.0
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let vm = self.vm else { conn.cancel(); return }
                vm.setZoom(f)
                // 回包报 clamp 后的目标收敛值(与 setZoom 内部同一 clamp 路径)。
                // 勿读 manager.zoomFactor:easeOutCubic 动画进行中它还是旧值,回包恒滞后一拍。
                let target = DevicePolicy.clampZoom(f, formatMax: vm.manager.activeFormatMaxZoom())
                self.reply(conn, json: "{\"ok\":true,\"zoom\":\(target)}")
            }
        case ("POST", "/aelock"):
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .kinetToggleAELock, object: nil)
            }
            reply(conn, json: "{\"ok\":true,\"action\":\"aelock-toggle\"}")
        case ("POST", "/brightness"):
            // AE 闭环验证:模拟场景光变化,如 /brightness?f=0.4(iOS 无合成源,空操作)
            #if os(macOS)
            var f = 1.0
            if let r = target.range(of: "f=") {
                let s = target[r.upperBound...].components(separatedBy: "&").first ?? ""
                f = Double(s) ?? 1.0
            }
            SyntheticCameraSource.shared.brightnessFactor = f
            reply(conn, json: "{\"ok\":true,\"brightnessFactor\":\(f)}")
            #else
            reply(conn, json: "{\"ok\":true,\"brightnessFactor\":1.0,\"note\":\"macOS only\"}")
            #endif
        case ("POST", "/beauty"):
            // 美颜+人像虚化+瘦脸一键: /beauty?s=0.6&w=0.4&b=0.8&slim=0.7 或 /beauty?preset=off
            var s = 0.0, w = 0.0, b = 0.0
            func param(_ key: String) -> Double? {
                guard let r = target.range(of: "\(key)=") else { return nil }
                let str = target[r.upperBound...].components(separatedBy: "&").first ?? ""
                return Double(str)
            }
            var slim = 0.0
            var sharpen: Double? = nil
            if target.contains("preset=off") {
                s = 0; w = 0; b = 0; slim = 0
                sharpen = 0
            } else {
                s = min(max(param("s") ?? 0.6, 0), 1)
                w = min(max(param("w") ?? 0.4, 0), 1)
                b = min(max(param("b") ?? 0, 0), 1)
                slim = min(max(param("slim") ?? 0, 0), 1)
                if let p = param("sh") { sharpen = min(max(p, 0), 1) }
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Notification.Name("kinetSetBeauty"), object: nil,
                    userInfo: ["smoothing": s, "whitening": w, "backgroundBlur": b, "faceSlim": slim,
                               "sharpen": sharpen])
            }
            reply(conn, json: "{\"ok\":true,\"smoothing\":\(s),\"whitening\":\(w),\"backgroundBlur\":\(b),\"faceSlim\":\(slim)}")
        case ("POST", "/exposure"):
            // 手动曝光(软件EV档): /exposure?ev=1.0 或 /exposure?ev=auto(回0)
            var ev = 0.0
            if let r = target.range(of: "ev=") {
                let s = target[r.upperBound...].components(separatedBy: "&").first ?? ""
                ev = s == "auto" ? 0 : (Double(s) ?? 0)
            }
            DispatchQueue.main.async { self.vm?.settings.exposureEV = max(-2, min(2, ev)) }
            // 回包报 clamp 后实际值(±2),而非回显请求参数
            reply(conn, json: "{\"ok\":true,\"exposureEV\":\(max(-2, min(2, ev)))}")
        case ("POST", "/grid"):
            // 网格/水平仪叠加: /grid?on=1&horizon=3.2(度;|θ|<0.5 绿=水平,否则黄)
            // 纯预览叠加,不进照片
            let on = target.contains("on=1")
            var horizon: Double?
            if let r = target.range(of: "horizon=") {
                horizon = Double(target[r.upperBound...].components(separatedBy: "&").first ?? "")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.vm?.setGrid(on)
                if let h = horizon { self.vm?.setHorizon(h) }
                self.reply(conn, json: "{\"ok\":true,\"grid\":\(on),\"horizon\":\(horizon ?? 0)}")
            }
        case ("POST", "/captureHD"):
            // 全画幅直拍(A1):photoOutput 全分辨率,纯净档无美颜;回包报落盘文件名或失败原因
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                #if os(iOS)
                let ok = self.vm?.manager.captureFullResolution { url in
                    NSLog("[KinetCamera] captureHD → \(url?.lastPathComponent ?? "nil")")
                } ?? false
                self.reply(conn, json: ok
                    ? "{\"ok\":true,\"mode\":\"fullResolution\"}"
                    : "{\"ok\":false,\"reason\":\"photoOutput inactive\"}")
                #else
                self.reply(conn, json: "{\"error\":\"iOS only\"}")
                #endif
            }
        case ("POST", "/lens"):
            // iOS 手动对焦镜距: /lens?v=0.5(0近焦~1无穷远) / v=-1 交还自动
            var v = -1.0
            if let r = target.range(of: "v=") {
                v = Double(target[r.upperBound...].components(separatedBy: "&").first ?? "") ?? -1.0
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                #if os(iOS)
                let applied = self.vm?.manager.setManualLensPosition(Float(v)) ?? false
                self.reply(conn, json: applied
                    ? "{\"ok\":true,\"lensPosition\":\(v)}"
                    : "{\"ok\":false,\"reason\":\"no active camera or focus lock unsupported\"}")
                #else
                self.reply(conn, json: "{\"error\":\"iOS only (macOS lensPosition platform-walled)\"}")
                #endif
            }
        case ("POST", "/exposureManual"):
            // iOS 硬件手动曝光: /exposureManual?dur=0.02&iso=400(秒/ISO) / 全 nil 交还自动
            // (区别于 /exposure 的软件 EV 档:硬件档直控传感器,软件档走滤镜链增益)
            var dur: Double?, iso: Float?
            if let r = target.range(of: "dur=") {
                dur = Double(target[r.upperBound...].components(separatedBy: "&").first ?? "")
            }
            if let r = target.range(of: "iso=") {
                iso = Float(target[r.upperBound...].components(separatedBy: "&").first ?? "")
            }
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                #if os(iOS)
                let applied = self.vm?.manager.setManualExposure(durationSeconds: dur, iso: iso) ?? false
                self.reply(conn, json: applied
                    ? "{\"ok\":true,\"duration\":\(dur ?? -1),\"iso\":\(iso ?? -1)}"
                    : "{\"ok\":false,\"reason\":\"no active camera or custom exposure unsupported\"}")
                #else
                self.reply(conn, json: "{\"error\":\"iOS only (macOS exposure platform-walled)\"}")
                #endif
            }
        case ("POST", "/torch"):
            // 手电/补光: /torch?on=1 / on=0(录制补光;拍照 flash 随 photoOutput 档落地)
            let on = target.contains("on=1")
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                #if os(iOS)
                let applied = self.vm?.manager.setTorch(on) ?? false
                self.reply(conn, json: applied ? "{\"ok\":true,\"torch\":\(on)}" : "{\"ok\":false,\"reason\":\"no torch\"}")
                #else
                self.reply(conn, json: "{\"error\":\"iOS only\"}")
                #endif
            }
        case ("POST", "/focus"):
            // 对焦锁: /focus?mode=lock(防拉风箱) / mode=auto(交还系统)
            let lock = !target.contains("mode=auto")
            DispatchQueue.main.async {
                if lock { if !(self.vm?.isFocusLocked ?? false) { self.vm?.toggleFocusLock() } }
                else { if self.vm?.isFocusLocked == true { self.vm?.toggleFocusLock() } }
            }
            reply(conn, json: "{\"ok\":true,\"focusLocked\":\(lock)}")
        case ("POST", "/peaking"):
            // 对焦峰值: /peaking?on=1 / on=0
            let on = target.contains("on=1")
            DispatchQueue.main.async { self.vm?.setFocusPeaking(on) }
            reply(conn, json: "{\"ok\":true,\"focusPeaking\":\(on ? 0.8 : 0)}")
        case ("POST", "/retro"):            // 回溯快门:扫描快门前2s帧环,AI选综合最优帧落盘
            DispatchQueue.main.async { [weak self] in
                guard let self, let vm = self.vm else { conn.cancel(); return }
                vm.captureRetro()
                self.reply(conn, json: "{\"ok\":true,\"action\":\"retro\"}")
            }
        case ("POST", "/synthLens"):
            // /synthLens?lens=uw|wide|tele —— 合成源回退态的虚拟摄位切换(模拟器无源验收链)
            DispatchQueue.main.async { [weak self] in
                guard let self, let vm = self.vm else { conn.cancel(); return }
                guard vm.manager.synthFallbackActive else {
                    self.reply(conn, json: "{\"error\":\"synthetic fallback not active\"}", status: "409 Conflict")
                    return
                }
                let lens = target.range(of: "lens=").map { String(target[$0.upperBound...]).components(separatedBy: "&").first ?? "" } ?? ""
                let kind: SyntheticLensKind?
                switch lens {
                case "uw": kind = .ultrawide
                case "wide": kind = .wide
                case "tele": kind = .tele
                default: kind = nil
                }
                guard let k = kind else {
                    self.reply(conn, json: "{\"error\":\"bad lens, expect uw|wide|tele\"}", status: "400 Bad Request")
                    return
                }
                vm.manager.switchSynthLens(k)
                self.reply(conn, json: "{\"ok\":true,\"lens\":\"\(lens)\",\"active\":\"synth.\(lens)\"}")
            }
        case ("POST", "/switch"):
            // /switch?id=<deviceID> 切主摄。
            // 先校验 target 在 live 列表里再回 ok;switchDevice 内部 may 静默拒绝(录像中/死设备),
            // 不能无脑回 ok:true+回显请求 id(曾把切到不存在设备报成成功,误导验收)。
            DispatchQueue.main.async { [weak self] in
                guard let self, let vm = self.vm else { conn.cancel(); return }
                if let range = target.range(of: "id=") {
                    let id = String(target[range.upperBound...]).components(separatedBy: "&").first ?? ""
                    let live = vm.manager.devices.map { $0.uniqueID }
                    guard vm.manager.devices.contains(where: { $0.uniqueID == id }) else {
                        self.reply(conn, json: "{\"error\":\"device not found\",\"active\":\"\(vm.manager.activeDeviceID ?? "")\",\"requested\":\"\(id)\"}", status: "404 Not Found")
                        return
                    }
                    vm.manager.switchDevice(to: id)
                    // 以切换后的实际主摄为准回包,而非回显请求参数
                    self.reply(conn, json: "{\"ok\":true,\"active\":\"\(vm.manager.activeDeviceID ?? "")\",\"requested\":\"\(id)\"}")
                } else {
                    self.reply(conn, json: "{\"error\":\"need id=\"}", status: "400 Bad Request")
                }
            }
        case ("POST", "/awaitDevice"):
            // /awaitDevice?id=<deviceID>[&timeout=N] — 离线设备状态机:枚举→等待→超时降级→上线热恢复
            DispatchQueue.main.async { [weak self] in
                guard let self, let vm = self.vm else { conn.cancel(); return }
                guard let range = target.range(of: "id=") else {
                    self.reply(conn, json: "{\"error\":\"need id=\"}", status: "400 Bad Request")
                    return
                }
                let id = String(target[range.upperBound...]).components(separatedBy: "&").first ?? ""
                var timeout = vm.manager.waitMaxAttempts
                if let tr = target.range(of: "timeout="), let v = Int(String(target[tr.upperBound...]).components(separatedBy: "&").first ?? "") {
                    timeout = max(1, min(60, v))
                }
                let online = vm.manager.devices.contains { $0.uniqueID == id }
                if online {
                    vm.manager.clearDeviceWaitState()   // 即时接管时清掉残留的 degraded/waiting 状态
                    self.reply(conn, json: "{\"ok\":true,\"state\":\"online\",\"active\":\"\(id)\"}")
                    vm.manager.switchDevice(to: id)
                } else {
                    self.reply(conn, json: "{\"ok\":true,\"state\":\"waiting\",\"timeout\":\(timeout)}")
                    vm.manager.awaitDevice(id: id, timeoutAttempts: timeout)
                }
            }
        case ("GET", "/deviceWait"):
            // 状态机查询:idle / waiting(n) / degraded(reason)
            DispatchQueue.main.async { [weak self] in
                guard let self, let vm = self.vm else { conn.cancel(); return }
                let msg = vm.manager.deviceWaitStatusMessage
                self.reply(conn, json: "{\"state\":\"\(msg.isEmpty ? "idle" : (msg.hasPrefix("等待") ? "waiting" : "degraded"))\",\"message\":\"\(msg)\"}")
            }
        case ("POST", "/pip"):            // /pip?id=<deviceID> 或 /pip?on=1 全部非主摄设备入 PIP
            DispatchQueue.main.async { [weak self] in
                guard let self, let vm = self.vm else { conn.cancel(); return }
                if let range = target.range(of: "id=") {
                    let id = String(target[range.upperBound...]).components(separatedBy: "&").first ?? ""
                    // 校验目标设备存在(屏流伪设备放行);死 id 回 404,不把失败报成 ok
                    let isScreen = (id == CameraManager.screenPseudoID)
                    guard isScreen || vm.manager.devices.contains(where: { $0.uniqueID == id }) else {
                        self.reply(conn, json: "{\"error\":\"device not found\",\"requested\":\"\(id)\"}", status: "404 Not Found")
                        return
                    }
                    vm.togglePIP(id)
                    self.reply(conn, json: "{\"ok\":true,\"pip\":\"\(id)\",\"pipList\":\(vm.manager.pipDeviceIDs)}")
                } else if target.contains("on=1") {
                    // 全部可用信号源入 PIP:非主摄摄像头 + 屏幕流
                    let others = vm.manager.devices.filter { $0.uniqueID != vm.manager.activeDeviceID }
                    for d in others { vm.togglePIP(d.uniqueID) }
                    #if os(macOS)
                    if !vm.manager.pipDeviceIDs.contains(ScreenSourceController.id) {
                        vm.togglePIP(ScreenSourceController.id)
                    }
                    #endif
                    self.reply(conn, json: "{\"ok\":true,\"pipAll\":\(others.count + 1)}")
                } else {
                    self.reply(conn, json: "{\"error\":\"need id= or on=1\"}", status: "400 Bad Request")
                }
            }
        case ("POST", "/frame"):
            let wantProcessed = target.contains("mode=processed")
            respondFrame(conn, processed: wantProcessed)
        default:
            reply(conn, json: "{\"error\":\"not found\"}", status: "404 Not Found")
        }
    }

    private func statusJSON() -> String {
        // 必须在主线程调用(route 已保证)
        dispatchPrecondition(condition: .onQueue(.main))
        guard let vm = vm else { return "{\"error\":\"no vm\"}" }
        var snap: [String: Any] = [:]
        let m = vm.manager
            snap = [
                "devices": m.devices.map { ["id": $0.uniqueID, "name": $0.localizedName] },
                "activeDeviceID": m.activeDeviceID ?? "",
                "isSessionRunning": m.isSessionRunning,
                "isRecording": m.isRecording,
                "recordingSeconds": (m.recordingSeconds * 10).rounded() / 10,
                "pipDeviceIDs": m.pipDeviceIDs,
                "pipFrameCount": vm.pipFrames.count,
                "pipFrameTotal": vm.pipFrameTotal,
                "screenFrameCount": m.screenFrameCount,
                "pipStatus": m.pipStatusMessage,
                "mainFrameCount": vm.frameCount,
                "processedFps": vm.processedFps,
                "synthFallbackActive": vm.manager.synthFallbackActive,
                "synthLens": SyntheticCameraSource.shared.lensKind == .ultrawide ? "uw" : (SyntheticCameraSource.shared.lensKind == .tele ? "tele" : "wide"),
                "zoomFactor": vm.zoom,
                "showGrid": vm.showGrid,
                "horizonAngle": vm.horizonAngle,
                "zoomIsHardware": vm.zoomIsHardware,
                "beauty": ["smoothing": vm.settings.smoothing, "whitening": vm.settings.whitening,
                           "brightening": vm.settings.brightening, "faceSlim": vm.settings.faceSlim,
                           "backgroundBlur": vm.settings.backgroundBlur, "sharpen": vm.settings.sharpen],
                "audioSilentWarning": vm.audioSilentWarning,
                "lastVideoAudioSilent": vm.lastVideoAudioSilent,
                "recordingURL": m.lastRecordingURL as Any?,
                "recordingFinishStatus": m.lastRecordingFinishStatus,
                "recordingError": m.lastRecordingError as Any?,
                "appendAttempts": m.appendAttempts,
                "videoAppendFailures": m.videoAppendFailures,
                "backgroundInterruptedDuringRecord": vm.backgroundInterruptedDuringRecord,
                "scaleMismatch": m.scaleMismatchCount,
                "lastAppendErrorCode": m.lastAppendErrorCode,
                "blur": (vm.lastAnalysis.blurScore * 10).rounded() / 10,
                "exposure": (vm.lastAnalysis.exposureScore * 10).rounded() / 10,
                "composition": (vm.lastAnalysis.exposureScore * 10).rounded() / 10,
                "compositionHint": vm.lastAnalysis.compositionHint ?? "",
                "faces": vm.lastAnalysis.faceCount,
                "lastSavedPath": vm.lastSavedPath ?? "",
                "cameraAuthStatus": AVCaptureDevice.authorizationStatus(for: .video).rawValue,
                "connEnabled": m.debugConnEnabled,
                "outputsCount": m.debugOutputsCount,
                "format": m.debugFormatDims, "ingestDims": "\(m.lastIngestDims.width)x\(m.lastIngestDims.height)",
                "delivered": m.framesDelivered,
                "dropped": m.framesDropped,
                "videoFrames": m.videoFrames,
                "audioFrames": m.audioFrames,
                "syntheticActive": Self.syntheticActive,
                "recordingQuality": m.recordingQuality.rawValue,
                "recordFpsTarget": m.recordingQuality.fps,
                "micAuthStatus": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
                "micName": m.activeMicName,
                "deviceNames": m.devices.map { $0.localizedName },
                "drawCount": vm.renderDrawCount,
                "drawState": vm.renderDrawState,
                "ringCount": m.ringCount,
                "aeLocked": m.isAELocked,
                "zoom": m.zoomFactor,
                "autoAdapt": vm.autoAdapt,
                "adaptReason": vm.lastAdjustment.reason,
                "zoomMode": m.zoomIsHardware ? "hardware" : "software",
                "colorCast": (vm.lastAnalysis.colorCast * 10).rounded() / 10,
                "pipFrames": vm.pipFrames.map { "\($0.key):\($0.value.extent.width)x\(Int($0.value.extent.height))" },
                "lastReport": vm.lastCaptureReport.map {
                    ["beforeBlur": $0.beforeBlur, "afterBlur": $0.afterBlur,
                     "beforeExp": $0.beforeExposure, "afterExp": $0.afterExposure,
                     "beforeCast": $0.beforeColorCast, "afterCast": $0.afterColorCast,
                     "applied": $0.applied.joined(separator: ","), "improved": $0.improved] as [String: Any]
                } ?? [:],
            ]
        guard let data = try? JSONSerialization.data(withJSONObject: snap, options: [.sortedKeys]) else {
            return "{\"error\":\"serialize failed\"}"
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func respondFrame(_ conn: NWConnection, processed: Bool) {
        guard let vm = vm, let raw = vm.manager.takeLatestFrame() else {
            reply(conn, json: "{\"error\":\"no frame\"}", status: "503 Service Unavailable")
            return
        }
        let image = processed ? FilterPipeline.shared.apply(raw, settings: vm.settings, time: .zero) : raw
        let ctx = FilterPipeline.shared.renderContext
        guard let cg = ctx.createCGImage(image, from: image.extent) else {
            reply(conn, json: "{\"error\":\"render failed\"}", status: "500 Internal Server Error")
            return
        }
        guard let png = Self.pngData(of: cg) else {
            reply(conn, json: "{\"error\":\"encode failed\"}", status: "500 Internal Server Error")
            return
        }
        send(conn, data: png, contentType: "image/png")
    }

    #if os(macOS)
    static var syntheticActive: Bool { SyntheticCameraSource.shared.isActive }
    #else
    static var syntheticActive: Bool { false }
    #endif

    /// 跨平台 PNG 编码(ImageIO,macOS/iOS 通用)
    static func pngData(of cg: CGImage) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, "public.png" as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, cg, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }

    private func reply(_ conn: NWConnection, json: String, status: String = "200 OK") {
        send(conn, data: Data(json.utf8), contentType: "application/json", status: status)
    }

    private func send(_ conn: NWConnection, data: Data, contentType: String, status: String = "200 OK") {
        let header = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
        var out = Data(header.utf8)
        out.append(data)
        conn.send(content: out, completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

private extension String.SubSequence {
    var trimmed: String {
        trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n"))
    }
}
