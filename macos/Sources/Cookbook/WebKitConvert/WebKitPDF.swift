import AppKit
import Foundation
import WebKit

/// Typeset EPUB/HTML/TXT/Kindle with WebKit (no Calibre).
/// Several offscreen WKWebViews capture independent spine files in parallel.
@MainActor
final class WebKitPDF {
    static let shared = WebKitPDF()

    private var cancelled = false
    private var workers: [WebKitSpineWorker] = []
    /// WKWebView / pagination size in CSS px (96 px/in), e.g. 704×1056.
    private var paper = NSSize.zero
    /// Output PDF / XTCH panel in points (72 pt/in), e.g. 528×792.
    private var panel = NSSize.zero
    private var cssFont: CGFloat = 16
    private var css = ""
    private var pdfCtx: CGContext?
    private var pdfBox = CGRect.zero
    private var pdfPageCount = 0
    private static let cssPxPerIn: CGFloat = 96
    private static let ptPerIn: CGFloat = 72
    private static let maxWorkers = 4

    func cancel() {
        cancelled = true
        for w in workers { w.cancel() }
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
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ext = src.pathExtension.lowercased()
        if shouldCancel() || cancelled { throw WebKitConvertError.cancelled }

        let prepared = try prepareJobs(src: src, ext: ext)
        defer {
            if let cleanup = prepared.cleanup { try? FileManager.default.removeItem(at: cleanup) }
            closePDF()
            tearDownWorkers()
        }
        configureLayout(pageWidth: pageWidth, pageHeight: pageHeight, fontSize: fontSize,
                        serif: serif, sans: sans, mono: mono, onLog: onLog)
        onLog("WebKit PDF (column capture)")
        try openPDF(dest)
        let slots = try await runSpines(
            prepared.jobs, maxPages: maxPages,
            onProgress: onProgress, onLog: onLog, shouldCancel: shouldCancel)
        for slot in slots {
            for data in slot { try appendPDFPage(from: data) }
        }
        if pdfPageCount == 0 { throw WebKitConvertError.failed("WebKit produced an empty PDF") }
        closePDF()
        onProgress(100, "PDF ready")
    }

    /// EPUB/HTML → XTCH. Each spine is packed as it finishes; no book PDF.
    func ebookToXtch(
        src: URL, dest: URL,
        pageWidth: Int, pageHeight: Int,
        serif: String, sans: String, mono: String, fontSize: Int,
        supersample: Int, pageCompression: Bool,
        maxPages: Int = 0,
        onProgress: @escaping (Int, String) -> Void,
        onLog: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws {
        cancelled = false
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let ext = src.pathExtension.lowercased()
        if shouldCancel() || cancelled { throw WebKitConvertError.cancelled }

        let tAll = Date()
        let tUnpack = Date()
        let prepared = try prepareJobs(src: src, ext: ext)
        let spineWord = prepared.jobs.count == 1 ? "spine file" : "spine files"
        let extra = prepared.note.isEmpty ? "" : prepared.note
        onLog("unpacked \(prepared.jobs.count) \(spineWord)\(extra) in \(WebKitLog.fmt(tUnpack))  “\(prepared.title)”")
        let pack = XtchPacker.Options(
            width: pageWidth, height: pageHeight, supersample: max(supersample, 1),
            pageCompression: pageCompression, onPage: nil,
            shouldCancel: { shouldCancel() || self.cancelled })
        let gate = RasterGate()
        defer {
            if let cleanup = prepared.cleanup { try? FileManager.default.removeItem(at: cleanup) }
            tearDownWorkers()
        }
        configureLayout(pageWidth: pageWidth, pageHeight: pageHeight, fontSize: fontSize,
                        serif: serif, sans: sans, mono: mono, onLog: onLog)
        onLog("WebKit XTCH (1-wide createPDF, pack in background)")
        let tSpines = Date()
        let slots = try await runSpines(
            prepared.jobs, maxPages: maxPages,
            pack: pack, gate: gate,
            onProgress: onProgress, onLog: onLog, shouldCancel: shouldCancel)
        let bodies = slots.flatMap { $0 }
        onLog("spines captured+packed in \(WebKitLog.fmt(tSpines))")
        if bodies.isEmpty { throw WebKitConvertError.failed("WebKit produced no pages") }
        let tWrite = Date()
        try XtchPacker.write(
            pageBodies: bodies, destURL: dest,
            width: pageWidth, height: pageHeight,
            chapters: [], title: prepared.title, author: prepared.author)
        let size = (try? FileManager.default.attributesOfItem(atPath: dest.path)[.size] as? NSNumber)?.intValue ?? 0
        onLog("wrote \(dest.lastPathComponent) \(WebKitLog.bytes(size)) in \(WebKitLog.fmt(tWrite))")
        onLog("total \(bodies.count) pages in \(WebKitLog.fmt(tAll))  \(WebKitLog.perPage(bodies.count, tAll))")
        onProgress(100, "XTCH ready")
    }

    private struct PreparedJobs {
        var jobs: [WebKitPrintJob]
        var cleanup: URL?
        var title: String
        var author: String
        var note: String = ""
    }

    private func prepareJobs(src: URL, ext: String) throws -> PreparedJobs {
        switch ext {
        case "epub":
            let unpacked = try EpubBook.unpack(src)
            let jobs = unpacked.items.map {
                WebKitPrintJob(url: $0.href, mediaType: $0.mediaType, accessRoot: unpacked.root)
            }
            return PreparedJobs(
                jobs: jobs, cleanup: unpacked.root,
                title: unpacked.title, author: unpacked.author)
        case "html", "htm", "xhtml":
            return PreparedJobs(
                jobs: [WebKitPrintJob(url: src, mediaType: "text/html",
                                      accessRoot: src.deletingLastPathComponent())],
                cleanup: nil,
                title: src.deletingPathExtension().lastPathComponent, author: "")
        case "txt":
            let html = try Self.wrapText(src)
            return PreparedJobs(
                jobs: [WebKitPrintJob(url: html, mediaType: "text/html",
                                      accessRoot: html.deletingLastPathComponent())],
                cleanup: html.deletingLastPathComponent(),
                title: src.deletingPathExtension().lastPathComponent, author: "")
        case "mobi", "azw", "azw3", "prc":
            let unpacked = try KindleBook.unpack(src)
            let jobs = unpacked.items.map {
                WebKitPrintJob(url: $0.href, mediaType: $0.mediaType, accessRoot: unpacked.root)
            }
            let note: String
            if unpacked.parts > jobs.count {
                note = " (from \(unpacked.parts) KF8 parts)"
            } else {
                note = ""
            }
            return PreparedJobs(
                jobs: jobs, cleanup: unpacked.root,
                title: unpacked.title, author: unpacked.author, note: note)
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
        onLog("WebKit layout \(Int(paper.width.rounded()))×\(Int(paper.height.rounded())) CSS px, panel \(pageWidth)×\(pageHeight) pt, font \(WebKitConvertStyle.cssNumber(cssFont))px @96dpi  serif=\(serif)")
    }

    private func workerCount(jobs: Int, maxPages: Int) -> Int {
        if maxPages > 0 || jobs <= 1 { return 1 }
        return min(Self.maxWorkers, jobs, max(1, ProcessInfo.processInfo.activeProcessorCount))
    }

    private func runSpines(
        _ jobs: [WebKitPrintJob],
        maxPages: Int,
        pack: XtchPacker.Options? = nil,
        gate: RasterGate? = nil,
        onProgress: @escaping (Int, String) -> Void,
        onLog: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) async throws -> [[Data]] {
        let nWorkers = workerCount(jobs: jobs.count, maxPages: maxPages)
        onLog("WebKit \(nWorkers) view\(nWorkers == 1 ? "" : "s")  \(jobs.count) spines  \(ProcessInfo.processInfo.activeProcessorCount) cores")
        let pool = (0..<nWorkers).map {
            WebKitSpineWorker(id: $0, paper: paper, css: css, cssFont: cssFont)
        }
        workers = pool
        defer { tearDownWorkers() }

        let queue = SpineJobQueue(jobs: jobs)
        let budget = PageBudget(maxPages: maxPages)
        var slots: [[Data]?] = Array(repeating: nil, count: jobs.count)
        let tPool = Date()

        try await withThrowingTaskGroup(of: Void.self) { group in
            for worker in pool {
                group.addTask { @MainActor in
                    while let item = await queue.take() {
                        if shouldCancel() || self.cancelled {
                            throw WebKitConvertError.cancelled
                        }
                        let left = await budget.remaining()
                        if left == 0 {
                            onLog("[v\(worker.id)] stop, page budget empty")
                            break
                        }
                        let label = item.job.url.lastPathComponent
                        onLog("WebKit \(item.index + 1)/\(jobs.count) \(label) [view \(worker.id)] \(item.job.mediaType)")
                        onProgress(
                            Int(Double(item.index) / Double(max(jobs.count, 1)) * 100),
                            "WebKit \(item.index + 1)/\(jobs.count)")
                        do {
                            let pages = try await worker.captureJob(
                                item.job, limit: left == Int.max ? 0 : left,
                                pack: pack, gate: gate,
                                onLog: onLog, shouldCancel: { shouldCancel() || self.cancelled })
                            await budget.consume(pages.count)
                            slots[item.index] = pages
                            let filled = slots.compactMap { $0 }.count
                            onLog("[v\(worker.id)] packed \(label) (\(pages.count) page\(pages.count == 1 ? "" : "s"), \(filled)/\(jobs.count) spines ready)")
                        } catch {
                            onLog("[v\(worker.id)] failed \(label): \(error.localizedDescription)")
                            throw WebKitConvertError.failed("\(label): \(error.localizedDescription)")
                        }
                    }
                    onLog("[v\(worker.id)] idle after \(WebKitLog.fmt(tPool))")
                }
            }
            try await group.waitForAll()
        }
        if shouldCancel() || cancelled { throw WebKitConvertError.cancelled }
        onLog("all views idle  wall \(WebKitLog.fmt(tPool))")
        if maxPages > 0 {
            var out: [[Data]] = []
            for slot in slots {
                guard let slot else { break }
                out.append(slot)
            }
            return out
        }
        return try slots.enumerated().map { i, slot in
            guard let slot else {
                throw WebKitConvertError.failed("missing spine \(i + 1)/\(jobs.count)")
            }
            return slot
        }
    }

    private func tearDownWorkers() {
        for w in workers { w.tearDown() }
        workers = []
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

    private func appendPDFPage(from data: Data) throws {
        guard let provider = CGDataProvider(data: data as CFData),
              let src = CGPDFDocument(provider),
              let page = src.page(at: 1)
        else {
            throw WebKitConvertError.failed("WebKit PDF page was empty")
        }
        guard let ctx = pdfCtx else {
            throw WebKitConvertError.failed("PDF is not open")
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
          font-size: \(WebKitConvertStyle.cssNumber(fontSize))px !important;
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
          max-width: none !important;
          overflow: visible !important;
        }
        @media print {
          html, body { overflow: visible !important; }
          html:not(.vrtl), html:not(.vrtl) body {
            height: auto !important;
            max-height: none !important;
          }
          html.vrtl, html.vrtl body {
            height: \(height)pt !important;
            max-height: \(height)pt !important;
            width: auto !important;
            max-width: none !important;
          }
        }
        body {
          font-family: \(s), \(a), serif !important;
          font-size: \(WebKitConvertStyle.cssNumber(fontSize))px !important;
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
}

/// Hands out spine files to workers.
private actor SpineJobQueue {
    struct Item {
        var index: Int
        var job: WebKitPrintJob
    }

    private var next = 0
    private let jobs: [WebKitPrintJob]

    init(jobs: [WebKitPrintJob]) { self.jobs = jobs }

    func take() -> Item? {
        guard next < jobs.count else { return nil }
        let i = next
        next += 1
        return Item(index: i, job: jobs[i])
    }
}

private actor PageBudget {
    private var left: Int?

    init(maxPages: Int) {
        left = maxPages > 0 ? maxPages : nil
    }

    func remaining() -> Int { left ?? Int.max }

    func consume(_ n: Int) {
        if let left {
            self.left = max(0, left - n)
        }
    }
}
