import AppKit
import Foundation

/// CLI: `swift run Cookbook -- --bench /path/book.epub [--pages 24]`
@MainActor
enum ConvertBench {
    static func launchIfRequested() -> Bool {
        let args = CommandLine.arguments
        guard let i = args.firstIndex(of: "--bench") else { return false }
        let rest = Array(args[(i + 1)...])
        var epub: URL?
        var maxPages = 24
        var j = 0
        while j < rest.count {
            let a = rest[j]
            if a == "--pages", j + 1 < rest.count {
                maxPages = max(1, Int(rest[j + 1]) ?? 24)
                j += 2
                continue
            }
            if a == "--full" {
                maxPages = 0
                j += 1
                continue
            }
            if !a.hasPrefix("-") { epub = URL(fileURLWithPath: a) }
            j += 1
        }
        guard let epub else {
            fputs("usage: Cookbook --bench <book.epub> [--pages N | --full]\n", stderr)
            exit(2)
        }
        NSApp.setActivationPolicy(.accessory)
        Task { @MainActor in
            do {
                try await run(epub: epub, maxPages: maxPages)
                exit(0)
            } catch {
                fputs("bench failed: \(error)\n", stderr)
                exit(1)
            }
        }
        return true
    }

    static func run(epub: URL, maxPages: Int) async throws {
        guard FileManager.default.isReadableFile(atPath: epub.path) else {
            throw WebKitConvertError.failed("unreadable \(epub.path)")
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("cookbook-bench-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        print("EPUB  \(epub.lastPathComponent)")
        print("out   \(out.path)")
        print("panel 528×792  layout 96dpi  font 60px  maxPages \(maxPages == 0 ? "all" : "\(maxPages)")")
        print("")

        let fonts = (serif: "Hiragino Mincho ProN", sans: "Hiragino Sans", mono: "Menlo")
        func log(_ line: String) { print("  \(line)") }

        let xtch = out.appendingPathComponent("book.xtch")
        let t1 = Date()
        try await WebKitPDF.shared.ebookToXtch(
            src: epub, dest: xtch,
            pageWidth: 528, pageHeight: 792,
            serif: fonts.serif, sans: fonts.sans, mono: fonts.mono, fontSize: 60,
            supersample: 3, pageCompression: false,
            maxPages: maxPages,
            onProgress: { _, _ in }, onLog: log, shouldCancel: { false })
        let sec = Date().timeIntervalSince(t1)
        let packedPages = try pageCount(xtch: xtch)
        print("")
        print("EPUB → XTCH (pack on arrival, no PDF)")
        print("   \(fmt(sec))   \(packedPages) pages   \(bytes(xtch))")
        print("   \(perPage(sec, packedPages))")
        print("  files \(out.path)")
    }

    private static func pageCount(xtch: URL) throws -> Int {
        let data = try Data(contentsOf: xtch)
        if data.count < 8 { return 0 }
        return Int(data.leUInt16(at: 6))
    }

    private static func bytes(_ url: URL) -> String {
        let n = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? 0
        if n >= 1_000_000 { return String(format: "%.1f MB", Double(n) / 1_000_000) }
        if n >= 1000 { return String(format: "%.0f KB", Double(n) / 1000) }
        return "\(n) B"
    }

    private static func fmt(_ sec: TimeInterval) -> String {
        if sec >= 60 { return String(format: "%.1f min", sec / 60) }
        return String(format: "%.1f s", sec)
    }

    private static func perPage(_ sec: TimeInterval, _ pages: Int) -> String {
        guard pages > 0 else { return "" }
        return String(format: "%.2f s/page", sec / Double(pages))
    }
}
