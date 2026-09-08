import AppKit
import CookbookWebKit
import Foundation
import WebKit

/// Typeset EPUB/HTML/TXT to a panel-sized PDF with WebKit (no Calibre).
/// Pages come from WKWebView's pagination API (the same one Books uses).
@MainActor
final class WebKitPDF: NSObject, WKNavigationDelegate {
    static let shared = WebKitPDF()

    private var cancelled = false
    private var navWait: CheckedContinuation<Void, Error>?
    private var window: NSWindow?
    private var webView: WKWebView?
    /// WKWebView / pagination size in CSS px (96 px/in), e.g. 704×1056.
    private var paper = NSSize.zero
    /// Output PDF / XTCH panel in points (72 pt/in), e.g. 528×792.
    private var panel = NSSize.zero
    private var cssFont: CGFloat = 16
    private var css = ""
    private var pager: Pager = .css
    private var pdfCtx: CGContext?
    private var pdfBox = CGRect.zero
    private var pdfPageCount = 0
    private var pageBudget = 0
    private var fontProbe = ""
    /// `_doAfterNextPresentationUpdate:` may not fire for an offscreen window.
    private var paintHookWorks = true
    /// Calibre `--pdf-default-font-size` is CSS px at 96 px/in. Screen WKWebView
    /// `px` match points (72 px/in); PDF capture uses print (96 px/in). Layout
    /// at 96dpi (704 CSS px, 60px type) and scale the PDF down to the panel.
    private static let cssPxPerIn: CGFloat = 96
    private static let ptPerIn: CGFloat = 72

    private enum Pager {
        /// Engine-owned pages: scroll by `delta` from `originX`.
        case engine(rtl: Bool, originX: CGFloat, delta: CGFloat)
        /// Public fallback: CSS columns / clip + translate.
        case css
    }

    private enum PaginationMode: Int {
        case unpaginated = 0
        case leftToRight = 1
        case rightToLeft = 2
        case topToBottom = 3
        case bottomToTop = 4
    }

    func cancel() {
        cancelled = true
        webView?.stopLoading()
        failNav(WebKitConvertError.cancelled)
    }

    static func canConvert(extension ext: String) -> Bool {
        EpubBook.canOpen(ext)
    }

    func ebookToPDF(
        src: URL, dest: URL,
        pageWidth: Int, pageHeight: Int,
        serif: String, sans: String, mono: String, fontSize: Int,
        maxPages: Int = 0,
        onProgress: @escaping (Int, String) -> Void,
        onLog: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws {
        cancelled = false
        paintHookWorks = true
        pageBudget = 0
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ext = src.pathExtension.lowercased()
        if shouldCancel() || cancelled { throw WebKitConvertError.cancelled }

        let prepared = try prepareJobs(src: src, ext: ext)
        defer {
            if let cleanup = prepared.cleanup { try? FileManager.default.removeItem(at: cleanup) }
            closePDF()
            tearDownView()
        }
        configureLayout(pageWidth: pageWidth, pageHeight: pageHeight, fontSize: fontSize,
                        serif: serif, sans: sans, mono: mono, onLog: onLog)
        onLog("WebKit PDF vector (document page rects)")
        try openPDF(dest)
        try await renderJobs(
            prepared.jobs, maxPages: maxPages,
            onProgress: onProgress, onLog: onLog, shouldCancel: shouldCancel
        ) { i, n, _, _, _ in
            try await self.appendVisiblePDFPage(index: i, of: n)
        }
        if pdfPageCount == 0 { throw WebKitConvertError.failed("WebKit produced an empty PDF") }
        closePDF()
        onProgress(100, "PDF ready")
    }

    private struct PrintJob {
        var url: URL
        var mediaType: String
        var accessRoot: URL
    }

    private struct PreparedJobs {
        var jobs: [PrintJob]
        var cleanup: URL?
        var title: String
        var author: String
    }

    private func prepareJobs(src: URL, ext: String) throws -> PreparedJobs {
        switch ext {
        case "epub":
            let unpacked = try EpubBook.unpack(src)
            let jobs = unpacked.items.map {
                PrintJob(url: $0.href, mediaType: $0.mediaType, accessRoot: unpacked.root)
            }
            return PreparedJobs(
                jobs: jobs, cleanup: unpacked.root,
                title: unpacked.title, author: unpacked.author)
        case "html", "htm", "xhtml":
            return PreparedJobs(
                jobs: [PrintJob(url: src, mediaType: "text/html",
                                accessRoot: src.deletingLastPathComponent())],
                cleanup: nil,
                title: src.deletingPathExtension().lastPathComponent, author: "")
        case "txt":
            let html = try Self.wrapText(src)
            return PreparedJobs(
                jobs: [PrintJob(url: html, mediaType: "text/html",
                                accessRoot: html.deletingLastPathComponent())],
                cleanup: html.deletingLastPathComponent(),
                title: src.deletingPathExtension().lastPathComponent, author: "")
        default:
            throw WebKitConvertError.formatNeedsCalibre(ext)
        }
    }

    private func configureLayout(
        pageWidth: Int, pageHeight: Int, fontSize: Int,
        serif: String, sans: String, mono: String,
        onLog: @escaping (String) -> Void
    ) {
        panel = NSSize(width: CGFloat(pageWidth), height: CGFloat(pageHeight))
        let cssScale = Self.cssPxPerIn / Self.ptPerIn
        paper = NSSize(width: panel.width * cssScale, height: panel.height * cssScale)
        cssFont = CGFloat(max(fontSize, 1))
        css = Self.printCSS(
            width: Int(panel.width.rounded()), height: Int(panel.height.rounded()),
            serif: serif, sans: sans, mono: mono, fontSize: cssFont)
        onLog("WebKit layout \(Int(paper.width.rounded()))×\(Int(paper.height.rounded())) CSS px, panel \(pageWidth)×\(pageHeight) pt, font \(Self.cssNumber(cssFont))px @96dpi")
        prepareView(paper: paper, css: css)
    }

    private func prepareView(paper: NSSize, css: String) {
        tearDownView()
        let config = WKWebViewConfiguration()
        config.preferences.javaScriptCanOpenWindowsAutomatically = false
        config.websiteDataStore = .nonPersistent()
        let script = WKUserScript(
            source: Self.styleInjector(css),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: true)
        config.userContentController.addUserScript(script)
        let wv = WKWebView(frame: NSRect(origin: .zero, size: paper), configuration: config)
        wv.navigationDelegate = self
        wv.cookbookSetWhiteBackground()

        let win = NSWindow(
            contentRect: NSRect(x: -12000, y: -12000, width: paper.width, height: paper.height),
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

    private func tearDownView() {
        webView?.navigationDelegate = nil
        webView = nil
        window?.contentView = nil
        window?.close()
        window = nil
        navWait = nil
    }

    private func renderJobs(
        _ jobs: [PrintJob],
        maxPages: Int = 0,
        onProgress: @escaping (Int, String) -> Void,
        onLog: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool,
        onPage: (Int, Int, Int, Int, String) async throws -> Void
    ) async throws {
        guard webView != nil else {
            throw WebKitConvertError.failed("WebKit view is not ready")
        }
        for (jobIndex, job) in jobs.enumerated() {
            if shouldCancel() || cancelled { throw WebKitConvertError.cancelled }
            let label = job.url.lastPathComponent
            onLog("WebKit \(jobIndex + 1)/\(jobs.count) \(label)")
            onProgress(
                Int(Double(jobIndex) / Double(max(jobs.count, 1)) * 100),
                "WebKit \(jobIndex + 1)/\(jobs.count)")
            await Task.yield()
            webView?.frame = NSRect(origin: .zero, size: paper)
            window?.setContentSize(paper)
            if EpubBook.imageTypes.contains(job.mediaType) {
                let html = Self.wrapImage(job.url)
                try await load(html, accessRoot: job.accessRoot)
            } else {
                try await load(job.url, accessRoot: job.accessRoot)
            }
            pager = .css
            let metrics = try await prepareLayout(paper: paper)
            if cancelled { throw WebKitConvertError.cancelled }
            let n = min(2000, max(1, metrics.pages))
            let axis = metrics.vertical ? (metrics.rtl ? "vertical-rl" : "vertical-lr") : "horizontal"
            let how: String
            switch pager {
            case .engine: how = "Books"
            case .css: how = "css"
            }
            onLog("  \(how) \(axis) \(Int(metrics.width))×\(Int(metrics.height)) → \(n) page\(n == 1 ? "" : "s")")
            if !fontProbe.isEmpty { onLog("  \(fontProbe)") }
            for i in 0..<n {
                if cancelled { throw WebKitConvertError.cancelled }
                if maxPages > 0, pageBudget >= maxPages { return }
                try await showPage(i, waitForPaint: true)
                try await onPage(i, n, jobIndex, jobs.count, label)
                pageBudget += 1
                if i == 0 || i + 1 == n || i % 16 == 15 {
                    onLog("  page \(i + 1)/\(n)")
                }
                if i % 8 == 7 { await Task.yield() }
            }
        }
    }

    private struct Metrics {
        var vertical: Bool
        var rtl: Bool
        var width: CGFloat
        var height: CGFloat
        var pages: Int
    }

    private func prepareLayout(paper: NSSize) async throws -> Metrics {
        guard let webView else {
            return Metrics(vertical: false, rtl: false, width: 1, height: 1, pages: 1)
        }
        let writing = try await detectWritingMode(webView)
        await pinFontSize(webView)
        await waitForFonts(webView)
        if webView.cookbookHasPagination() {
            if let metrics = try await enableEnginePagination(webView, paper: paper, rtl: writing.rtl) {
                pager = .engine(rtl: writing.rtl, originX: metrics.originX, delta: metrics.delta)
                return Metrics(
                    vertical: writing.vertical, rtl: writing.rtl,
                    width: paper.width, height: paper.height, pages: metrics.pages)
            }
            disableEnginePagination(webView)
        }
        pager = .css
        return try await enableCSSFallback(webView, paper: paper, vertical: writing.vertical)
    }

    private struct WritingMode {
        var vertical: Bool
        var rtl: Bool
    }

    private func detectWritingMode(_ webView: WKWebView) async throws -> WritingMode {
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
        return WritingMode(
            vertical: (dict?["vertical"] as? Bool) ?? false,
            rtl: (dict?["rtl"] as? Bool) ?? false)
    }

    private func pinFontSize(_ webView: WKWebView) async {
        let px = Self.cssNumber(cssFont)
        let js = """
        (function() {
          const px = '\(px)px';
          const root = document.documentElement;
          const body = document.body;
          if (root) {
            root.style.setProperty('font-size', px, 'important');
          }
          if (body) {
            body.style.setProperty('font-size', px, 'important');
          }
          const cs = body ? getComputedStyle(body) : null;
          return {
            html: root ? getComputedStyle(root).fontSize : '',
            body: cs ? cs.fontSize : '',
            innerWidth: window.innerWidth || 0
          };
        })()
        """
        let raw = try? await webView.evaluateJavaScript(js)
        if let dict = raw as? [String: Any] {
            let html = dict["html"] as? String ?? "?"
            let body = dict["body"] as? String ?? "?"
            let w = (dict["innerWidth"] as? NSNumber)?.intValue ?? 0
            fontProbe = "computed font html \(html) body \(body), innerWidth \(w)"
        } else {
            fontProbe = ""
        }
    }

    private struct EnginePages {
        var pages: Int
        var originX: CGFloat
        var delta: CGFloat
    }

    private func enableEnginePagination(
        _ webView: WKWebView, paper: NSSize, rtl: Bool
    ) async throws -> EnginePages? {
        let mode: PaginationMode = rtl ? .rightToLeft : .leftToRight
        setPagination(webView, mode: mode, pageLength: paper.width, gap: 0, likeColumns: true)
        await afterPaint(webView)
        _ = try? await webView.evaluateJavaScript(
            "document.documentElement && document.documentElement.offsetWidth")
        var engineCount = pageCount(webView)
        var scroll = try await scrollMetrics(webView)
        var fromScroll = max(1, Int(ceil((scroll.width / max(scroll.clientWidth, 1)) - 1e-6)))
        if engineCount == 0 && fromScroll <= 1 {
            await afterPaint(webView)
            engineCount = pageCount(webView)
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

    private func enableCSSFallback(
        _ webView: WKWebView, paper: NSSize, vertical: Bool
    ) async throws -> Metrics {
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

    private func openPDF(_ dest: URL) throws {
        closePDF()
        try? FileManager.default.removeItem(at: dest)
        pdfBox = CGRect(origin: .zero, size: panel)
        guard let ctx = CGContext(dest as CFURL, mediaBox: &pdfBox, nil) else {
            throw WebKitConvertError.failed("Could not create PDF")
        }
        pdfCtx = ctx
        pdfPageCount = 0
    }

    private func pdfDocumentRect(index i: Int, of _: Int) -> CGRect {
        let w = paper.width
        let h = paper.height
        switch pager {
        case .engine(let rtl, _, _):
            // drawToPDF uses document coordinates, not the scrolled view.
            // LTR: columns run +x. RTL / vertical-rl: later pages are at -x
            // (page 0 at the origin). (n-1-i)*w looks past the right edge → blank.
            let x = CGFloat(i) * (rtl ? -w : w)
            return CGRect(x: x, y: 0, width: w, height: h)
        case .css:
            return CGRect(origin: .zero, size: CGSize(width: w, height: h))
        }
    }

    private func capturePDFPage(rect: CGRect) async throws -> Data {
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
                try? await Task.sleep(nanoseconds: 20_000_000_000)
                resumeOnce(.failure(WebKitConvertError.failed("Timed out creating PDF page")))
            }
        }
    }

    private func appendVisiblePDFPage(index i: Int, of n: Int) async throws {
        let data = try await capturePDFPage(rect: pdfDocumentRect(index: i, of: n))
        try appendPDFPage(from: data)
    }

    private func appendPDFPage(from data: Data) throws {
        guard let ctx = pdfCtx else {
            throw WebKitConvertError.failed("PDF is not open")
        }
        guard let provider = CGDataProvider(data: data as CFData),
              let src = CGPDFDocument(provider),
              let page = src.page(at: 1)
        else {
            throw WebKitConvertError.failed("WebKit PDF page was empty")
        }
        ctx.beginPDFPage(nil)
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(pdfBox)
        ctx.saveGState()
        ctx.concatenate(page.getDrawingTransform(.mediaBox, rect: pdfBox, rotate: 0, preserveAspectRatio: false))
        ctx.drawPDFPage(page)
        ctx.restoreGState()
        ctx.endPDFPage()
        pdfPageCount += 1
    }

    private func closePDF() {
        pdfCtx?.closePDF()
        pdfCtx = nil
    }

    private func setPagination(
        _ webView: WKWebView, mode: PaginationMode, pageLength: CGFloat, gap: CGFloat, likeColumns: Bool
    ) {
        webView.cookbookSetPaginationMode(
            mode.rawValue, pageLength: pageLength, gap: gap, likeColumns: likeColumns)
    }

    private func disableEnginePagination(_ webView: WKWebView) {
        setPagination(webView, mode: .unpaginated, pageLength: 0, gap: 0, likeColumns: false)
    }

    private func pageCount(_ webView: WKWebView) -> Int {
        Int(webView.cookbookPageCount)
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
        // callAsyncJavaScript treats the string as the body of an async function.
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
        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                self.navWait = cont
                webView.loadFileURL(url, allowingReadAccessTo: accessRoot)
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 20_000_000_000)
                    if self.navWait != nil {
                        webView.stopLoading()
                        self.failNav(WebKitConvertError.failed("Timed out loading HTML"))
                    }
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
            failNav(error)
        }
    }

    nonisolated func webView(
        _ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error
    ) {
        Task { @MainActor in
            failNav(error)
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

    private static func cssNumber(_ n: CGFloat) -> String {
        String(format: "%g", Double(n))
    }

    private static func printCSS(
        width: Int, height: Int,
        serif: String, sans: String, mono: String, fontSize: CGFloat
    ) -> String {
        let s = cssQuote(serif)
        let a = cssQuote(sans)
        let m = cssQuote(mono)
        return """
        @page { size: \(width)pt \(height)pt; margin: 0; }
        html {
          font-size: \(cssNumber(fontSize))px !important;
        }
        html.vrtl, .vrtl {
          -webkit-writing-mode: vertical-rl !important;
          writing-mode: vertical-rl !important;
        }
        html.hltr, .hltr {
          -webkit-writing-mode: horizontal-tb !important;
          writing-mode: horizontal-tb !important;
        }
        html, body {
          margin: 0;
          padding: 0;
          background: #fff;
          overflow-wrap: break-word;
          -webkit-print-color-adjust: exact;
          print-color-adjust: exact;
        }
        body {
          font-family: \(s), \(a), serif !important;
          font-size: \(cssNumber(fontSize))px !important;
        }
        code, kbd, pre, samp, tt { font-family: \(m), monospace !important; }
        img, svg, video, canvas {
          max-width: 100%;
          max-height: 100%;
          page-break-inside: avoid;
          break-inside: avoid;
        }
        """
    }

    private static func jsStringLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let wrapped = String(data: data, encoding: .utf8),
              wrapped.count >= 2
        else { return "\"\"" }
        return String(wrapped.dropFirst().dropLast())
    }

    private static func styleInjector(_ css: String) -> String {
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

    private static func cssQuote(_ family: String) -> String {
        let trimmed = family.trimmingCharacters(in: .whitespaces)
        let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static func wrapText(_ src: URL) throws -> URL {
        let data = try Data(contentsOf: src)
        let text = String(data: data, encoding: .utf8)
            ?? String(data: data, encoding: .isoLatin1)
            ?? String(decoding: data, as: UTF8.self)
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let html = """
        <!DOCTYPE html><html><head><meta charset="utf-8"></head>
        <body><pre style="white-space:pre-wrap;word-wrap:break-word;margin:0">\(escaped)</pre></body></html>
        """
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cookbook-txt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("body.html")
        try html.write(to: out, atomically: true, encoding: .utf8)
        return out
    }

    private static func wrapImage(_ url: URL) -> URL {
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
}
