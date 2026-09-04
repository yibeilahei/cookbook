import AppKit
import Foundation
import UniformTypeIdentifiers

enum ConvertMode: String, CaseIterable, Identifiable {
    case xtch
    case pdf
    var id: String { rawValue }
}

struct DeviceInfo: Identifiable, Hashable {
    var key: String
    var label: String
    var width: Int
    var height: Int
    var supersample: Int
    var orientation: String
    var id: String { key }

    var menuTitle: String {
        let name = label.isEmpty ? key : label
        return "\(name) (\(width)×\(height))"
    }
}

struct InputFile: Identifiable, Hashable {
    var path: String
    var stage: String?
    var message: String?
    var percent: Double?
    var detectedLanguage: String?
    var outputPath: String?
    var id: String { path }
    var name: String { URL(fileURLWithPath: path).lastPathComponent }
    var canPreviewXtch: Bool {
        guard let outputPath else { return false }
        return URL(fileURLWithPath: outputPath).pathExtension.lowercased() == "xtch"
    }
}

struct PreviewSession: Identifiable {
    let id = UUID()
    let path: String
    var title: String
    var status: String
    var images: [NSImage] = []
}

@Observable
@MainActor
final class AppModel {
    var mode: ConvertMode = .xtch {
        didSet {
            if oldValue != mode {
                selectedFile = nil
                Task { await reloadForMode() }
            }
        }
    }
    var devices: [DeviceInfo] = []
    var selectedDevice: String = ""
    var files: [InputFile] = []
    var selectedFile: String?
    var outputDir: String?
    var converting = false
    var convertStatus = ""
    var calibreHint: String?
    var settingsError = ""
    var settingsStatus = ""
    var batchCompleted = 0
    var batchTotal = 0
    var batchPercent = 0
    var batchEta: String = ""
    var showBatch = false
    var preview: PreviewSession?
    var showDeviceEditor = false

    var language = BookLanguage.detectFromLocale()
    var romanize = true
    var pageCompression = false
    var fontSerif = "Hiragino Mincho ProN"
    var fontSans = "Hiragino Sans"
    var fontMono = "Menlo"
    var fontSize = 60
    var systemFonts: [SystemFont] = []

    let backend = BackendClient()
    private var config: [String: Any] = [:]
    private var started = false
    private var ignoreSaves = false
    private var settingsStatusReset: Task<Void, Never>?
    private var convertingPaths: Set<String> = []
    private var queuedConvertPaths: [String] = []

    var isXtch: Bool { mode == .xtch }
    var romanizeEnabled: Bool { BookLanguage.romanizable.contains(language) }

    func startIfNeeded() {
        guard !started else { return }
        started = true
        systemFonts = FontLister.list()
        backend.onEvent = { [weak self] msg in
            DispatchQueue.main.async {
                self?.handleBackendEvent(msg)
            }
        }
        do {
            let launch = try Self.resolveBackend()
            try backend.start(command: launch.command, arguments: launch.arguments, cwd: launch.cwd)
        } catch {
            convertStatus = L10n.t("errorMsg", ["msg": error.localizedDescription])
            return
        }
        Task { await reloadForMode(); await checkCalibre() }
    }

    func stop() {
        backend.stop()
    }

    func reloadForMode() async {
        do {
            let listed = try await backend.callDict("list_devices", ["kind": mode.rawValue])
            devices = Self.parseDevices(listed["devices"]).sorted { $0.key < $1.key }
            if let def = listed["default"] as? String, devices.contains(where: { $0.key == def }) {
                selectedDevice = def
            } else {
                selectedDevice = devices.first?.key ?? ""
            }
            config = try await backend.callDict("get_config", ["kind": mode.rawValue])
            applyConfigToForm()
        } catch {
            convertStatus = L10n.t("errorMsg", ["msg": error.localizedDescription])
        }
    }

    func checkCalibre() async {
        do {
            let result = try await backend.callDict("find_calibre")
            if jsonBool(result["found"]) == true {
                calibreHint = nil
            } else {
                calibreHint = result["hint"] as? String ?? L10n.t("calibreNotFound")
            }
        } catch {
            calibreHint = error.localizedDescription
        }
    }

    func pickInputs() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = Self.inputTypes
        if let dir = UserDefaults.standard.string(forKey: "lastInputDir") {
            panel.directoryURL = URL(fileURLWithPath: dir)
        }
        guard panel.runModal() == .OK else { return }
        if let first = panel.urls.first {
            UserDefaults.standard.set(Self.dirOf(first.path), forKey: "lastInputDir")
        }
        Task { await addPaths(panel.urls.map(\.path)) }
    }

    func pickOutputDir() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        let hint = files.first.map { Self.dirOf($0.path) }
            ?? UserDefaults.standard.string(forKey: "lastOutputDir")
        if let hint { panel.directoryURL = URL(fileURLWithPath: hint) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        outputDir = url.path
        UserDefaults.standard.set(url.path, forKey: "lastOutputDir")
    }

    func clearOutputDir() {
        outputDir = nil
    }

    func addPaths(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        do {
            let result = try await backend.callDict("expand_inputs", ["paths": paths])
            let incoming = (result["files"] as? [Any])?.compactMap { $0 as? String } ?? []
            var existing = Set(files.map(\.path))
            var newFiles: [String] = []
            for path in incoming where !existing.contains(path) {
                existing.insert(path)
                files.append(InputFile(path: path))
                newFiles.append(path)
            }
            if !newFiles.isEmpty {
                await detectAndApplyLanguage(newFiles)
                await convert(paths: newFiles)
            }
        } catch {
            convertStatus = L10n.t("errorMsg", ["msg": error.localizedDescription])
        }
    }

    func isConverting(_ path: String) -> Bool {
        converting && convertingPaths.contains(path)
            && files.first(where: { $0.path == path }).map {
                $0.stage != "done" && $0.stage != "error" && $0.stage != "cancelled"
            } ?? false
    }

    func removeFile(_ path: String) {
        files.removeAll { $0.path == path }
        if selectedFile == path {
            clearFileSelection()
        }
    }

    func clearFileSelection() {
        selectedFile = nil
        applyConfigToForm()
    }

    func selectFile(_ path: String) async {
        if selectedFile == path {
            selectedFile = nil
            applyConfigToForm()
            return
        }
        selectedFile = path
        settingsStatus = ""
        var language = files.first(where: { $0.path == path })?.detectedLanguage
        if language == nil {
            do {
                let result = try await backend.callDict("detect_language", ["paths": [path]])
                let langs = asStringDict(result["languages"] ?? [:]) ?? [:]
                let detected = langs[path] as? String
                language = detected
                if let idx = files.firstIndex(where: { $0.path == path }) {
                    files[idx].detectedLanguage = detected
                }
            } catch {
                language = nil
            }
        }
        guard selectedFile == path else { return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        if let language, !language.isEmpty {
            applyLanguage(language, romanize: true, save: false)
            flashStatus(L10n.t("previewingFile", [
                "file": name,
                "lang": L10n.t(BookLanguage.nameKey(language)),
            ]))
        } else {
            flashStatus(L10n.t("previewingFileUnknown", ["file": name]), autoClear: false)
        }
    }

    func convert(paths: [String]? = nil) async {
        let targets = (paths ?? files.map(\.path)).filter { path in
            files.contains { $0.path == path && $0.stage != "done" }
        }
        guard !targets.isEmpty else { return }
        guard !selectedDevice.isEmpty else {
            convertStatus = L10n.t("selectDeviceFirst")
            return
        }
        if converting {
            queuedConvertPaths.append(contentsOf: targets.filter { !queuedConvertPaths.contains($0) })
            return
        }
        converting = true
        convertingPaths = Set(targets)
        convertStatus = L10n.t("converting")
        showBatch = false
        batchCompleted = 0
        batchTotal = 0
        batchPercent = 0
        batchEta = ""
        for i in files.indices where convertingPaths.contains(files[i].path) {
            files[i].stage = nil
            files[i].message = nil
            files[i].percent = nil
            files[i].outputPath = nil
        }
        var params: [String: Any] = [
            "kind": mode.rawValue,
            "device": selectedDevice,
            "paths": targets,
        ]
        if let outputDir { params["output_dir"] = outputDir }
        do {
            let result = try await backend.callDict("convert", params)
            if let doneList = result["done"] as? [Any] {
                for item in doneList {
                    guard let dict = asStringDict(item),
                          let file = dict["file"] as? String,
                          let output = dict["output"] as? String,
                          let idx = files.firstIndex(where: { $0.path == file }) else { continue }
                    files[idx].outputPath = output
                    files[idx].stage = "done"
                    files[idx].percent = 100
                }
            }
            let done = (result["done"] as? [Any])?.count ?? 0
            let skipped = (result["skipped"] as? [Any])?.count ?? 0
            let errors = (result["errors"] as? [Any])?.count ?? 0
            var parts: [String] = []
            if done > 0 { parts.append(L10n.t("nDone", ["n": "\(done)"])) }
            if skipped > 0 { parts.append(L10n.t("nSkipped", ["n": "\(skipped)"])) }
            if errors > 0 { parts.append(L10n.t("nFailed", ["n": "\(errors)"])) }
            let cancelled = jsonBool(result["cancelled"]) ?? false
            convertStatus = cancelled
                ? L10n.t("cancelledWith", ["parts": parts.isEmpty ? L10n.t("nothingFinished") : parts.joined(separator: ", ")])
                : (parts.isEmpty ? L10n.t("nothingToDo") : parts.joined(separator: ", "))
        } catch {
            convertStatus = L10n.t("errorMsg", ["msg": error.localizedDescription])
        }
        converting = false
        convertingPaths = []
        let queued = queuedConvertPaths
        queuedConvertPaths = []
        if !queued.isEmpty {
            await convert(paths: queued)
        }
    }

    func cancel() async {
        convertStatus = L10n.t("cancelling")
        _ = try? await backend.callDict("cancel")
    }

    func openPreview(_ file: InputFile) async {
        guard file.canPreviewXtch, let xtch = file.outputPath else { return }
        let name = URL(fileURLWithPath: xtch).lastPathComponent
        preview = PreviewSession(
            path: xtch,
            title: L10n.t("previewTitleFor", ["name": name]),
            status: L10n.t("renderingPages", ["n": "15"])
        )
        do {
            let result = try await backend.callDict("preview", [
                "kind": mode.rawValue,
                "device": selectedDevice,
                "path": xtch,
                "max_pages": 15,
            ])
            let previewed = jsonInt(result["previewed"]) ?? 0
            let pageCount = jsonInt(result["page_count"]) ?? 0
            let pages = (result["pages"] as? [Any])?.compactMap { $0 as? String } ?? []
            var images: [NSImage] = []
            for url in pages {
                if let image = NSImage.fromDataURL(url) { images.append(image) }
            }
            if var session = preview, session.path == xtch {
                session.images = images
                session.status = L10n.t("showingPages", [
                    "shown": "\(previewed)",
                    "total": "\(pageCount)",
                    "s": pageCount == 1 ? "" : "s",
                ])
                preview = session
            }
        } catch {
            if var session = preview, session.path == xtch {
                session.status = L10n.t("errorMsg", ["msg": error.localizedDescription])
                preview = session
            }
        }
    }

    func languageChanged(_ newValue: String) {
        applyLanguage(newValue, romanize: true, save: true)
    }

    func saveSettings() async {
        guard !ignoreSaves else { return }
        settingsError = ""
        let serif = fontSerif.trimmingCharacters(in: .whitespaces)
        let sans = fontSans.trimmingCharacters(in: .whitespaces)
        let mono = fontMono.trimmingCharacters(in: .whitespaces)
        guard !serif.isEmpty, !sans.isEmpty, !mono.isEmpty else {
            settingsError = L10n.t("errFontsRequired")
            return
        }
        guard fontSize > 0 else {
            settingsError = L10n.t("errFontSize")
            return
        }
        var updated = config
        var fonts = asStringDict(updated["fonts"] ?? [:]) ?? [:]
        fonts["macos"] = ["serif": serif, "sans": sans, "mono": mono]
        updated["fonts"] = fonts
        updated["font_size"] = fontSize
        updated["language"] = language
        if mode == .xtch {
            let on = romanizeEnabled && romanize
            updated["ascii_romanization"] = on ? BookLanguage.asciiRomanization(for: language) : "none"
            updated["page_compression"] = pageCompression
        }
        do {
            _ = try await backend.call("save_config", ["kind": mode.rawValue, "config": updated])
            config = updated
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func saveDevices(_ drafts: [DeviceDraft], defaultKey: String) async throws {
        var updated = config
        var devicesObj: [String: Any] = [:]
        var seen = Set<String>()
        guard !drafts.isEmpty else { throw AppError.message(L10n.t("errAtLeastOneDevice")) }
        for draft in drafts {
            let key = draft.key.trimmingCharacters(in: .whitespaces)
            if key.isEmpty { throw AppError.message(L10n.t("errEmptyKey")) }
            if seen.contains(key) { throw AppError.message(L10n.t("errDuplicateKey", ["key": key])) }
            seen.insert(key)
            var table: [String: Any] = [
                "label": draft.label,
                "width": draft.width,
                "height": draft.height,
                "orientation": draft.orientation,
            ]
            if mode == .xtch { table["supersample"] = draft.supersample }
            devicesObj[key] = table
        }
        updated["devices"] = devicesObj
        updated["default"] = seen.contains(defaultKey) ? defaultKey : (drafts.first?.key ?? "")
        _ = try await backend.call("save_config", ["kind": mode.rawValue, "config": updated])
        config = updated
        await reloadForMode()
    }

    private func applyLanguage(_ language: String, romanize: Bool, save: Bool) {
        self.language = language
        let preset = BookLanguage.recommended(language)
        fontSerif = preset.serif
        fontSans = preset.sans
        fontMono = preset.mono
        self.romanize = BookLanguage.romanizable.contains(language) && romanize
        if save {
            Task { await saveSettings() }
        }
    }

    private func applyConfigToForm() {
        ignoreSaves = true
        defer { ignoreSaves = false }
        language = config["language"] as? String ?? BookLanguage.detectFromLocale()
        if let romanization = config["ascii_romanization"] as? String {
            romanize = romanization != "none"
        } else {
            romanize = BookLanguage.romanizable.contains(language)
        }
        pageCompression = jsonBool(config["page_compression"]) ?? false
        let fonts = asStringDict(asStringDict(config["fonts"] ?? [:])?["macos"] ?? [:]) ?? [:]
        fontSerif = fonts["serif"] as? String ?? fontSerif
        fontSans = fonts["sans"] as? String ?? fontSans
        fontMono = fonts["mono"] as? String ?? fontMono
        fontSize = jsonInt(config["font_size"]) ?? 60
        settingsError = ""
        settingsStatus = ""
    }

    private func detectAndApplyLanguage(_ newFiles: [String]) async {
        let sample = Array(newFiles.prefix(20))
        let result: [String: Any]
        do {
            result = try await backend.callDict("detect_language", ["paths": sample])
        } catch {
            return
        }
        let langs = asStringDict(result["languages"] ?? [:]) ?? [:]
        var counts: [String: Int] = [:]
        for path in sample {
            let lang = langs[path] as? String
            if let idx = files.firstIndex(where: { $0.path == path }) {
                files[idx].detectedLanguage = lang
            }
            if let lang, !lang.isEmpty {
                counts[lang, default: 0] += 1
            }
        }
        guard let detected = counts.max(by: { $0.value < $1.value })?.key, detected != language else { return }
        applyLanguage(detected, romanize: true, save: true)
        flashStatus(L10n.t("detectedApplied", ["lang": L10n.t(BookLanguage.nameKey(detected))]))
    }

    private func handleBackendEvent(_ msg: [String: Any]) {
        let type = msg["type"] as? String
        if type == "batch" {
            let completed = jsonInt(msg["completed"]) ?? 0
            let total = jsonInt(msg["total"]) ?? 0
            batchCompleted = completed
            batchTotal = total
            batchPercent = total > 0 ? Int(round(Double(completed) / Double(total) * 100)) : 0
            if let eta = jsonDouble(msg["eta_seconds"]), eta.isFinite {
                batchEta = L10n.t("etaSuffix", ["eta": Self.formatEta(eta)])
            } else {
                batchEta = ""
            }
            showBatch = true
            return
        }
        guard let file = msg["file"] as? String,
              let idx = files.firstIndex(where: { $0.path == file }) else { return }
        let stage = msg["stage"] as? String
        files[idx].stage = stage
        files[idx].message = msg["message"] as? String
        if stage == "done" {
            files[idx].percent = 100
            if let dest = msg["message"] as? String, !dest.isEmpty {
                files[idx].outputPath = dest
            }
        } else if stage == "error" {
            files[idx].percent = 0
        } else if let percent = jsonDouble(msg["percent"]) {
            files[idx].percent = min(100, max(0, percent))
        }
    }

    private func flashStatus(_ text: String, autoClear: Bool = true) {
        settingsStatus = text
        settingsStatusReset?.cancel()
        guard autoClear else { return }
        settingsStatusReset = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            if !Task.isCancelled { self?.settingsStatus = "" }
        }
    }

    private static func parseDevices(_ raw: Any?) -> [DeviceInfo] {
        guard let dict = asStringDict(raw ?? [:]) else { return [] }
        return dict.compactMap { key, value in
            guard let dev = asStringDict(value) else { return nil }
            return DeviceInfo(
                key: key,
                label: dev["label"] as? String ?? "",
                width: jsonInt(dev["width"]) ?? 0,
                height: jsonInt(dev["height"]) ?? 0,
                supersample: jsonInt(dev["supersample"]) ?? 3,
                orientation: dev["orientation"] as? String ?? "portrait"
            )
        }
    }

    private static func formatEta(_ seconds: Double) -> String {
        let s = Int(seconds.rounded())
        if s < 60 { return "\(s)s" }
        return "\(s / 60)m \(s % 60)s"
    }

    private static func dirOf(_ path: String) -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return path
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
    }

    private static func userConfigDir() -> String {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = root.appendingPathComponent("Cookbook/device-config", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.path
    }

    private static func resolveBackend() throws -> (command: URL, arguments: [String], cwd: URL?) {
        let configDir = userConfigDir()
        if let bundled = bundledBackend(), FileManager.default.isExecutableFile(atPath: bundled.path) {
            return (bundled, ["--user-config-dir", configDir], nil)
        }
        let repo = findRepoRoot()
        let venv = repo.appendingPathComponent(".venv/bin/python3")
        let python = FileManager.default.isExecutableFile(atPath: venv.path)
            ? venv
            : URL(fileURLWithPath: "/usr/bin/python3")
        return (python, ["-m", "backend.server", "--user-config-dir", configDir], repo)
    }

    private static func bundledBackend() -> URL? {
        if let url = Bundle.main.url(forResource: "backend-server", withExtension: nil, subdirectory: "backend") {
            return url
        }
        if let resources = Bundle.main.resourceURL {
            let url = resources.appendingPathComponent("backend/backend-server")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private static func findRepoRoot() -> URL {
        var urls: [URL] = [URL(fileURLWithPath: FileManager.default.currentDirectoryPath)]
        var exe = URL(fileURLWithPath: CommandLine.arguments[0]).standardized
        for _ in 0..<16 {
            urls.append(exe)
            exe.deleteLastPathComponent()
        }
        for start in urls {
            var dir = start
            for _ in 0..<10 {
                if FileManager.default.fileExists(atPath: dir.appendingPathComponent("devices.xtch.toml").path) {
                    return dir
                }
                dir.deleteLastPathComponent()
            }
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }

    private static let inputTypes: [UTType] = {
        var types: [UTType] = [.pdf]
        let exts = [
            "epub", "mobi", "azw", "azw3", "fb2", "lit", "lrf", "pdb", "rtf", "txt",
            "htmlz", "html", "cbz", "cbr", "cbc", "chm", "djvu", "docx", "odt", "prc",
            "pml", "rb", "snb", "tcr",
        ]
        for ext in exts {
            if let type = UTType(filenameExtension: ext) { types.append(type) }
        }
        return types
    }()
}

enum AppError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let s): return s
        }
    }
}

struct DeviceDraft: Identifiable, Hashable {
    var id = UUID()
    var key: String
    var label: String
    var width: Int
    var height: Int
    var supersample: Int
    var orientation: String
}

extension NSImage {
    static func fromDataURL(_ url: String) -> NSImage? {
        guard let comma = url.firstIndex(of: ",") else { return nil }
        let b64 = String(url[url.index(after: comma)...])
        guard let data = Data(base64Encoded: b64) else { return nil }
        return NSImage(data: data)
    }
}
