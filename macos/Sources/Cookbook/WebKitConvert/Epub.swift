import Foundation

/// Unpack an EPUB and list linear spine documents (XHTML/HTML, or image pages).
enum EpubBook {
    struct Item {
        var href: URL
        var mediaType: String
    }

    static let htmlTypes: Set<String> = [
        "application/xhtml+xml", "text/html", "application/xml", "text/xml",
    ]
    static let imageTypes: Set<String> = [
        "image/jpeg", "image/png", "image/gif", "image/webp", "image/svg+xml",
    ]

    static func canOpen(_ ext: String) -> Bool {
        ["epub", "html", "htm", "xhtml", "txt"].contains(ext) || KindleBook.canOpen(ext)
    }

    static func language(at path: String) -> String? {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        if KindleBook.canOpen(ext) { return KindleBook.language(at: path) }
        guard ext == "epub" else { return nil }
        guard let opf = try? unzipToString(epub: path, memberSuffix: ".opf") else { return nil }
        return language(fromOPF: opf)
    }

    static func unpack(_ epub: URL) throws -> (root: URL, items: [Item], title: String, author: String) {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("cookbook-epub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try runUnzip(epub: epub, dest: root)
        if FileManager.default.fileExists(atPath: root.appendingPathComponent("META-INF/encryption.xml").path) {
            throw WebKitConvertError.encrypted
        }
        let containerURL = root.appendingPathComponent("META-INF/container.xml")
        guard let containerData = try? Data(contentsOf: containerURL) else {
            throw WebKitConvertError.failed("EPUB is missing META-INF/container.xml")
        }
        let container = try XMLDocument(data: containerData)
        let rootfiles = try container.nodes(forXPath: "//*[local-name()='rootfile']")
        let fullPath = (rootfiles.first as? XMLElement)?.attribute(forName: "full-path")?.stringValue
            ?? (rootfiles.first as? XMLElement)?.attribute(forLocalName: "full-path", uri: nil)?.stringValue
        guard let fullPath, !fullPath.isEmpty else {
            throw WebKitConvertError.failed("EPUB container has no rootfile")
        }
        let opfURL = root.appendingPathComponent(fullPath)
        let opfDir = opfURL.deletingLastPathComponent()
        let opf = try XMLDocument(data: Data(contentsOf: opfURL))
        var hrefByID: [String: (href: String, type: String)] = [:]
        for node in try opf.nodes(forXPath: "//*[local-name()='item']") {
            guard let el = node as? XMLElement,
                  let id = el.attribute(forName: "id")?.stringValue,
                  let href = el.attribute(forName: "href")?.stringValue
            else { continue }
            let type = el.attribute(forName: "media-type")?.stringValue ?? ""
            hrefByID[id] = (href, type)
        }
        var items: [Item] = []
        for node in try opf.nodes(forXPath: "//*[local-name()='itemref']") {
            guard let el = node as? XMLElement,
                  let idref = el.attribute(forName: "idref")?.stringValue
            else { continue }
            let linear = (el.attribute(forName: "linear")?.stringValue ?? "yes").lowercased()
            if linear == "no" { continue }
            guard let spec = hrefByID[idref] else { continue }
            let decoded = spec.href.removingPercentEncoding ?? spec.href
            let url = URL(fileURLWithPath: decoded, relativeTo: opfDir).standardizedFileURL
            items.append(Item(href: url, mediaType: spec.type.lowercased()))
        }
        if items.isEmpty { throw WebKitConvertError.noSpine }
        let title = firstText(opf, localName: "title")
        let author = firstText(opf, localName: "creator")
        return (root, items, title, author)
    }

    private static func firstText(_ doc: XMLDocument, localName: String) -> String {
        let nodes = (try? doc.nodes(forXPath: "//*[local-name()='\(localName)']")) ?? []
        return nodes.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty } ?? ""
    }

    static func language(fromOPF xml: String) -> String? {
        guard let doc = try? XMLDocument(xmlString: xml, options: []) else { return nil }
        let nodes = (try? doc.nodes(forXPath: "//*[local-name()='language']")) ?? []
        let raw = nodes.compactMap { $0.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
        guard var code = raw?.lowercased() else { return nil }
        if let dash = code.firstIndex(of: "-") { code = String(code[..<dash]) }
        if let under = code.firstIndex(of: "_") { code = String(code[..<under]) }
        if LanguageDetect.chineseCodes.contains(code) {
            let titles = ((try? doc.nodes(forXPath: "//*[local-name()='title' or local-name()='creator']")) ?? [])
                .compactMap { $0.stringValue }
                .joined(separator: "\n")
            return LanguageDetect.chineseScript(titles) ?? LanguageDetect.bucket(for: code)
        }
        return LanguageDetect.bucket(for: code)
    }

    private static func unzipToString(epub: String, memberSuffix: String) throws -> String? {
        let list = try runUnzipList(epub: epub)
        guard let member = list.first(where: { $0.lowercased().hasSuffix(memberSuffix) && !$0.hasSuffix("/") }) else {
            return nil
        }
        return try runUnzipStdout(epub: epub, member: member)
    }

    private static func runUnzip(epub: URL, dest: URL) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-qq", "-o", epub.path, "-d", dest.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        if proc.terminationStatus != 0 {
            throw WebKitConvertError.failed("Could not unzip EPUB")
        }
    }

    private static func runUnzipList(epub: String) throws -> [String] {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-Z", "-1", epub]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        let text = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return text.split(whereSeparator: \.isNewline).map(String.init)
    }

    private static func runUnzipStdout(epub: String, member: String) throws -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        proc.arguments = ["-p", epub, member]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else { return nil }
        return String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)
    }
}

enum WebKitConvertError: LocalizedError {
    case cancelled
    case encrypted
    case noSpine
    case formatNeedsCalibre(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .cancelled: return "cancelled"
        case .encrypted: return L10n.t("engineEncrypted")
        case .noSpine: return L10n.t("engineNoSpine")
        case .formatNeedsCalibre(let ext):
            return L10n.t("engineNeedsCalibre", ["format": ext.uppercased()])
        case .failed(let s): return s
        }
    }
}
