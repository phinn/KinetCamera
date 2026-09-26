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
        params.requiredLocalEndpoint = NWEndpoint.hostPort(
            host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
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
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .kinetToggleRecord, object: nil)
            }
            reply(conn, json: "{\"ok\":true,\"action\":\"record-toggle\"}")
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
        case ("POST", "/zoom"):
            // 变焦: /zoom?f=2.5 (硬件 zoomFactor 优先,软件裁切兜底) / /zoom?f=1 复位
            var f = 1.0
            if let r = target.range(of: "f=") {
                let s = target[r.upperBound...].components(separatedBy: "&").first ?? ""
                f = Double(s) ?? 1.0
            }
            DispatchQueue.main.async { [weak self] in
                guard let self, let vm = self.vm else { return }
                vm.setZoom(f)
            }
            reply(conn, json: "{\"ok\":true,\"zoom\":\(f)}")
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
            if target.contains("preset=off") {
                s = 0; w = 0; b = 0; slim = 0
            } else {
                s = min(max(param("s") ?? 0.6, 0), 1)
                w = min(max(param("w") ?? 0.4, 0), 1)
                b = min(max(param("b") ?? 0, 0), 1)
                slim = min(max(param("slim") ?? 0, 0), 1)
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(
                    name: Notification.Name("kinetSetBeauty"), object: nil,
                    userInfo: ["smoothing": s, "whitening": w, "backgroundBlur": b,
                               "faceSlim": slim])
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
            reply(conn, json: "{\"ok\":true,\"exposureEV\":\(ev)}")
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
        case ("POST", "/switch"):
            // /switch?id=<deviceID> 切主摄
            DispatchQueue.main.async { [weak self] in
                guard let self, let vm = self.vm else { conn.cancel(); return }
                if let range = target.range(of: "id=") {
                    let id = String(target[range.upperBound...]).components(separatedBy: "&").first ?? ""
                    vm.manager.switchDevice(to: id)
                    self.reply(conn, json: "{\"ok\":true,\"active\":\"\(id)\"}")
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
                    vm.togglePIP(id)
                    self.reply(conn, json: "{\"ok\":true,\"pip\":\"\(id)\"}")
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
                "screenFrameCount": m.screenFrameCount,
                "pipStatus": m.pipStatusMessage,
                "mainFrameCount": vm.frameCount,
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
                "micAuthStatus": AVCaptureDevice.authorizationStatus(for: .audio).rawValue,
                "micName": m.activeMicName,
                "deviceNames": m.devices.map { $0.localizedName },
                "drawCount": vm.renderDrawCount,
                "drawState": vm.renderDrawState,
                "ringCount": m.ringCount,
                "aeLocked": m.isAELocked,
                "zoom": m.zoomFactor,
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
        send(conn, data: Data(json.utf8), contentType: "application/json")
    }

    private func send(_ conn: NWConnection, data: Data, contentType: String) {
        let header = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(data.count)\r\nConnection: close\r\n\r\n"
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
