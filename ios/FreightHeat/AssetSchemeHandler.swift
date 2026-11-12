//
//  AssetSchemeHandler.swift
//  FreightHeat
//
//  兜底通道：用自定义 scheme `appassets://local/<path>` 从 App Bundle 的 www/ 读取
//  index.html、geo/*.json、字体与图片。
//
//  为什么需要它：默认走 LocalHTTPServer（真实 http 源，localStorage / fetch 才完整可用）。
//  当回环端口被占用或 Network.framework 初始化失败时，WebSession 会退到本通道，
//  保证「至少能把页面显示出来」。该通道下 localStorage 不可用（opaque origin），
//  因此仅作为降级方案，README 中有说明。
//

import Foundation
import WebKit

/// 从 Bundle/www 读取资源的 WKURLSchemeHandler。
final class AssetSchemeHandler: NSObject, WKURLSchemeHandler {

    /// 已停止的任务：WKURLSchemeTask 在 stop 之后再调用任何方法都会抛异常，
    /// 而 Swift 捕获不到 ObjC 异常，所以只能自己记账跳过。
    private let lock = NSLock()
    private var stoppedTasks = Set<ObjectIdentifier>()

    private let fileQueue = DispatchQueue(label: "com.freightheat.schemehandler", qos: .userInitiated)

    // MARK: - WKURLSchemeHandler

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        guard let url = urlSchemeTask.request.url else {
            finish(urlSchemeTask, status: 400, reason: "Bad Request",
                   mime: "text/plain; charset=utf-8", body: Data("Bad Request".utf8), for: nil)
            return
        }

        let relativePath = url.path

        fileQueue.async { [weak self] in
            guard let self = self else { return }
            if self.isStopped(urlSchemeTask) { return }

            guard let fileURL = WebAssetLocator.fileURL(forRelativePath: relativePath),
                  let data = try? Data(contentsOf: fileURL, options: .mappedIfSafe) else {
                self.finish(
                    urlSchemeTask,
                    status: 404,
                    reason: "Not Found",
                    mime: "text/plain; charset=utf-8",
                    body: Data("404 Not Found: \(relativePath)".utf8),
                    for: url
                )
                return
            }

            let mime = WebAssetLocator.mimeType(forExtension: fileURL.pathExtension)
            self.finish(urlSchemeTask, status: 200, reason: "OK", mime: mime, body: data, for: url)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {
        lock.lock()
        stoppedTasks.insert(ObjectIdentifier(urlSchemeTask))
        lock.unlock()
    }

    // MARK: - 内部

    private func isStopped(_ task: WKURLSchemeTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return stoppedTasks.contains(ObjectIdentifier(task))
    }

    /// 统一回包：设置 Content-Type / 长度 / CORS，让页面里的 fetch 与字体加载都不受限。
    private func finish(
        _ task: WKURLSchemeTask,
        status: Int,
        reason: String,
        mime: String,
        body: Data,
        for url: URL?
    ) {
        guard let responseURL = url ?? task.request.url else { return }

        let headers: [String: String] = [
            "Content-Type": mime,
            "Content-Length": String(body.count),
            "Access-Control-Allow-Origin": "*",
            "Access-Control-Allow-Methods": "GET, HEAD, OPTIONS",
            "Access-Control-Allow-Headers": "*",
            "Cache-Control": "no-cache",
            "X-Content-Type-Options": "nosniff",
        ]

        guard let response = HTTPURLResponse(
            url: responseURL,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: headers
        ) else {
            return
        }

        // WKURLSchemeTask 必须在主线程回调
        DispatchQueue.main.async { [weak self] in
            guard let self = self, !self.isStopped(task) else { return }
            task.didReceive(response)
            task.didReceive(body)
            task.didFinish()

            // 任务结束后回收记账，避免集合随导航次数无限增长
            self.lock.lock()
            self.stoppedTasks.remove(ObjectIdentifier(task))
            self.lock.unlock()
        }
    }
}
