import Foundation
import Network
import CoreImage
import AppKit
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
                "format": m.debugFormatDims,
                "delivered": m.framesDelivered,
                "dropped": m.framesDropped,
                "videoFrames": m.videoFrames,
                "audioFrames": m.audioFrames,
                "drawCount": vm.renderDrawCount,
                "drawState": vm.renderDrawState,
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
        let rep = NSBitmapImageRep(cgImage: cg)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            reply(conn, json: "{\"error\":\"encode failed\"}", status: "500 Internal Server Error")
            return
        }
        send(conn, data: png, contentType: "image/png")
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
