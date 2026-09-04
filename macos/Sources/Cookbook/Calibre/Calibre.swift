import Foundation

/// Locate and run Calibre's `ebook-convert` / `ebook-meta` CLIs.

enum CalibreError: LocalizedError {
    case notFound
    case failed(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .notFound:
            return "ebook-convert not found. Install Calibre:\n  brew install --cask calibre\n  or download from https://calibre-ebook.com\nOr set EBOOK_CONVERT to the ebook-convert binary."
        case .failed(let s): return s
        case .cancelled: return "cancelled"
        }
    }
}

final class Calibre: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?

    func findConvert() -> String? {
        if let env = ProcessInfo.processInfo.environment["EBOOK_CONVERT"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        if let path = which("ebook-convert") { return path }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            "/Applications/calibre.app/Contents/MacOS/ebook-convert",
            home.appendingPathComponent("Applications/calibre.app/Contents/MacOS/ebook-convert").path,
        ]
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    func findMeta() -> String? {
        if let env = ProcessInfo.processInfo.environment["EBOOK_META"],
           FileManager.default.isExecutableFile(atPath: env) {
            return env
        }
        if let path = which("ebook-meta") { return path }
        guard let convert = findConvert() else { return nil }
        let sibling = URL(fileURLWithPath: convert)
            .deletingLastPathComponent()
            .appendingPathComponent("ebook-meta").path
        return FileManager.default.isExecutableFile(atPath: sibling) ? sibling : nil
    }

    func cancel() {
        lock.lock()
        process?.terminate()
        lock.unlock()
    }

    func ebookToPDF(
        src: URL, dest: URL, size: String,
        serif: String, sans: String, mono: String, fontSize: Int,
        onProgress: @escaping (Int, String) -> Void,
        onLog: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) throws {
        guard let exe = findConvert() else { throw CalibreError.notFound }
        try FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = [
            src.path, dest.path,
            "--custom-size", size,
            "--unit", "point",
            "--pdf-page-margin-left", "0",
            "--pdf-page-margin-right", "0",
            "--pdf-page-margin-top", "0",
            "--pdf-page-margin-bottom", "0",
            "--pdf-default-font-size", "\(fontSize)",
            "--pdf-serif-family", serif,
            "--pdf-sans-family", sans,
            "--pdf-mono-family", mono,
            "--embed-all-fonts",
            "--subset-embedded-fonts",
        ]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        lock.lock(); process = proc; lock.unlock()
        try proc.run()
        let handle = pipe.fileHandleForReading
        var buffer = Data()
        var log = ""
        while true {
            if shouldCancel() {
                proc.terminate()
                proc.waitUntilExit()
                throw CalibreError.cancelled
            }
            let chunk = handle.availableData
            if chunk.isEmpty {
                if !proc.isRunning { break }
                Thread.sleep(forTimeInterval: 0.05)
                continue
            }
            buffer.append(chunk)
            while let range = buffer.firstRange(of: Data([0x0A])) {
                let lineData = buffer.subdata(in: buffer.startIndex..<range.lowerBound)
                buffer.removeSubrange(buffer.startIndex...range.lowerBound)
                let line = String(data: lineData, encoding: .utf8) ?? ""
                log += line + "\n"
                if !line.isEmpty { onLog(line) }
                if let parsed = Self.parseProgress(line) {
                    onProgress(parsed.percent, parsed.message)
                }
            }
        }
        if !buffer.isEmpty {
            let line = String(data: buffer, encoding: .utf8) ?? ""
            if !line.isEmpty {
                log += line + "\n"
                onLog(line)
                if let parsed = Self.parseProgress(line) {
                    onProgress(parsed.percent, parsed.message)
                }
            }
        }
        proc.waitUntilExit()
        lock.lock(); process = nil; lock.unlock()
        if proc.terminationStatus != 0 {
            throw CalibreError.failed(log.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "ebook-convert exited \(proc.terminationStatus)"
                : log)
        }
    }

    func detectLanguage(path: String) -> String? {
        guard let exe = findMeta() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = [path]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        let deadline = Date().addingTimeInterval(10)
        while proc.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if proc.isRunning { proc.terminate() }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let text = String(data: data, encoding: .utf8) ?? ""
        var langCode: String?
        var fields: [String] = []
        for line in text.components(separatedBy: .newlines) {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let label = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if label == "Languages", langCode == nil {
                langCode = value.split(separator: ",").first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            } else if label == "Title" || label == "Title sort" || label == "Author(s)" {
                fields.append(value)
            }
        }
        guard let code = langCode else { return nil }
        if LanguageDetect.chineseCodes.contains(code) {
            return LanguageDetect.chineseScript(fields.joined(separator: "\n"))
        }
        return LanguageDetect.bucket(for: code)
    }

    private static func parseProgress(_ line: String) -> (percent: Int, message: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let percentEnd = trimmed.firstIndex(of: "%") else { return nil }
        let num = String(trimmed[..<percentEnd])
        guard let percent = Int(num), (0...100).contains(percent) else { return nil }
        let rest = trimmed[trimmed.index(after: percentEnd)...].trimmingCharacters(in: .whitespaces)
        return (percent, rest.isEmpty ? "Converting to PDF" : rest)
    }

    private func which(_ name: String) -> String? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        proc.arguments = [name]
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return nil }
        proc.waitUntilExit()
        let path = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return path.isEmpty ? nil : path
    }
}
