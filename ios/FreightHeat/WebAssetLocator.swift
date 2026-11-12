//
//  WebAssetLocator.swift
//  FreightHeat
//
//  统一的资源定位器：本地 HTTP 服务（默认通道）与 WKURLSchemeHandler（兜底通道）
//  共用同一套「URL 路径 → Bundle/www 内的文件」映射规则，避免两条通道各自
//  实现路径拼接导致行为不一致（例如一处能取到 geo json，另一处 404）。
//

import Foundation

/// Web 资源的磁盘定位与 MIME 判定。
enum WebAssetLocator {

    /// 打进 App Bundle 的 Web 根目录名（XcodeGen 以 folder reference 形式引入 ios/www）。
    static let folderName = "www"

    /// 入口文件。
    static let entryFileName = "index.html"

    /// 兜底通道使用的自定义 scheme。
    static let schemeName = "appassets"

    /// 兜底通道使用的 host（`appassets://local/index.html`）。
    static let schemeHost = "local"

    /// Web 资源根目录；未打包进 www 时返回 nil，便于上层给出明确的错误页。
    static var rootDirectory: URL? {
        guard let resourceURL = Bundle.main.resourceURL else { return nil }
        let directory = resourceURL.appendingPathComponent(folderName, isDirectory: true)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return nil
        }
        return directory.standardizedFileURL
    }

    /// 把请求里的相对路径（已百分号编码）解析成磁盘文件 URL。
    /// - Parameter rawPath: 形如 `/index.html`、`geo/110000.json`、`/`。
    /// - Returns: 校验通过且真实存在的文件 URL；越界、目录、缺失一律返回 nil。
    static func fileURL(forRelativePath rawPath: String) -> URL? {
        guard let root = rootDirectory else { return nil }

        var path = rawPath
        // 去掉 query 与 fragment（scheme handler 拿到的 path 通常已经干净，
        // 但 HTTP 通道需要自己裁）
        if let cut = path.firstIndex(where: { $0 == "?" || $0 == "#" }) {
            path = String(path[path.startIndex..<cut])
        }
        if let decoded = path.removingPercentEncoding {
            path = decoded
        }
        while path.hasPrefix("/") {
            path.removeFirst()
        }
        if path.isEmpty {
            path = entryFileName
        }
        if path.hasSuffix("/") {
            path += entryFileName
        }
        // 目录穿越防护：本项目不存在需要 `..` 的合法资源
        if path.contains("..") {
            return nil
        }

        let candidate = root.appendingPathComponent(path).standardizedFileURL
        guard candidate.path == root.path || candidate.path.hasPrefix(root.path + "/") else {
            return nil
        }

        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
              !isDirectory.boolValue else {
            return nil
        }
        return candidate
    }

    /// 读取资源内容；大文件用 mappedIfSafe 避免整块拷进堆内存。
    static func data(forRelativePath path: String) -> Data? {
        guard let fileURL = fileURL(forRelativePath: path) else { return nil }
        return try? Data(contentsOf: fileURL, options: .mappedIfSafe)
    }

    /// 扩展名 → Content-Type。iOS 上是本地资源，charset 一律按 UTF-8 声明。
    static func mimeType(forExtension pathExtension: String) -> String {
        switch pathExtension.lowercased() {
        case "html", "htm":
            return "text/html; charset=utf-8"
        case "css":
            return "text/css; charset=utf-8"
        case "js", "mjs":
            return "text/javascript; charset=utf-8"
        case "json", "geojson":
            return "application/json; charset=utf-8"
        case "webmanifest", "manifest":
            return "application/manifest+json; charset=utf-8"
        case "svg":
            return "image/svg+xml"
        case "png":
            return "image/png"
        case "jpg", "jpeg":
            return "image/jpeg"
        case "webp":
            return "image/webp"
        case "gif":
            return "image/gif"
        case "woff2":
            return "font/woff2"
        case "woff":
            return "font/woff"
        case "ttf":
            return "font/ttf"
        case "otf":
            return "font/otf"
        case "ico":
            return "image/x-icon"
        case "txt", "md":
            return "text/plain; charset=utf-8"
        default:
            return "application/octet-stream"
        }
    }

    /// 兜底通道的入口 URL：`appassets://local/index.html`。
    static var schemeEntryURL: URL? {
        URL(string: "\(schemeName)://\(schemeHost)/\(entryFileName)")
    }
}
