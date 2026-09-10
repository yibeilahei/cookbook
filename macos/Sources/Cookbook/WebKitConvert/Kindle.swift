import Foundation
import LibMobi

/// Unpack DRM-free MOBI / AZW / AZW3 with vendored libmobi.
/// Dumps reconstructed HTML (and images/CSS/fonts) using the same
/// `part00000.html` / `resource00000.jpg` names libmobi rewrites into hrefs.
enum KindleBook {
    static let extensions: Set<String> = ["mobi", "azw", "azw3", "prc"]

    static func canOpen(_ ext: String) -> Bool {
        extensions.contains(ext)
    }

    static func language(at path: String) -> String? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        guard canOpen(ext) else { return nil }
        guard let m = mobi_init() else { return nil }
        defer { mobi_free(m) }
        guard mobi_load_filename(m, path) == MOBI_SUCCESS else { return nil }
        if mobi_is_encrypted(m) { return nil }
        let title = takeString(mobi_meta_get_title(m)) ?? ""
        let author = takeString(mobi_meta_get_author(m)) ?? ""
        guard let lang = takeString(mobi_meta_get_language(m)) else { return nil }
        var code = lang.lowercased()
        if let dash = code.firstIndex(of: "-") { code = String(code[..<dash]) }
        if let under = code.firstIndex(of: "_") { code = String(code[..<under]) }
        if LanguageDetect.chineseCodes.contains(code) {
            return LanguageDetect.chineseScript(title + author) ?? LanguageDetect.bucket(for: code)
        }
        return LanguageDetect.bucket(for: code)
    }

    static func unpack(_ src: URL) throws -> (
        root: URL, items: [EpubBook.Item], title: String, author: String, parts: Int
    ) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cookbook-mobi-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        guard let m = mobi_init() else {
            throw WebKitConvertError.failed("libmobi init failed")
        }
        defer { mobi_free(m) }

        try check(mobi_load_filename(m, src.path), "load")
        if mobi_is_encrypted(m) { throw WebKitConvertError.encrypted }
        if mobi_is_replica(m) {
            throw WebKitConvertError.formatNeedsCalibre("azw4")
        }
        _ = mobi_parse_kf8(m)

        guard let rawml = mobi_init_rawml(m) else {
            throw WebKitConvertError.failed("libmobi rawml init failed")
        }
        defer { mobi_free_rawml(rawml) }
        try check(mobi_parse_rawml(rawml, m), "parse")

        var items: [EpubBook.Item] = []
        try walk(rawml.pointee.markup) { part in
            if let url = try dump(part, prefix: "part", dir: root),
               part.pointee.type == T_HTML {
                items.append(EpubBook.Item(href: url, mediaType: mime(part.pointee.type)))
            }
        }
        // flow[0] is the concatenated raw markup; later nodes are CSS etc.
        var flow = rawml.pointee.flow?.pointee.next
        while let part = flow {
            _ = try dump(part, prefix: "flow", dir: root)
            flow = part.pointee.next
        }
        try walk(rawml.pointee.resources) { part in
            _ = try dump(part, prefix: "resource", dir: root)
        }

        if items.isEmpty { throw WebKitConvertError.noSpine }
        let merged = try mergeSpines(items, dir: root)
        let title = takeString(mobi_meta_get_title(m))
            ?? src.deletingPathExtension().lastPathComponent
        let author = takeString(mobi_meta_get_author(m)) ?? ""
        return (root, merged, title, author, items.count)
    }

    /// libmobi emits one XHTML file per KF8 skeleton. Complete works become
    /// 1000+ tiny spines; each is a WKWebView navigation. Concatenate consecutive
    /// bodies into ~256KB documents so capture matches EPUB (few long files).
    private static let mergeBytes = 256 * 1024

    private static func mergeSpines(_ items: [EpubBook.Item], dir: URL) throws -> [EpubBook.Item] {
        if items.count <= 1 { return items }
        var batches: [[EpubBook.Item]] = []
        var current: [EpubBook.Item] = []
        var bytes = 0
        for item in items {
            let size = (try? FileManager.default.attributesOfItem(atPath: item.href.path)[.size] as? Int) ?? 0
            if !current.isEmpty, bytes + size > mergeBytes {
                batches.append(current)
                current = []
                bytes = 0
            }
            current.append(item)
            bytes += size
        }
        if !current.isEmpty { batches.append(current) }
        if batches.count == items.count { return items }

        var map: [String: String] = [:]
        var merged: [EpubBook.Item] = []
        merged.reserveCapacity(batches.count)
        for (i, batch) in batches.enumerated() {
            let name = String(format: "spine%05d.html", i)
            for item in batch { map[item.href.lastPathComponent] = name }
            let url = dir.appendingPathComponent(name)
            try writeMerged(batch, to: url)
            merged.append(EpubBook.Item(href: url, mediaType: "application/xhtml+xml"))
        }
        for item in merged {
            let html = try String(contentsOf: item.href, encoding: .utf8)
            try rewritePartLinks(html, map: map).write(to: item.href, atomically: true, encoding: .utf8)
        }
        return merged
    }

    private static func writeMerged(_ batch: [EpubBook.Item], to url: URL) throws {
        let first = try String(contentsOf: batch[0].href, encoding: .utf8)
        var html = headAndOpenBody(first)
        for item in batch {
            html += bodyInner(try String(contentsOf: item.href, encoding: .utf8))
        }
        html += "</body></html>\n"
        try html.write(to: url, atomically: true, encoding: .utf8)
    }

    private static func headAndOpenBody(_ html: String) -> String {
        if let fromBody = html.range(of: "<body", options: .caseInsensitive),
           let gt = html[fromBody.lowerBound...].range(of: ">") {
            return String(html[..<gt.upperBound])
        }
        return html
    }

    private static func bodyInner(_ html: String) -> String {
        guard let fromBody = html.range(of: "<body", options: .caseInsensitive),
              let gt = html[fromBody.lowerBound...].range(of: ">"),
              let end = html.range(of: "</body>", options: [.caseInsensitive, .backwards])
        else { return html }
        return String(html[gt.upperBound..<end.lowerBound])
    }

    private static func rewritePartLinks(_ html: String, map: [String: String]) -> String {
        guard let re = try? NSRegularExpression(pattern: "part[0-9]+\\.html") else { return html }
        let ns = html as NSString
        let matches = re.matches(in: html, options: [], range: NSRange(location: 0, length: ns.length))
        var result = html
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let name = String(result[range])
            if let dest = map[name] { result.replaceSubrange(range, with: dest) }
        }
        return result
    }

    private static func dump(
        _ part: UnsafeMutablePointer<MOBIPart>, prefix: String, dir: URL
    ) throws -> URL? {
        if part.pointee.size == 0 || part.pointee.type == T_BREAK { return nil }
        guard let bytes = part.pointee.data else { return nil }
        let ext = cString(mobi_get_filemeta_by_type(part.pointee.type).extension)
        let name = String(format: "%@%05zu.%@", prefix, part.pointee.uid, ext)
        let url = dir.appendingPathComponent(name)
        try Data(bytes: bytes, count: part.pointee.size).write(to: url)
        return url
    }

    private static func walk(
        _ head: UnsafeMutablePointer<MOBIPart>?,
        _ body: (UnsafeMutablePointer<MOBIPart>) throws -> Void
    ) rethrows {
        var curr = head
        while let part = curr {
            try body(part)
            curr = part.pointee.next
        }
    }

    private static func mime(_ type: MOBIFiletype) -> String {
        cString(mobi_get_filemeta_by_type(type).mime_type)
    }

    private static func cString<T>(_ value: T) -> String {
        withUnsafeBytes(of: value) { raw in
            raw.withMemoryRebound(to: CChar.self) { chars in
                String(cString: chars.baseAddress!)
            }
        }
    }

    private static func takeString(_ ptr: UnsafeMutablePointer<CChar>?) -> String? {
        guard let ptr else { return nil }
        defer { free(ptr) }
        var s = String(cString: ptr).trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("\u{FEFF}") { s.removeFirst() }
        return s.isEmpty ? nil : s
    }

    private static func check(_ ret: MOBI_RET, _ what: String) throws {
        if ret == MOBI_SUCCESS { return }
        if ret == MOBI_FILE_ENCRYPTED { throw WebKitConvertError.encrypted }
        throw WebKitConvertError.failed("libmobi \(what) failed (\(ret.rawValue))")
    }
}
