import Foundation

/// Locate and run Calibre's `ebook-convert` / `ebook-meta` CLIs.

enum CalibreError: LocalizedError {
    case notFound
    case failed(String)
    case cancelled
    var errorDescription: String? {
        switch self {
        case .notFound:
            return "ebook-convert not found. Switch the engine to WebKit for EPUB/HTML/TXT/Kindle, or install Calibre:\n  brew install --cask calibre\n  or download from https://calibre-ebook.com"
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
        let arguments = [
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
        // Qt WebEngine often SIGSEGVs on the first spawn from Cookbook and
        // succeeds on the next try.
        let maxAttempts = 2
        for attempt in 1...maxAttempts {
            if shouldCancel() { throw CalibreError.cancelled }
            if attempt > 1 {
                try? FileManager.default.removeItem(at: dest)
                onProgress(0, "Retrying")
                onLog("ebook-convert crashed; retrying")
                Thread.sleep(forTimeInterval: 0.5)
                if shouldCancel() { throw CalibreError.cancelled }
            }
            switch try runEbookConvert(
                exe: exe, arguments: arguments,
                onProgress: onProgress, onLog: onLog, shouldCancel: shouldCancel
            ) {
            case .success:
                return
            case .failed(let message):
                throw CalibreError.failed(message)
            case .crashed(let message):
                if attempt == maxAttempts {
                    throw CalibreError.failed(message)
                }
            }
        }
    }

    func detectLanguage(path: String) -> String? {
        guard let exe = findMeta() else { return nil }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = [path]
        configure(proc)
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

    private enum ConvertRun {
        case success
        case crashed(String)
        case failed(String)
    }

    private func runEbookConvert(
        exe: String, arguments: [String],
        onProgress: @escaping (Int, String) -> Void,
        onLog: @escaping (String) -> Void,
        shouldCancel: @escaping () -> Bool
    ) throws -> ConvertRun {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: exe)
        proc.arguments = arguments
        configure(proc)
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
                lock.lock(); process = nil; lock.unlock()
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
        if proc.terminationStatus == 0 { return .success }
        let message = Self.failureMessage(process: proc, log: log)
        return Self.isCrash(proc) ? .crashed(message) : .failed(message)
    }

    private static func isCrash(_ proc: Process) -> Bool {
        guard proc.terminationReason == .uncaughtSignal else { return false }
        switch proc.terminationStatus {
        case SIGINT, SIGTERM: return false
        default: return true
        }
    }

    private static func parseProgress(_ line: String) -> (percent: Int, message: String)? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard let percentEnd = trimmed.firstIndex(of: "%") else { return nil }
        let num = String(trimmed[..<percentEnd])
        guard let percent = Int(num), (0...100).contains(percent) else { return nil }
        let rest = trimmed[trimmed.index(after: percentEnd)...].trimmingCharacters(in: .whitespaces)
        return (percent, rest.isEmpty ? "Converting to PDF" : rest)
    }

    /// Qt WebEngine SIGSEGVs in Skia Graphite/Metal when spawned from Cookbook.
    private func configure(_ proc: Process) {
        proc.standardInput = FileHandle.nullDevice
        proc.environment = Self.calibreEnvironment()
    }

    private static func calibreEnvironment(
        from parent: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        var env = parent
        for key in Array(env.keys) where key.hasPrefix("DYLD_") || key.hasPrefix("__XPC_DYLD_") {
            env.removeValue(forKey: key)
        }
        env["QTWEBENGINE_DISABLE_SANDBOX"] = "1"
        env["QT_QUICK_BACKEND"] = "software"
        env["QT_MAC_DISABLE_FOREGROUND_APPLICATION_TRANSFORM"] = "1"
        env["QTWEBENGINE_CHROMIUM_FLAGS"] = Self.mergeChromiumFlags(env["QTWEBENGINE_CHROMIUM_FLAGS"])
        return env
    }

    private static let chromiumFlags = [
        "--disable-gpu",
        "--disable-features=SkiaGraphite",
        "--no-sandbox",
    ]

    private static func mergeChromiumFlags(_ existing: String?) -> String {
        var tokens = (existing ?? "")
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
            .filter { !$0.isEmpty }
        for flag in chromiumFlags where !tokens.contains(flag) {
            tokens.append(flag)
        }
        return tokens.joined(separator: " ")
    }

    private static func failureMessage(process proc: Process, log: String) -> String {
        let trimmed = log.trimmingCharacters(in: .whitespacesAndNewlines)
        if proc.terminationReason == .uncaughtSignal {
            let crashed = "ebook-convert crashed (signal \(proc.terminationStatus))"
            return trimmed.isEmpty ? crashed : trimmed + "\n" + crashed
        }
        return trimmed.isEmpty ? "ebook-convert exited \(proc.terminationStatus)" : trimmed
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
