import AppKit
import CookbookWebKit
import Foundation
import WebKit

/// One offscreen WKWebView. Several can capture different spine files at once.
@MainActor
final class WebKitSpineWorker: NSObject, WKNavigationDelegate {
    let id: Int
    private let paper: NSSize
    private let cssFont: CGFloat
    private let css: String
    private var window: NSWindow?
    private var webView: WKWebView?
    private var navWait: CheckedContinuation<Void, Error>?
    private var pager: Pager = .css
    private var paintHookWorks = true
    private var cancelled = false
    private var loadGen = 0

    private enum Pager {
        case engine(rtl: Bool, originX: CGFloat, delta: CGFloat)
        case css
    }

    private enum PaginationMode: Int {
        case unpaginated = 0
        case leftToRight = 1
        case rightToLeft = 2
        case topToBottom = 3
        case bottomToTop = 4
    }

    init(id: Int, paper: NSSize, css: String, cssFont: CGFloat) {
        self.id = id
        self.paper = paper
        self.css = css
        self.cssFont = cssFont
        super.init()
        prepareView()
    }

    func cancel() {
        cancelled = true
        webView?.stopLoading()
        failNav(WebKitConvertError.cancelled)
    }

    func tearDown() {
        webView?.navigationDelegate = nil
        webView = nil
        window?.contentView = nil
        window?.close()
        window = nil
        navWait = nil
    }

    func captureJob(
        _ job: WebKitPrintJob,
        limit: Int,
        pack: XtchPacker.Options?,
        gate: RasterGate?,
        onLog: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws -> [Data] {
        if shouldCancel() || cancelled { throw WebKitConvertError.cancelled }
        let label = job.url.lastPathComponent
        let tJob = Date()
        webView?.frame = NSRect(origin: .zero, size: paper)
        window?.setContentSize(paper)
        let tLoad = Date()
        do {
            try await loadJob(job)
        } catch {
            onLog("[v\(id)] load failed \(label): \(error.localizedDescription)")
            throw error
        }
        await promoteEpubCSS()
        let loadMs = WebKitLog.fmt(tLoad)
        if cancelled || shouldCancel() { throw WebKitConvertError.cancelled }
        pager = .css
        let tLayout = Date()
        let metrics: Metrics
        do {
            metrics = try await prepareLayout()
        } catch {
            onLog("[v\(id)] layout failed \(label): \(error.localizedDescription)")
            throw error
        }
        let layoutMs = WebKitLog.fmt(tLayout)
        if cancelled { throw WebKitConvertError.cancelled }
        var n = min(2000, max(1, metrics.pages))
        if limit > 0 { n = min(n, limit) }
        let axis = metrics.vertical ? (metrics.rtl ? "vertical-rl" : "vertical-lr") : "horizontal"
        let how: String
        switch pager {
        case .engine: how = "Books"
        case .css: how = "css"
        }
        onLog("[v\(id)] \(label) load \(loadMs)  layout \(layoutMs)  \(how) \(axis) \(Int(metrics.width))×\(Int(metrics.height)) → \(n) page\(n == 1 ? "" : "s")")
        let needsShow: Bool
        if case .css = pager { needsShow = true } else { needsShow = false }
        let tCap = Date()
        if !needsShow, let webView {
            await afterPaint(webView)
        }
        if pack != nil { gate?.beginCapture() }
        let inflight = pack != nil ? BackgroundPages(count: n) : nil
        var pdfPages: [Data] = []
        if pack == nil { pdfPages.reserveCapacity(n) }
        do {
            for i in 0..<n {
                if cancelled || shouldCancel() { throw WebKitConvertError.cancelled }
                if needsShow {
                    try await showPage(i, waitForPaint: i == 0)
                }
                let tPage = Date()
                let rect = pdfDocumentRect(start: i, count: 1)
                let data: Data
                do {
                    data = try await capturePDFPage(rect: rect)
                } catch {
                    onLog("[v\(id)] \(label) capture page \(i + 1)/\(n) failed in \(WebKitLog.fmt(tPage)): \(error.localizedDescription) rect=\(Int(rect.origin.x)),\(Int(rect.origin.y)) \(Int(rect.width))×\(Int(rect.height))")
                    throw WebKitConvertError.failed("\(label) page \(i + 1)/\(n): \(error.localizedDescription)")
                }
                if let pack, let inflight {
                    let g = gate
                    Task.detached {
                        do {
                            let body: Data
                            if let g {
                                body = try await g.withRaster {
                                    try XtchPacker.pageBody(fromPDF: data, options: pack)
                                }
                            } else {
                                body = try XtchPacker.pageBody(fromPDF: data, options: pack)
                            }
                            inflight.put(i, body)
                        } catch {
                            inflight.fail(error)
                        }
                    }
                } else {
                    pdfPages.append(data)
                }
                if i == 0 || i + 1 == n || i % 16 == 15 {
                    onLog("[v\(id)] \(label) page \(i + 1)/\(n)  \(WebKitLog.fmt(tCap))  \(WebKitLog.perPage(i + 1, tCap))  snap \(WebKitLog.bytes(data.count))")
                }
                if i % 8 == 7 { await Task.yield() }
            }
        } catch {
            inflight?.fail(error)
            if pack != nil { gate?.endCapture() }
            throw error
        }
        if pack != nil { gate?.endCapture() }
        let pages: [Data]
        if let inflight {
            let tPack = Date()
            pages = try await inflight.result()
            onLog("[v\(id)] \(label) done  \(n) page\(n == 1 ? "" : "s")  load \(loadMs)  layout \(layoutMs)  capture \(WebKitLog.fmt(tCap))  pack-wait \(WebKitLog.fmt(tPack))  total \(WebKitLog.fmt(tJob))  \(WebKitLog.perPage(n, tCap))")
        } else {
            pages = pdfPages
            onLog("[v\(id)] \(label) done  \(n) page\(n == 1 ? "" : "s")  load \(loadMs)  layout \(layoutMs)  capture \(WebKitLog.fmt(tCap))  total \(WebKitLog.fmt(tJob))  \(WebKitLog.perPage(n, tCap))")
        }
        return pages
    }

    private func prepareView() {
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        let script = WKUserScript(
            source: WebKitConvertStyle.styleInjector(css),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        let wv = WKWebView(frame: NSRect(origin: .zero, size: paper), configuration: config)
        wv.navigationDelegate = self
        wv.cookbookSetWhiteBackground()
        let y = CGFloat(-12000 - id * 80)
        let win = NSWindow(
            contentRect: NSRect(x: -12000, y: y, width: paper.width, height: paper.height),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false)
        win.isReleasedWhenClosed = false
        win.isOpaque = true
        win.backgroundColor = .white
        win.contentView = wv
        win.orderBack(nil)
        window = win
        webView = wv
    }

    private func loadJob(_ job: WebKitPrintJob) async throws {
        if EpubBook.imageTypes.contains(job.mediaType) {
            let html = WebKitConvertStyle.wrapImage(job.url)
            try await load(html, accessRoot: job.accessRoot)
        } else {
            try await load(job.url, accessRoot: job.accessRoot)
        }
    }

    private struct Metrics {
        var vertical: Bool
        var rtl: Bool
        var width: CGFloat
        var height: CGFloat
        var pages: Int
    }

    private func prepareLayout() async throws -> Metrics {
        guard let webView else {
            return Metrics(vertical: false, rtl: false, width: 1, height: 1, pages: 1)
        }
        let writing = try await detectWritingMode(webView)
        await pinFontSize(webView)
        await waitForFonts(webView)
        if webView.cookbookHasPagination() {
            if let metrics = try await enableEnginePagination(webView, rtl: writing.rtl) {
                pager = .engine(rtl: writing.rtl, originX: metrics.originX, delta: metrics.delta)
                return Metrics(
                    vertical: writing.vertical, rtl: writing.rtl,
                    width: paper.width, height: paper.height, pages: metrics.pages)
            }
            disableEnginePagination(webView)
        }
        pager = .css
        return try await enableCSSFallback(webView, vertical: writing.vertical)
    }

    private func detectWritingMode(_ webView: WKWebView) async throws -> (vertical: Bool, rtl: Bool) {
        let js = """
        (function() {
          const root = document.documentElement;
          const body = document.body;
          if (!body) return { vertical: false, rtl: false };
          function promote(el) {
            if (!el || !el.classList) return;
            if (el.classList.contains('vrtl')) {
              el.style.setProperty('writing-mode', 'vertical-rl', 'important');
              el.style.setProperty('-webkit-writing-mode', 'vertical-rl', 'important');
            }
            if (el.classList.contains('hltr')) {
              el.style.setProperty('writing-mode', 'horizontal-tb', 'important');
              el.style.setProperty('-webkit-writing-mode', 'horizontal-tb', 'important');
            }
          }
          promote(root);
          promote(body);
          const classVrtl = root.classList.contains('vrtl') || body.classList.contains('vrtl')
            || !!document.querySelector('.vrtl');
          const classHltr = root.classList.contains('hltr') || body.classList.contains('hltr')
            || !!document.querySelector('.hltr');
          const cs = getComputedStyle(root);
          const wm = String(cs.writingMode || cs.webkitWritingMode || '').toLowerCase();
          const vertical = (classVrtl && !classHltr) || wm.indexOf('vertical') !== -1;
          const rtl = vertical ? wm.indexOf('vertical-lr') === -1 : cs.direction === 'rtl';
          root.style.margin = '0';
          root.style.padding = '0';
          body.style.margin = '0';
          body.style.padding = '0';
          return { vertical: vertical, rtl: rtl };
        })()
        """
        let raw = try await webView.evaluateJavaScript(js)
        let dict = raw as? [String: Any]
        return (
            vertical: (dict?["vertical"] as? Bool) ?? false,
            rtl: (dict?["rtl"] as? Bool) ?? false)
    }

    private func pinFontSize(_ webView: WKWebView) async {
        let px = WebKitConvertStyle.cssNumber(cssFont)
        let js = """
        (function() {
          const px = '\(px)px';
          const root = document.documentElement;
          const body = document.body;
          if (root) root.style.setProperty('font-size', px, 'important');
          if (body) body.style.setProperty('font-size', px, 'important');
          return true;
        })()
        """
        _ = try? await webView.evaluateJavaScript(js)
    }

    private struct EnginePages {
        var pages: Int
        var originX: CGFloat
        var delta: CGFloat
    }

    private func enableEnginePagination(
        _ webView: WKWebView, rtl: Bool
    ) async throws -> EnginePages? {
        let mode: PaginationMode = rtl ? .rightToLeft : .leftToRight
        webView.cookbookSetPaginationMode(
            mode.rawValue, pageLength: paper.width, gap: 0, likeColumns: true)
        await afterPaint(webView)
        _ = try? await webView.evaluateJavaScript(
            "document.documentElement && document.documentElement.offsetWidth")
        var engineCount = Int(webView.cookbookPageCount)
        var scroll = try await scrollMetrics(webView)
        var fromScroll = max(1, Int(ceil((scroll.width / max(scroll.clientWidth, 1)) - 1e-6)))
        if engineCount == 0 && fromScroll <= 1 {
            await afterPaint(webView)
            engineCount = Int(webView.cookbookPageCount)
            scroll = try await scrollMetrics(webView)
            fromScroll = max(1, Int(ceil((scroll.width / max(scroll.clientWidth, 1)) - 1e-6)))
        }
        if engineCount == 0 && fromScroll <= 1 {
            return nil
        }
        let pages = min(2000, max(engineCount, fromScroll, 1))
        let origin = scroll.left
        let delta = rtl ? -paper.width : paper.width
        _ = try? await scrollToX(webView, origin)
        return EnginePages(pages: pages, originX: origin, delta: delta)
    }

    private func disableEnginePagination(_ webView: WKWebView) {
        webView.cookbookSetPaginationMode(
            PaginationMode.unpaginated.rawValue, pageLength: 0, gap: 0, likeColumns: false)
    }

    private func enableCSSFallback(_ webView: WKWebView, vertical: Bool) async throws -> Metrics {
        let js = """
        (function() {
          const pageW = \(paper.width);
          const pageH = \(paper.height);
          const root = document.documentElement;
          const body = document.body;
          if (!body) return { vertical: false, rtl: false, width: pageW, height: pageH, pages: 1 };
          if (document.getElementById('cookbook-vp')) {
            return window.__cookbookMetrics || { vertical: false, rtl: false, width: pageW, height: pageH, pages: 1 };
          }
          const ns = body.namespaceURI || 'http://www.w3.org/1999/xhtml';
          function el(name) { return document.createElementNS(ns, name); }
          root.style.margin = '0';
          root.style.padding = '0';
          body.style.margin = '0';
          body.style.padding = '0';
          if (\(vertical ? "true" : "false")) {
            const vp = el('div');
            vp.id = 'cookbook-vp';
            vp.setAttribute('style',
              'box-sizing:border-box;position:relative;width:' + pageW + 'px;height:' + pageH + 'px;overflow:hidden;background:#fff;');
            const clip = el('div');
            clip.id = 'cookbook-clip';
            clip.setAttribute('style',
              'position:absolute;top:0;right:0;width:' + pageW + 'px;height:' + pageH + 'px;overflow:hidden;');
            const flow = el('div');
            flow.id = 'cookbook-flow';
            flow.setAttribute('style',
              'box-sizing:border-box;position:absolute;top:0;right:0;height:' + pageH + 'px;width:max-content;max-width:none;max-height:' + pageH + 'px;'
              + 'writing-mode:vertical-rl;-webkit-writing-mode:vertical-rl;margin:0;padding:0;transform-origin:top right;');
            while (body.firstChild) flow.appendChild(body.firstChild);
            clip.appendChild(flow);
            vp.appendChild(clip);
            body.appendChild(vp);
            root.style.setProperty('writing-mode', 'horizontal-tb', 'important');
            body.style.setProperty('writing-mode', 'horizontal-tb', 'important');
            void flow.offsetWidth;
            const w = Math.max(flow.scrollWidth || 0, flow.getBoundingClientRect().width || 0, pageW);
            const pages = Math.max(1, Math.ceil(w / pageW - 1e-6));
            window.__cookbookShow = function(i) {
              flow.style.transform = 'translateX(' + (i * pageW) + 'px)';
              void flow.offsetWidth;
            };
            window.__cookbookShow(0);
            const metrics = { vertical: true, rtl: true, width: w, height: pageH, pages: pages };
            window.__cookbookMetrics = metrics;
            return metrics;
          }
          body.style.boxSizing = 'border-box';
          body.style.width = pageW + 'px';
          body.style.height = pageH + 'px';
          body.style.overflow = 'hidden';
          body.style.columnWidth = pageW + 'px';
          body.style.webkitColumnWidth = pageW + 'px';
          body.style.columnGap = '0px';
          body.style.columnFill = 'auto';
          body.style.webkitColumnFill = 'auto';
          void body.offsetWidth;
          const w = Math.max(body.scrollWidth || 0, pageW);
          const pages = Math.max(1, Math.ceil(w / pageW - 1e-6));
          window.__cookbookShow = function(i) {
            body.style.transform = 'translateX(' + (-i * pageW) + 'px)';
            void body.offsetWidth;
          };
          window.__cookbookShow(0);
          const metrics = { vertical: false, rtl: false, width: w, height: pageH, pages: pages };
          window.__cookbookMetrics = metrics;
          return metrics;
        })()
        """
        let raw = try await webView.evaluateJavaScript(js)
        guard let dict = raw as? [String: Any] else {
            return Metrics(vertical: false, rtl: false, width: paper.width, height: paper.height, pages: 1)
        }
        let pages = (dict["pages"] as? NSNumber)?.intValue ?? 1
        return Metrics(
            vertical: (dict["vertical"] as? Bool) ?? false,
            rtl: (dict["rtl"] as? Bool) ?? false,
            width: CGFloat((dict["width"] as? NSNumber)?.doubleValue ?? Double(paper.width)),
            height: CGFloat((dict["height"] as? NSNumber)?.doubleValue ?? Double(paper.height)),
            pages: max(1, pages))
    }

    private func showPage(_ i: Int, waitForPaint: Bool) async throws {
        guard let webView else { return }
        switch pager {
        case .engine(_, let originX, let delta):
            _ = try? await scrollToX(webView, originX + CGFloat(i) * delta)
        case .css:
            _ = try? await webView.evaluateJavaScript("window.__cookbookShow(\(i))")
        }
        if waitForPaint { await afterPaint(webView) }
    }

    private func pdfDocumentRect(start: Int, count: Int) -> CGRect {
        let w = paper.width
        let h = paper.height
        let n = max(1, count)
        switch pager {
        case .engine(let rtl, _, _):
            if rtl {
                let x = CGFloat(start + n - 1) * -w
                return CGRect(x: x, y: 0, width: CGFloat(n) * w, height: h)
            }
            return CGRect(x: CGFloat(start) * w, y: 0, width: CGFloat(n) * w, height: h)
        case .css:
            return CGRect(origin: .zero, size: CGSize(width: w, height: h))
        }
    }

    private func capturePDFPage(rect: CGRect, timeoutSeconds: UInt64 = 20) async throws -> Data {
        guard let webView else { throw WebKitConvertError.failed("WebKit view is not ready") }
        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Data, Error>) in
            let lock = NSLock()
            var resumed = false
            func resumeOnce(_ result: Result<Data, Error>) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(with: result)
            }
            webView.cookbookCapturePDF(rect: rect) { data, error in
                if let data, error == nil {
                    resumeOnce(.success(data))
                } else {
                    resumeOnce(.failure(error ?? WebKitConvertError.failed("PDF snapshot failed")))
                }
            }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: timeoutSeconds * 1_000_000_000)
                resumeOnce(.failure(WebKitConvertError.failed("Timed out creating PDF page")))
            }
        }
    }

    private func promoteEpubCSS() async {
        guard let webView else { return }
        _ = try? await webView.evaluateJavaScript(WebKitConvertStyle.promoteEpubCSSJS)
    }

    private func afterPaint(_ webView: WKWebView) async {
        guard paintHookWorks else {
            await Task.yield()
            return
        }
        let fired = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            let lock = NSLock()
            var resumed = false
            func resumeOnce(_ value: Bool) {
                lock.lock()
                defer { lock.unlock() }
                guard !resumed else { return }
                resumed = true
                cont.resume(returning: value)
            }
            webView.cookbookOnNextPaint { resumeOnce(true) }
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 400_000_000)
                resumeOnce(false)
            }
        }
        if !fired { paintHookWorks = false }
    }

    private func waitForFonts(_ webView: WKWebView) async {
        let js = """
        if (document.fonts && document.fonts.ready) {
          await Promise.race([
            document.fonts.ready,
            new Promise(function(resolve) { setTimeout(resolve, 3000); })
          ]);
        }
        return true;
        """
        _ = try? await webView.callAsyncJavaScript(js, arguments: [:], in: nil, contentWorld: .page)
    }

    private struct ScrollMetrics {
        var left: CGFloat
        var width: CGFloat
        var clientWidth: CGFloat
    }

    private func scrollMetrics(_ webView: WKWebView) async throws -> ScrollMetrics {
        let js = """
        (function() {
          const se = document.scrollingElement || document.documentElement;
          return {
            left: se.scrollLeft || 0,
            width: se.scrollWidth || 0,
            clientWidth: se.clientWidth || window.innerWidth || 0
          };
        })()
        """
        let raw = try await webView.evaluateJavaScript(js)
        let dict = raw as? [String: Any]
        return ScrollMetrics(
            left: CGFloat((dict?["left"] as? NSNumber)?.doubleValue ?? 0),
            width: CGFloat((dict?["width"] as? NSNumber)?.doubleValue ?? 0),
            clientWidth: CGFloat((dict?["clientWidth"] as? NSNumber)?.doubleValue ?? 1))
    }

    private func scrollToX(_ webView: WKWebView, _ x: CGFloat) async throws -> Any? {
        let js = """
        (function() {
          const x = \(x);
          const se = document.scrollingElement || document.documentElement;
          se.scrollLeft = x;
          if (document.body) document.body.scrollLeft = x;
          window.scrollTo(x, 0);
          return se.scrollLeft;
        })()
        """
        return try await webView.evaluateJavaScript(js)
    }

    private func load(_ url: URL, accessRoot: URL) async throws {
        guard let webView else { throw WebKitConvertError.failed("WebKit view is not ready") }
        loadGen += 1
        let gen = loadGen
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.navWait = cont
                webView.loadFileURL(url, allowingReadAccessTo: accessRoot)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    guard self.loadGen == gen, self.navWait != nil else { return }
                    webView.stopLoading()
                    self.failNav(WebKitConvertError.failed("Timed out loading HTML (\(url.lastPathComponent))"))
                }
            }
        } catch {
            webView.stopLoading()
            throw error
        }
    }

    private func failNav(_ error: Error) {
        let cont = navWait
        navWait = nil
        cont?.resume(throwing: error)
    }

    nonisolated func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { @MainActor in
            let cont = navWait
            navWait = nil
            cont?.resume()
        }
    }

    nonisolated func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        Task { @MainActor in
            failNav(WebKitConvertError.failed("navigation failed: \(error.localizedDescription)"))
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        Task { @MainActor in
            failNav(WebKitConvertError.failed("provisional navigation failed: \(error.localizedDescription)"))
        }
    }

    nonisolated func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        Task { @MainActor in
            let scheme = navigationAction.request.url?.scheme?.lowercased() ?? ""
            if scheme == "file" || scheme == "about" || scheme == "data" || scheme.isEmpty {
                decisionHandler(.allow)
            } else {
                decisionHandler(.cancel)
            }
        }
    }
}

struct WebKitPrintJob {
    var url: URL
    var mediaType: String
    var accessRoot: URL
}

/// Collects background-packed XTCH page bodies in capture order.
private final class BackgroundPages: @unchecked Sendable {
    private let lock = NSLock()
    private var slots: [Data]
    private var left: Int
    private var error: Error?
    private var waiter: CheckedContinuation<[Data], Error>?

    init(count: Int) {
        slots = Array(repeating: Data(), count: count)
        left = count
    }

    func put(_ i: Int, _ data: Data) {
        lock.lock()
        defer { lock.unlock() }
        guard error == nil, i >= 0, i < slots.count else { return }
        slots[i] = data
        left -= 1
        finishLocked()
    }

    func fail(_ error: Error) {
        lock.lock()
        defer { lock.unlock() }
        if self.error == nil { self.error = error }
        left = 0
        finishLocked()
    }

    func result() async throws -> [Data] {
        try await withCheckedThrowingContinuation { cont in
            lock.lock()
            if let error {
                lock.unlock()
                cont.resume(throwing: error)
                return
            }
            if left <= 0 {
                let out = slots
                lock.unlock()
                cont.resume(returning: out)
                return
            }
            waiter = cont
            lock.unlock()
        }
    }

    private func finishLocked() {
        guard left <= 0, let waiter else { return }
        self.waiter = nil
        if let error {
            waiter.resume(throwing: error)
        } else {
            waiter.resume(returning: slots)
        }
    }
}

/// Limits 3× raster threads while a WKWebView is still capturing.
final class RasterGate: @unchecked Sendable {
    private let cond = NSCondition()
    private var capturing = 0
    private var rasters = 0
    private let cores: Int

    init() {
        cores = max(1, ProcessInfo.processInfo.activeProcessorCount)
    }

    func beginCapture() {
        cond.lock()
        capturing += 1
        cond.unlock()
    }

    func endCapture() {
        cond.lock()
        capturing = max(0, capturing - 1)
        cond.broadcast()
        cond.unlock()
    }

    func withRaster<T: Sendable>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .utility).async {
                self.cond.lock()
                while self.rasters >= self.limit() { self.cond.wait() }
                self.rasters += 1
                self.cond.unlock()
                do {
                    let result = try work()
                    self.cond.lock()
                    self.rasters -= 1
                    self.cond.signal()
                    self.cond.unlock()
                    cont.resume(returning: result)
                } catch {
                    self.cond.lock()
                    self.rasters -= 1
                    self.cond.signal()
                    self.cond.unlock()
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func limit() -> Int {
        capturing > 0 ? max(2, cores / 2) : cores
    }
}

enum WebKitLog {
    static func fmt(_ since: Date) -> String {
        let s = Date().timeIntervalSince(since)
        if s < 0.95 { return String(format: "%.0fms", s * 1000) }
        if s < 60 { return String(format: "%.1fs", s) }
        return String(format: "%.1fmin", s / 60)
    }

    static func perPage(_ n: Int, _ since: Date) -> String {
        guard n > 0 else { return "" }
        let s = Date().timeIntervalSince(since)
        guard s > 0 else { return "" }
        return String(format: "%.0fms/page", s / Double(n) * 1000)
    }

    static func bytes(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fMB", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: "%.0fKB", Double(n) / 1000) }
        return "\(n)B"
    }
}

enum WebKitConvertStyle {
    static func cssNumber(_ n: CGFloat) -> String {
        String(format: "%g", Double(n))
    }

    static func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let wrapped = String(data: data, encoding: .utf8),
              wrapped.count >= 2
        else { return "\"\"" }
        return String(wrapped.dropFirst().dropLast())
    }

    static func styleInjector(_ css: String) -> String {
        let literal = jsStringLiteral(css)
        return """
        (function() {
          const css = \(literal);
          const apply = () => {
            let s = document.getElementById('cookbook-print');
            if (!s) {
              s = document.createElement('style');
              s.id = 'cookbook-print';
              (document.head || document.documentElement).appendChild(s);
            }
            s.textContent = css;
          };
          apply();
          document.addEventListener('DOMContentLoaded', apply);
        })();
        """
    }

    static func wrapImage(_ url: URL) -> URL {
        let name = url.lastPathComponent
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8">
        <style>html,body{margin:0;height:100%}img{max-width:100%;max-height:100vh;display:block;margin:auto}</style>
        </head><body><img src="\(name)"></body></html>
        """
        let out = url.deletingLastPathComponent().appendingPathComponent("cookbook-img-\(UUID().uuidString).html")
        try? html.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    static let promoteEpubCSSJS = """
        (function() {
          function dests(name) {
            if (name.indexOf('-epub-') !== 0) return [];
            const rest = name.slice(6);
            if (rest === 'text-combine' || rest === 'text-combine-horizontal') {
              return ['text-combine-upright', '-webkit-text-combine'];
            }
            if (rest === 'writing-mode') {
              return ['writing-mode', '-webkit-writing-mode'];
            }
            return [rest, '-webkit-' + rest];
          }
          function promoteStyle(style) {
            if (!style) return;
            const jobs = [];
            for (let i = 0; i < style.length; i++) {
              const name = style.item(i);
              if (!name || name.indexOf('-epub-') !== 0) continue;
              const val = style.getPropertyValue(name);
              const pri = style.getPropertyPriority(name);
              const mapped = dests(name);
              for (let j = 0; j < mapped.length; j++) {
                let outVal = val;
                if (mapped[j] === 'text-combine-upright'
                    && String(val).indexOf('horizontal') !== -1) {
                  outVal = 'all';
                }
                jobs.push([mapped[j], outVal, pri]);
              }
            }
            for (let i = 0; i < jobs.length; i++) {
              const dest = jobs[i][0], val = jobs[i][1], pri = jobs[i][2];
              if (!style.getPropertyValue(dest)) style.setProperty(dest, val, pri);
            }
          }
          function promoteSheet(sheet) {
            let rules;
            try { rules = sheet.cssRules; } catch (e) { return; }
            if (!rules) return;
            for (let i = 0; i < rules.length; i++) {
              const r = rules[i];
              if (r.style) promoteStyle(r.style);
              if (r.cssRules) promoteSheet(r);
            }
          }
          function promoteText(css) {
            return css.replace(/-epub-([a-z-]+)\\s*:\\s*([^;}\\n]+)/gi, function(match, prop, val) {
              const p = String(prop).toLowerCase();
              let extra = '-webkit-' + p + ': ' + val + '; ' + p + ': ' + val;
              if (p === 'writing-mode') {
                extra = '-webkit-writing-mode: ' + val + '; writing-mode: ' + val;
              }
              if (p === 'text-combine' || p === 'text-combine-horizontal') {
                const upright = String(val).indexOf('horizontal') !== -1 ? 'all' : val;
                extra += '; text-combine-upright: ' + upright;
              }
              return match + '; ' + extra;
            });
          }
          const sheets = document.styleSheets;
          for (let i = 0; i < sheets.length; i++) promoteSheet(sheets[i]);
          const tags = document.querySelectorAll('style');
          for (let i = 0; i < tags.length; i++) {
            const t = tags[i].textContent || '';
            if (t.indexOf('-epub-') !== -1) tags[i].textContent = promoteText(t);
          }
          const inlines = document.querySelectorAll('[style]');
          for (let i = 0; i < inlines.length; i++) promoteStyle(inlines[i].style);
          function vrtl(el) {
            if (!el || !el.classList || !el.classList.contains('vrtl')) return;
            el.style.setProperty('writing-mode', 'vertical-rl', 'important');
            el.style.setProperty('-webkit-writing-mode', 'vertical-rl', 'important');
          }
          vrtl(document.documentElement);
          vrtl(document.body);
          return true;
        })()
        """
}
