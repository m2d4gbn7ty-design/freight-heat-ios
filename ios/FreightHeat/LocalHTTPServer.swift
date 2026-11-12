//
//  LocalHTTPServer.swift
//  FreightHeat
//
//  极简的本机静态文件服务（Network.framework，无第三方依赖）。
//
//  为什么不用 `appassets://` 直接加载？
//  ---------------------------------------------------------------------------
//  WKWebView 里自定义 scheme 的页面是「不透明源（opaque origin）」，会踩两个硬限制：
//    1. `localStorage` 不可用 —— 而本工具的运价数据全部存在 localStorage；
//    2. `fetch()` 不支持自定义 scheme —— 而地图要 `fetch('geo/110034.json')`。
//  因此默认通道走 http://127.0.0.1:<随机端口>：
//    * 127.0.0.1 被 WebKit 视为可信来源，localStorage / fetch / Service Worker 全部可用；
//    * 只监听回环地址，不触发 iOS「本地网络」权限弹窗，也不暴露到局域网。
//  `AssetSchemeHandler` 仍然保留（离线兜底 + 便于无服务器调试），见 README。
//

import Foundation
import Network

/// 只服务回环地址的静态文件 HTTP 服务。
final class LocalHTTPServer {

    /// 启动失败的原因，便于上层给出可诊断的日志。
    enum StartError: Error {
        case invalidRoot
        case listenerUnavailable
        case portUnavailable
    }

    private let rootDirectory: URL
    private let queue = DispatchQueue(label: "com.freightheat.localhttpserver", qos: .userInitiated)
    private var listener: NWListener?

    /// 实际监听端口（`start()` 成功后有效）。
    private(set) var listenPort: UInt16 = 0

    /// 单次请求头的最大字节数，防止异常客户端打满内存。
    private let maxHeaderBytes = 32 * 1024

    init(rootDirectory: URL) {
        self.rootDirectory = rootDirectory.standardizedFileURL
    }

    deinit {
        stop()
    }

    /// 入口地址：`http://127.0.0.1:<port>/index.html`。
    var entryURL: URL? {
        guard listenPort > 0 else { return nil }
        return URL(string: "http://127.0.0.1:\(listenPort)/\(WebAssetLocator.entryFileName)")
    }

    /// 同步启动，最多等待 `timeout` 秒。
    /// - Note: 在 App 启动路径上调用，超时后放弃回环通道、由调用方切到 scheme 兜底。
    @discardableResult
    func start(timeout: TimeInterval = 3.0) -> Bool {
        if listener != nil {
            return true
        }

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        parameters.includePeerToPeer = false

        guard let newListener = try? NWListener(using: parameters, on: .any) else {
            return false
        }

        let semaphore = DispatchSemaphore(value: 0)
        var resolvedPort: UInt16 = 0

        newListener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                if let port = newListener.port?.rawValue {
                    resolvedPort = port
                }
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }

        newListener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }

        newListener.start(queue: queue)
        _ = semaphore.wait(timeout: .now() + timeout)

        guard resolvedPort > 0 else {
            newListener.cancel()
            return false
        }

        listenPort = resolvedPort
        listener = newListener
        return true
    }

    /// 停止服务并释放端口。App 进入后台或视图销毁时调用。
    func stop() {
        listener?.cancel()
        listener = nil
        listenPort = 0
    }

    // MARK: - 请求处理

    private func accept(_ connection: NWConnection) {
        // 只接受回环地址发起的连接：监听端口虽然监听在所有网卡上，
        // 但外部设备连进来会被立刻掐断，不暴露本机文件。
        guard isLoopback(connection.endpoint) else {
            connection.cancel()
            return
        }
        connection.start(queue: queue)
        readRequest(on: connection, accumulated: Data())
    }

    /// 判断连接对端是否来自 127.0.0.1 / ::1。
    private func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else {
            return false
        }
        switch host {
        case let .ipv4(address):
            guard let loopback = IPv4Address("127.0.0.1") else { return false }
            return address.rawValue == loopback.rawValue
        case let .ipv6(address):
            guard let loopback = IPv6Address("::1") else { return false }
            return address.rawValue == loopback.rawValue
        case .name:
            return true // 回环场景下 WebKit 传入的是 IP，名字兜底放行
        @unknown default:
            return false
        }
    }

    private func readRequest(on connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] chunk, _, isComplete, error in
            guard let self = self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }

            var buffer = accumulated
            if let chunk {
                buffer.append(chunk)
            }

            if let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) {
                let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
                let headerText = String(decoding: headerData, as: UTF8.self)
                self.respond(to: headerText, on: connection)
                return
            }

            if isComplete || buffer.count > self.maxHeaderBytes {
                connection.cancel()
                return
            }

            self.readRequest(on: connection, accumulated: buffer)
        }
    }

    private func respond(to headerText: String, on connection: NWConnection) {
        let lines = headerText.split(separator: "\r\n", omittingEmptySubsequences: true)
        guard let requestLine = lines.first else {
            send(status: 400, reason: "Bad Request", mime: "text/plain; charset=utf-8",
                 body: Data("Bad Request".utf8), on: connection)
            return
        }

        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else {
            send(status: 400, reason: "Bad Request", mime: "text/plain; charset=utf-8",
                 body: Data("Bad Request".utf8), on: connection)
            return
        }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])

        if method == "OPTIONS" {
            send(status: 204, reason: "No Content", mime: "text/plain; charset=utf-8",
                 body: Data(), on: connection)
            return
        }

        guard method == "GET" || method == "HEAD" else {
            send(status: 405, reason: "Method Not Allowed", mime: "text/plain; charset=utf-8",
                 body: Data("Method Not Allowed".utf8), on: connection)
            return
        }

        guard let fileURL = WebAssetLocator.fileURL(forRelativePath: target),
              let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
            let body = Data("404 Not Found: \(target)".utf8)
            send(status: 404, reason: "Not Found", mime: "text/plain; charset=utf-8",
                 body: body, on: connection)
            return
        }

        let mime = WebAssetLocator.mimeType(forExtension: fileURL.pathExtension)
        let body = method == "HEAD" ? Data() : data
        send(status: 200, reason: "OK", mime: mime, body: body,
             extraHeaders: ["Content-Length": String(data.count)], on: connection)
    }

    private func send(
        status: Int,
        reason: String,
        mime: String,
        body: Data,
        extraHeaders: [String: String] = [:],
        on connection: NWConnection
    ) {
        var headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": String(body.count),
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
            "Access-Control-Allow-Headers": "*",
            "Cache-Control": "no-cache",
            "Connection": "close",
            "X-Content-Type-Options": "nosniff",
        ]
        for (key, value) in extraHeaders {
            headers[key] = value
        }

        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        // 固定顺序输出，便于抓包时肉眼对齐
        for key in headers.keys.sorted() {
            head += "\(key): \(headers[key] ?? "")\r\n"
        }
        head += "\r\n"

        var payload = Data(head.utf8)
        payload.append(body)

        connection.send(content: payload, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }
}
