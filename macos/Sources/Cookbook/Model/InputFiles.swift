import Foundation
import UniformTypeIdentifiers

/// Ebook/PDF paths accepted by Add files… and drag-and-drop.
enum InputFiles {
    static let extensions: Set<String> = [
        "epub", "mobi", "azw", "azw3", "fb2", "lit", "lrf", "pdb", "rtf", "txt",
        "htmlz", "html", "cbz", "cbr", "cbc", "chm", "djvu", "docx", "odt", "prc",
        "pml", "rb", "snb", "tcr", "pdf",
    ]

    static var contentTypes: [UTType] {
        var types: [UTType] = [.pdf]
        for ext in extensions where ext != "pdf" {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }

    static func expand(_ paths: [String]) -> [String] {
        var out: [String] = []
        for path in paths {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                let kids = (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
                for name in kids.sorted() {
                    let child = URL(fileURLWithPath: path).appendingPathComponent(name)
                    let ext = child.pathExtension.lowercased()
                    if FileManager.default.isReadableFile(atPath: child.path), extensions.contains(ext) {
                        out.append(child.standardizedFileURL.path)
                    }
                }
            } else {
                out.append(URL(fileURLWithPath: path).standardizedFileURL.path)
            }
        }
        return out
    }
}
