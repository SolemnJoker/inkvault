import Foundation
import UIKit
import WebKit

/// 渲染条目种类。
enum DiagramKind: String {
    case mermaid
    case math        // 行内公式 $...$
    case mathblock   // 独立公式 $$...$$
}

/// 一次渲染的结果。
struct DiagramResult {
    var image: UIImage
    var size: CGSize     // 原生像素尺寸（points @1x）
    var error: String?
}

/// Mermaid/KaTeX 离屏渲染引擎（D-01 唯一例外）。
///
/// 功耗与生命周期纪律：
/// - WKWebView 仅在渲染会话期间存在；空闲 10 秒或退后台即整体销毁，不常驻
/// - JS/样式全部来自本地 bundle，渲染过程零网络（US-03）
/// - 成品位图进 NSCache（内存压力自动淘汰），同一内容复用快照
final class DiagramRenderEngine: NSObject {
    static let shared = DiagramRenderEngine()

    struct Request {
        var kind: DiagramKind
        var code: String
        var itemID: String
        var completion: (DiagramResult) -> Void
    }

    private var webView: WKWebView?
    private var pageReady = false
    private var queue: [Request] = []
    private var processing = false
    private var idleTimer: Timer?
    private let cache = NSCache<NSString, UIImage>()

    static let idleTeardownSeconds: TimeInterval = 10

    private override init() {
        super.init()
        cache.countLimit = 80
    }

    // MARK: - 公开接口

    /// 渲染一段 Mermaid / KaTeX。completion 在主线程回调。
    func render(kind: DiagramKind, code: String, itemID: String, completion: @escaping (DiagramResult) -> Void) {
        let cacheKey = "\(kind.rawValue)|\(code)" as NSString
        if let cached = cache.object(forKey: cacheKey) {
            completion(DiagramResult(image: cached, size: cached.size, error: nil))
            scheduleTeardown()
            return
        }
        cancelTeardown()
        queue.append(Request(kind: kind, code: code, itemID: itemID) { [weak self] result in
            if result.error == nil, result.size.width > 1 {
                self?.cache.setObject(result.image, forKey: cacheKey)
            }
            completion(result)
        })
        ensureWebView()
    }

    /// 立即销毁引擎（退后台 / 手动调用，D-05/D-01）。
    func tearDown() {
        cancelTeardown()
        queue.removeAll()
        processing = false
        pageReady = false
        webView?.stopLoading()
        webView?.loadHTMLString("", baseURL: nil)
        webView?.removeFromSuperview()
        webView = nil
    }

    var isEngineAlive: Bool { webView != nil }

    // MARK: - 内部

    private func cancelTeardown() {
        idleTimer?.invalidate()
        idleTimer = nil
    }

    private func scheduleTeardown() {
        cancelTeardown()
        guard queue.isEmpty, !processing else { return }
        let timer = Timer(timeInterval: Self.idleTeardownSeconds, repeats: false) { [weak self] _ in
            DispatchQueue.main.async { self?.tearDown() }
        }
        RunLoop.main.add(timer, forMode: .default)
        idleTimer = timer
    }

    private func ensureWebView() {
        guard webView == nil else { return }
        guard let htmlURL = Bundle.main.url(forResource: "render", withExtension: "html", subdirectory: "renderer") else {
            // 资源缺失：直接完成所有请求，标记错误
            let pending = queue; queue.removeAll()
            for r in pending {
                r.completion(DiagramResult(image: UIImage(), size: .zero, error: "渲染资源缺失"))
            }
            return
        }
        let config = WKWebViewConfiguration()
        let wv = WKWebView(frame: CGRect(x: 0, y: 0, width: 500, height: 200), configuration: config)
        wv.isOpaque = false
        wv.scrollView.isScrollEnabled = false
        wv.backgroundColor = .clear
        wv.navigationDelegate = self
        webView = wv
        pageReady = false
        // 允许读取 bundle 内 renderer 目录（本地字体/JS，零网络）
        let scope = htmlURL.deletingLastPathComponent()
        wv.loadFileURL(htmlURL, allowingReadAccessTo: scope)
    }

    private func drain() {
        guard !processing, let req = queue.first else {
            if queue.isEmpty { scheduleTeardown() }
            return
        }
        processing = true
        queue.removeFirst()
        guard pageReady, let wv = webView else {
            // 页面未就绪（可能刚被销毁）：重排队
            queue.insert(req, at: 0)
            processing = false
            ensureWebView()
            return
        }
        let payload: String
        if let data = try? JSONEncoder().encode(req.code), let s = String(data: data, encoding: .utf8) {
            payload = s
        } else {
            payload = "\"\""
        }
        let js = "renderItem('\(req.kind.rawValue)', \(payload))"
        wv.evaluateJavaScript(js) { [weak self] raw, error in
            guard let self else { return }
            if let error {
                self.finish(req: req, image: UIImage(), size: .zero, error: error.localizedDescription, webView: wv)
                return
            }
            guard let dict = raw as? [String: Any],
                  let ok = dict["ok"] as? Bool,
                  let w = dict["width"] as? CGFloat ?? (dict["width"] as? NSNumber)?.doubleValue,
                  let h = dict["height"] as? CGFloat ?? (dict["height"] as? NSNumber)?.doubleValue
            else {
                self.finish(req: req, image: UIImage(), size: .zero, error: "渲染输出异常", webView: wv)
                return
            }
            if !ok {
                let msg = dict["error"] as? String ?? "渲染失败"
                let img = Self.errorImage(width: min(640, w), height: max(28, h))
                self.finish(req: req, image: img, size: img.size, error: msg, webView: wv)
                return
            }
            // 调整 webview 尺寸后整页快照
            DispatchQueue.main.async {
                let width = min(max(4, w), 1400)
                let height = min(max(4, h), 4000)
                wv.frame = CGRect(x: 0, y: 0, width: width, height: height)
                let config = WKSnapshotConfiguration()
                config.rect = wv.bounds
                config.afterScreenUpdates = true
                wv.takeSnapshot(with: config) { image, _ in
                    let img = image ?? UIImage()
                    self.finish(req: req, image: img, size: img.size, error: nil, webView: wv)
                }
            }
        }
    }

    private func finish(req: Request, image: UIImage, size: CGSize, error: String?, webView: WKWebView) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.processing = false
            // 释放 JS 侧 DOM，控制内存
            webView.evaluateJavaScript("document.getElementById('out').innerHTML='';", completionHandler: nil)
            req.completion(DiagramResult(image: image, size: size, error: error))
            self.drain()
        }
    }

    private static func errorImage(width: CGFloat, height: CGFloat) -> UIImage {
        let size = CGSize(width: max(40, width), height: max(28, height))
        let renderer = UIGraphicsImageRenderer(size: size)
        return renderer.image { ctx in
            UIColor.systemRed.withAlphaComponent(0.08).setFill()
            ctx.fill(CGRect(origin: .zero, size: size))
            "公式渲染失败".draw(
                at: CGPoint(x: 8, y: 6),
                withAttributes: [.font: UIFont.systemFont(ofSize: 12), .foregroundColor: UIColor.systemRed]
            )
        }
    }
}

extension DiagramRenderEngine: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageReady = true
        drain()
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        pageReady = false
        webView.stopLoading()
        // 允许下次渲染时重建（避免死 webview 卡住队列）
        if self.webView === webView {
            self.webView = nil
        }
    }
}
