//
//  WebView.swift
//  FreightHeat
//
//  WKWebView 容器与壳工程的全部平台桥接：
//    * 选择加载通道（回环 http 优先，自定义 scheme 兜底）
//    * 把原生安全区回传给页面（--ios-safe-*），双保险防止顶栏压到刘海
//    * 承接页面「导出 JSON」的 Blob 下载（WKWebView 不会自己落盘），改走系统分享
//    * 关闭 WKWebView 默认的双指缩放与橡皮筋，手势完全交给页面
//
//  这里不解析、不修改任何业务数据，只做平台能力转发。
//

import SwiftUI
import UIKit
import WebKit

// MARK: - 兜底通道下注入口的弱引用消息代理

/// WKUserContentController 会强引用 messageHandler，直接传 self 会与 WebSession 形成
/// 循环引用（WebSession → webView → configuration → userContentController → self）。
private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
    }

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        target?.userContentController(userContentController, didReceive: message)
    }
}

// MARK: - 关闭系统手势的 WKWebView

/// 页面自己实现了长按下钻、单指拖拽面板，系统级手势必须让位：
/// WKWebView 会忽略 viewport 里的 `user-scalable=no`，双指缩放只能用原生关掉。
final class SafeAreaWebView: WKWebView {

    /// 安全区变化回调（点单位，与 CSS px 1:1）。
    var onSafeAreaChange: ((UIEdgeInsets) -> Void)?

    override func safeAreaInsetsDidChange() {
        super.safeAreaInsetsDidChange()
        onSafeAreaChange?(safeAreaInsets)
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        applyGestureRestrictions()
        onSafeAreaChange?(safeAreaInsets)
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        applyGestureRestrictions()
    }

    private func applyGestureRestrictions() {
        scrollView.pinchGestureRecognizer?.isEnabled = false
        scrollView.bounces = false
        scrollView.alwaysBounceVertical = false
        scrollView.alwaysBounceHorizontal = false
        scrollView.contentInsetAdjustmentBehavior = .never
        scrollView.showsVerticalScrollIndicator = false
        scrollView.showsHorizontalScrollIndicator = false
        // 列表自己滚动，主滚动视图不需要惯性滚动
        scrollView.delaysContentTouches = false
    }
}

// MARK: - WebSession

/// 管理 WKWebView 的一次性创建、资源通道选择、导航回调与导出桥。
final class WebSession: NSObject, ObservableObject {

    /// 页面资源通道。
    enum Channel: String {
        case loopback = "loopback-http"
        case scheme = "custom-scheme"
        case failed = "failed"
    }

    @Published private(set) var isReady = false
    @Published private(set) var channel: Channel = .failed
    @Published private(set) var failureMessage: String?

    let webView: WKWebView

    private var server: LocalHTTPServer?
    private var schemeHandler: AssetSchemeHandler?
    private var hasStarted = false
    private var messageProxies: [WeakScriptMessageHandler] = []

    private static let background = UIColor(red: 7 / 255, green: 20 / 255, blue: 38 / 255, alpha: 1)

    override init() {
        let configuration = WKWebViewConfiguration()

        // 网页配置
        configuration.websiteDataStore = .default()
        configuration.allowsInlineMediaPlayback = true
        configuration.mediaTypesRequiringUserActionForPlayback = []
        configuration.suppressesIncrementalRendering = true
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences.preferredContentMode = .mobile
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false

        // 兜底通道：appassets://local/*
        let schemeHandler = AssetSchemeHandler()
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: WebAssetLocator.schemeName)

        // 导出桥：拦截 <a download> 的 Blob 下载，转成系统分享
        let exportScript = WKUserScript(
            source: WebSession.exportBridgeScript,
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true
        )
        configuration.userContentController.addUserScript(exportScript)

        let webView = SafeAreaWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = WebSession.background
        webView.scrollView.backgroundColor = WebSession.background
        if #available(iOS 15.0, *) {
            webView.underPageBackgroundColor = WebSession.background
        }
        webView.allowsBackForwardNavigationGestures = false
        webView.allowsLinkPreview = false

        self.webView = webView
        self.schemeHandler = schemeHandler

        super.init()

        webView.navigationDelegate = self
        webView.uiDelegate = self

        // 消息通道：iosBridge 仅用于让页面识别「运行在壳里」（添加 ios-shell class）
        for name in ["iosBridge", "exportFile"] {
            let proxy = WeakScriptMessageHandler(target: self)
            messageProxies.append(proxy)
            configuration.userContentController.add(proxy, name: name)
        }

        webView.onSafeAreaChange = { [weak self] insets in
            self?.pushSafeAreaInsets(insets)
        }
    }

    deinit {
        server?.stop()
    }

    // MARK: - 启动

    /// 首次挂载时调用；重复调用无副作用。
    func start() {
        guard !hasStarted else { return }
        hasStarted = true

        guard let root = WebAssetLocator.rootDirectory else {
            channel = .failed
            failureMessage = "App 包内缺少 www/ 资源目录。请先在 ios/ 目录执行 bash build_www.sh，再用 Xcode 重新构建。"
            loadBlankErrorPage()
            return
        }

        // 首选：回环 http（真实源，localStorage / fetch / SW 全部可用）
        let server = LocalHTTPServer(rootDirectory: root)
        if server.start(), let url = server.entryURL {
            self.server = server
            channel = .loopback
            webView.load(URLRequest(url: url))
            return
        }
        server.stop()

        // 兜底：自定义 scheme（只保证页面能显示）
        guard let fallbackURL = WebAssetLocator.schemeEntryURL else {
            channel = .failed
            failureMessage = "既无法启动本地资源服务，也无法构造 appassets:// 地址。"
            loadBlankErrorPage()
            return
        }
        channel = .scheme
        webView.load(URLRequest(url: fallbackURL))
    }

    // MARK: - 安全区回传

    private func pushSafeAreaInsets(_ insets: UIEdgeInsets) {
        let script = String(
            format: "window.__iosApplySafeArea && window.__iosApplySafeArea(%.2f, %.2f, %.2f, %.2f);",
            Double(insets.top),
            Double(insets.bottom),
            Double(insets.left),
            Double(insets.right)
        )
        webView.evaluateJavaScript(script, completionHandler: nil)
    }

    // MARK: - 导出

    /// 页面把导出内容以文本形式交上来，这里落盘成文件再走系统分享
    /// （「存储到文件」/「AirDrop」/「微信」都能直接收到 JSON）。
    private func handleExportFile(name: String, text: String) {
        let fileName = sanitizedFileName(name)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FreightHeatExport", isDirectory: true)

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let fileURL = directory.appendingPathComponent(fileName)
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            presentShareSheet(for: fileURL, in: directory)
        } catch {
            failureMessage = "导出失败：\(error.localizedDescription)"
        }
    }

    private func sanitizedFileName(_ raw: String) -> String {
        let illegal = CharacterSet(charactersIn: "/\\:?%*|\"<>")
        let cleaned = raw.components(separatedBy: illegal).joined(separator: "-")
        let trimmed = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "freight-heat-export.json"
        }
        return trimmed.hasSuffix(".json") ? trimmed : trimmed + ".json"
    }

    private func presentShareSheet(for fileURL: URL, in directory: URL) {
        DispatchQueue.main.async { [weak self] in
            guard let presenter = WebSession.topViewController() else {
                self?.failureMessage = "找不到可用于分享的界面。"
                return
            }

            let controller = UIActivityViewController(activityItems: [fileURL], applicationActivities: nil)
            if let popover = controller.popoverPresentationController {
                popover.sourceView = presenter.view
                popover.sourceRect = CGRect(
                    x: presenter.view.bounds.midX,
                    y: presenter.view.bounds.midY,
                    width: 0,
                    height: 0
                )
                popover.permittedArrowDirections = []
            }
            controller.completionWithItemsHandler = { _, _, _, _ in
                // 分享结束后清掉临时文件，避免占空间
                try? FileManager.default.removeItem(at: directory)
            }
            presenter.present(controller, animated: true)
        }
    }

    /// 取当前最顶层的 ViewController，用于呈现系统分享面板。
    private static func topViewController() -> UIViewController? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let keyWindow = scenes
            .flatMap { $0.windows }
            .first { $0.isKeyWindow } ?? scenes.first?.windows.first

        guard var top = keyWindow?.rootViewController else { return nil }
        while let presented = top.presentedViewController {
            top = presented
        }
        return top
    }

    // MARK: - 错误页

    private func loadBlankErrorPage() {
        let message = failureMessage ?? "未知错误"
        let html = """
        <!DOCTYPE html><html lang="zh-CN"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
        <style>
        :root{color-scheme:dark}
        body{margin:0;min-height:100vh;display:flex;align-items:center;justify-content:center;
        background:#071426;color:#E8EEF8;font:15px/1.7 -apple-system,"PingFang SC",sans-serif;padding:24px;
        padding-top:calc(24px + env(safe-area-inset-top));padding-bottom:calc(24px + env(safe-area-inset-bottom));}
        .box{max-width:420px;background:rgba(255,255,255,.06);border:1px solid rgba(255,255,255,.12);
        border-radius:16px;padding:20px}
        h1{font-size:16px;margin:0 0 10px;font-weight:600}
        p{margin:0;color:#A9B6C9;font-size:13px}
        </style></head><body><div class="box"><h1>资源未就绪</h1><p>\(message)</p></div></body></html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }

    // MARK: - 注入脚本

    /// 拦截页面里 `URL.createObjectURL(blob) + a.download` 的导出写法。
    /// WKWebView 不会为 Blob 触发系统下载，这里把文本转交原生，落盘后弹分享面板。
    private static let exportBridgeScript = """
    (function () {
      if (!window.webkit || !window.webkit.messageHandlers || !window.webkit.messageHandlers.exportFile) return;
      var nativeClick = HTMLAnchorElement.prototype.click;
      HTMLAnchorElement.prototype.click = function () {
        var anchor = this;
        try {
          var href = anchor.getAttribute('href') || '';
          var wantsDownload = anchor.hasAttribute('download');
          if (wantsDownload && href.indexOf('blob:') === 0) {
            var name = anchor.getAttribute('download') || 'freight-heat-export.json';
            fetch(href).then(function (response) { return response.text(); }).then(function (text) {
              window.webkit.messageHandlers.exportFile.postMessage({ name: name, text: text });
            }).catch(function () { nativeClick.call(anchor); });
            return;
          }
        } catch (error) {
          /* 任何异常都退回浏览器默认行为，不影响页面本身 */
        }
        return nativeClick.call(anchor);
      };
    })();
    """
}

// MARK: - WKNavigationDelegate

extension WebSession: WKNavigationDelegate {

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        isReady = true
        failureMessage = nil
        pushSafeAreaInsets(webView.safeAreaInsets)
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        failureMessage = "页面加载失败：\(error.localizedDescription)"
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        failureMessage = "页面加载失败：\(error.localizedDescription)"
    }

    /// 站内资源放行，站外链接交给 Safari，避免把浏览器窗口困在壳里。
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }

        switch url.scheme?.lowercased() {
        case "http", "https":
            let host = url.host?.lowercased() ?? ""
            let isLocal = host == "127.0.0.1" || host == "localhost" || host == "::1"
            if isLocal {
                decisionHandler(.allow)
            } else {
                UIApplication.shared.open(url)
                decisionHandler(.cancel)
            }
        case WebAssetLocator.schemeName, "about", "data", "blob":
            decisionHandler(.allow)
        default:
            UIApplication.shared.open(url)
            decisionHandler(.cancel)
        }
    }
}

// MARK: - WKUIDelegate

extension WebSession: WKUIDelegate {

    /// target=_blank / window.open：一律用 Safari 打开（本页面本身不需要新窗口）。
    func webView(
        _ webView: WKWebView,
        createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction,
        windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if let url = navigationAction.request.url {
            UIApplication.shared.open(url)
        }
        return nil
    }
}

// MARK: - WKScriptMessageHandler

extension WebSession: WKScriptMessageHandler {

    func userContentController(
        _ userContentController: WKUserContentController,
        didReceive message: WKScriptMessage
    ) {
        switch message.name {
        case "exportFile":
            guard let payload = message.body as? [String: Any],
                  let text = payload["text"] as? String else {
                return
            }
            let name = (payload["name"] as? String) ?? "freight-heat-export.json"
            handleExportFile(name: name, text: text)
        case "iosBridge":
            // 页面启动握手：仅用于打点，无业务副作用
            break
        default:
            break
        }
    }
}

// MARK: - SwiftUI 包装

/// 把 WebSession 持有的 WKWebView 挂进 SwiftUI 视图树。
struct WebView: UIViewRepresentable {

    @ObservedObject var session: WebSession

    func makeUIView(context: Context) -> WKWebView {
        session.start()
        return session.webView
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        // 页面自身状态由 Web 层维护，无需 SwiftUI 驱动更新
    }
}
