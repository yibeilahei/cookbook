import AppKit
import Foundation

/// Window state: files, settings, and conversion (WebKit or Calibre + Swift packer).
@Observable
@MainActor
final class AppModel {
    var mode: ConvertMode = .xtch
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
    var preview: PreviewSession?
    var showDeviceEditor = false

    var language = BookLanguage.detectFromLocale()
    var pageCompression = false
    var fontSerif = "Hiragino Mincho ProN"
    var fontSans = "Hiragino Sans"
    var fontMono = "Menlo"
    var fontSize = 60
    var convertEngine: ConvertEngine = .webkit
    var systemFonts: [SystemFont] = []

    let calibre = Calibre()
    private var storedConfig = DeviceConfig(
        defaultKey: nil, language: nil, fontSize: 60,
        pageCompression: false, fontSerif: "Hiragino Mincho ProN",
        fontSans: "Hiragino Sans", fontMono: "Menlo", devices: [])
    private var started = false
    private var ignoreSaves = false
    private var settingsStatusReset: Task<Void, Never>?
    private var convertingPaths: Set<String> = []
    /// Remaining books in the current batch, processed one at a time.
    private var convertJobs: [String] = []
    var expandedLogs: Set<String> = []
    private var reloadGeneration = 0
    private let packCancel = PackCancel()
    private var filePanelOpen = false
    private var previewDocument: XtchPreview.Document?
    private var previewLoadGeneration = 0
    private static let engineKey = "dev.cookbook.convertEngine"

    var isXtch: Bool { mode == .xtch }

    // MARK: - Lifecycle

    func startIfNeeded() {
        guard !started else { return }
        started = true
        systemFonts = FontLister.list()
        if let raw = UserDefaults.standard.string(forKey: Self.engineKey),
           let engine = ConvertEngine(rawValue: raw) {
            convertEngine = engine
        }
        Task { await reload(kind: mode); await checkCalibre() }
    }

    func stop() {
        calibre.cancel()
        WebKitPDF.shared.cancel()
        packCancel.cancel()
    }

    func applyMode(_ newMode: ConvertMode) async {
        selectedFile = nil
        await reload(kind: newMode)
        await checkCalibre()
    }

    func reloadForMode() async {
        await reload(kind: mode)
    }

    private func reload(kind: ConvertMode) async {
        reloadGeneration += 1
        let generation = reloadGeneration
        let loaded = DeviceConfigStore.load(kind: kind.rawValue)
        guard generation == reloadGeneration, mode == kind else { return }
        storedConfig = loaded
        devices = loaded.devices
        if let def = loaded.defaultKey, devices.contains(where: { $0.key == def }) {
            selectedDevice = def
        } else {
            selectedDevice = devices.first?.key ?? ""
        }
        applyConfigToForm()
    }

    func checkCalibre() async {
        // PDF output always uses ebook-convert. XTCH can skip Calibre when WebKit handles the file.
        if convertEngine == .webkit, mode == .xtch {
            calibreHint = nil
            return
        }
        if calibre.findConvert() != nil {
            calibreHint = nil
        } else {
            calibreHint = CalibreError.notFound.errorDescription
        }
    }

    func engineChanged(_ engine: ConvertEngine) async {
        convertEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: Self.engineKey)
        await checkCalibre()
    }

    func pickInputs() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = InputFiles.contentTypes
        if let dir = UserDefaults.standard.string(forKey: "lastInputDir") {
            panel.directoryURL = URL(fileURLWithPath: dir)
        }
        presentOpenPanel(panel) { [weak self] response in
            guard let self, response == .OK else { return }
            if let first = panel.urls.first {
                UserDefaults.standard.set(Self.dirOf(first.path), forKey: "lastInputDir")
            }
            Task { await self.addPaths(panel.urls.map(\.path)) }
        }
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
        presentOpenPanel(panel) { [weak self] response in
            guard let self, response == .OK, let url = panel.url else { return }
            self.outputDir = url.path
            UserDefaults.standard.set(url.path, forKey: "lastOutputDir")
        }
    }

    func clearOutputDir() {
        outputDir = nil
    }

    // MARK: - Files

    func addPaths(_ paths: [String]) async {
        guard !paths.isEmpty else { return }
        let incoming = InputFiles.expand(paths)
        var existing = Set(files.map(\.path))
        var newFiles: [String] = []
        for path in incoming where !existing.contains(path) {
            existing.insert(path)
            files.append(InputFile(path: path))
            newFiles.append(path)
        }
        if !newFiles.isEmpty {
            await detectAndApplyLanguage(newFiles)
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
        expandedLogs.remove(path)
        if selectedFile == path {
            clearFileSelection()
        }
    }

    func toggleLog(_ path: String) {
        if expandedLogs.contains(path) {
            expandedLogs.remove(path)
        } else {
            expandedLogs.insert(path)
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
            let detected = await Task.detached { [calibre] in
                EpubBook.language(at: path) ?? calibre.detectLanguage(path: path)
            }.value
            language = detected
            if let idx = files.firstIndex(where: { $0.path == path }) {
                files[idx].detectedLanguage = detected
            }
        }
        guard selectedFile == path else { return }
        let name = URL(fileURLWithPath: path).lastPathComponent
        if let language, !language.isEmpty {
            applyLanguage(language, save: false)
            flashStatus(L10n.t("previewingFile", [
                "file": name,
                "lang": L10n.t(BookLanguage.nameKey(language)),
            ]))
        } else {
            flashStatus(L10n.t("previewingFileUnknown", ["file": name]), autoClear: false)
        }
    }

    // MARK: - Convert

    func convert(paths: [String]? = nil) async {
        let requested = paths ?? files.map(\.path)
        let targets = requested.filter { path in
            guard files.contains(where: { $0.path == path }) else { return false }
            if isConverting(path) { return false }
            // Explicit Convert on a row re-runs even after a successful convert.
            if paths == nil, files.first(where: { $0.path == path })?.stage == "done" {
                return false
            }
            return true
        }
        guard !targets.isEmpty else { return }
        guard !selectedDevice.isEmpty else {
            convertStatus = L10n.t("selectDeviceFirst")
            return
        }
        let newJobs = targets.filter { !convertingPaths.contains($0) && !convertJobs.contains($0) }
        guard !newJobs.isEmpty else { return }

        if converting {
            if packCancel.isCancelled { return }
            for path in newJobs {
                convertJobs.append(path)
                convertingPaths.insert(path)
                prepareFileForConvert(path)
            }
            return
        }

        converting = true
        convertJobs = newJobs
        convertingPaths = Set(newJobs)
        packCancel.reset()
        convertStatus = ""
        for path in newJobs { prepareFileForConvert(path) }
        if mode == .xtch {
            await convertXtch()
        } else {
            await convertPdf()
        }
        if packCancel.isCancelled {
            markRemainingCancelled()
        }
        converting = false
        convertingPaths = []
        convertJobs = []
        convertStatus = ""
    }

    func cancel() async {
        packCancel.cancel()
        calibre.cancel()
        WebKitPDF.shared.cancel()
        for path in convertJobs {
            if let i = files.firstIndex(where: { $0.path == path }),
               files[i].stage != "done", files[i].stage != "error", files[i].stage != "cancelled" {
                files[i].stage = "cancelled"
                appendLog(path: path, "Cancelled")
            }
        }
        convertJobs = []
    }

    func openPreview(_ file: InputFile) async {
        guard file.canPreviewXtch, let xtch = file.outputPath else { return }
        let name = URL(fileURLWithPath: xtch).lastPathComponent
        previewLoadGeneration += 1
        previewDocument = nil
        preview = PreviewSession(
            path: xtch,
            title: L10n.t("previewTitleFor", ["name": name]),
            status: L10n.t("renderingPages", ["from": "1", "to": "1"])
        )
        do {
            let doc = try await Task.detached {
                try XtchPreview.Document(url: URL(fileURLWithPath: xtch))
            }.value
            guard preview?.path == xtch else { return }
            previewDocument = doc
            if var session = preview {
                session.pageCount = doc.pageCount
                preview = session
            }
            if doc.pageCount == 0 {
                if var session = preview {
                    session.loading = false
                    session.status = L10n.t("noPages")
                    preview = session
                }
                return
            }
            if let n = preview?.pagesPerScreen, n > 0 {
                await loadPreviewScreen(0)
            }
        } catch {
            if var session = preview, session.path == xtch {
                session.loading = false
                session.status = L10n.t("errorMsg", ["msg": error.localizedDescription])
                preview = session
            }
        }
    }

    func previewNext() async {
        guard let session = preview, session.pagesPerScreen > 0 else { return }
        await previewGoToScreen(session.currentPage / session.pagesPerScreen + 1)
    }

    func previewPrevious() async {
        guard let session = preview, session.pagesPerScreen > 0 else { return }
        await previewGoToScreen(session.currentPage / session.pagesPerScreen - 1)
    }

    /// `screen` is a 0-based index of a window of `pagesPerScreen` pages.
    func previewGoToScreen(_ screen: Int) async {
        guard let session = preview, previewDocument != nil, session.pageCount > 0,
              session.pagesPerScreen > 0 else { return }
        let stride = session.pagesPerScreen
        let screens = Self.previewScreenCount(pages: session.pageCount, stride: stride)
        let clamped = max(0, min(screen, screens - 1))
        let start = clamped * stride
        if session.currentPage == start, session.images.count == min(stride, session.pageCount - start),
           !session.loading { return }
        await loadPreviewScreen(start)
    }

    /// Called when the preview grid's fitted page count changes.
    func previewSetPageCapacity(_ count: Int) async {
        guard count > 0, var session = preview else { return }
        if session.pagesPerScreen == count, !session.images.isEmpty { return }
        session.pagesPerScreen = count
        preview = session
        await loadPreviewScreen(session.currentPage)
    }

    private func loadPreviewScreen(_ start: Int) async {
        guard let doc = previewDocument, let path = preview?.path, doc.pageCount > 0 else { return }
        let stride = max(preview?.pagesPerScreen ?? 0, 1)
        let lastStart = ((doc.pageCount - 1) / stride) * stride
        let clamped = max(0, min(start, lastStart))
        let end = min(clamped + stride, doc.pageCount)
        previewLoadGeneration += 1
        let gen = previewLoadGeneration
        if var session = preview, session.path == path {
            session.currentPage = clamped
            session.loading = true
            session.status = L10n.t("renderingPages", [
                "from": "\(clamped + 1)",
                "to": "\(end)",
            ])
            preview = session
        }
        do {
            let images = try await Task.detached {
                try doc.images(from: clamped, count: stride)
            }.value
            guard gen == previewLoadGeneration, preview?.path == path else { return }
            if var session = preview {
                session.images = images
                session.currentPage = clamped
                session.loading = false
                session.status = L10n.t("showingPages", [
                    "from": "\(clamped + 1)",
                    "to": "\(end)",
                    "total": "\(session.pageCount)",
                ])
                preview = session
            }
        } catch {
            guard gen == previewLoadGeneration, preview?.path == path else { return }
            if var session = preview {
                session.loading = false
                session.status = L10n.t("errorMsg", ["msg": error.localizedDescription])
                preview = session
            }
        }
    }

    static func previewScreenCount(pages: Int, stride: Int = 1) -> Int {
        let n = max(stride, 1)
        guard pages > 0 else { return 0 }
        return (pages + n - 1) / n
    }

    private func convertPdf() async {
        guard let dev = devices.first(where: { $0.key == selectedDevice }) else {
            convertStatus = L10n.t("selectDeviceFirst")
            return
        }
        let panel = dev.panelSize
        let serif = fontSerif, sans = fontSans, mono = fontMono, fontSize = fontSize
        let cancel = packCancel
        while !cancel.isCancelled, let path = popConvertJob() {
            guard let idx = files.firstIndex(where: { $0.path == path }) else { continue }
            if URL(fileURLWithPath: path).pathExtension.lowercased() == "pdf" {
                files[idx].stage = "done"
                files[idx].message = "Skipping (already PDF)"
                appendLog(path: path, "Skipping (already PDF)")
                continue
            }
            let dest = outputDirectory(for: path).appendingPathComponent(
                "\(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)_\(selectedDevice).pdf")
            files[idx].stage = "convert"
            files[idx].percent = 0
            do {
                try await convertEbookToPDF(
                    src: URL(fileURLWithPath: path), dest: dest,
                    width: panel.width, height: panel.height,
                    serif: serif, sans: sans, mono: mono, fontSize: fontSize, path: path)
                if let i = files.firstIndex(where: { $0.path == path }) {
                    files[i].stage = "done"
                    files[i].percent = 100
                    files[i].outputPath = dest.path
                    appendLog(path: path, "Wrote \(dest.path)")
                }
            } catch {
                markConvertError(path: path, error: error)
                if cancel.isCancelled { break }
            }
        }
    }

    private func convertXtch() async {
        guard let dev = devices.first(where: { $0.key == selectedDevice }) else {
            convertStatus = L10n.t("selectDeviceFirst")
            return
        }
        let panel = dev.panelSize
        let width = panel.width
        let height = panel.height
        let supersample = max(dev.supersample, 1)
        let compress = pageCompression
        let cancel = packCancel

        while !cancel.isCancelled, let path = popConvertJob() {
            guard let idx = files.firstIndex(where: { $0.path == path }) else { continue }
            do {
                let dest = xtchDestination(for: path)
                let srcURL = URL(fileURLWithPath: path)
                let ext = srcURL.pathExtension.lowercased()
                if convertEngine == .webkit, ext != "pdf", WebKitPDF.canConvert(extension: ext) {
                    files[idx].stage = "convert"
                    files[idx].percent = 0
                    appendLog(path: path, "WebKit → \(dest.path)")
                    try await WebKitPDF.shared.ebookToXtch(
                        src: srcURL, dest: dest,
                        pageWidth: width, pageHeight: height,
                        serif: fontSerif, sans: fontSans, mono: fontMono, fontSize: fontSize,
                        supersample: supersample, pageCompression: compress,
                        onProgress: { percent, message in
                            self.setCalibreProgress(path: path, percent: percent, message: message)
                        },
                        onLog: { line in
                            self.appendLog(path: path, line)
                        },
                        shouldCancel: { cancel.isCancelled }
                    )
                    if let i = files.firstIndex(where: { $0.path == path }) {
                        files[i].stage = "done"
                        files[i].percent = 100
                        files[i].outputPath = dest.path
                        appendLog(path: path, "Wrote \(dest.path)")
                    }
                    continue
                }
                var pdfURL = srcURL
                if ext != "pdf" {
                    files[idx].stage = "convert"
                    files[idx].percent = 0
                    let pdfDest = outputDirectory(for: path)
                        .appendingPathComponent(
                            "\(srcURL.deletingPathExtension().lastPathComponent)_\(selectedDevice).pdf")
                    try await convertEbookToPDF(
                        src: srcURL, dest: pdfDest,
                        width: width, height: height,
                        serif: fontSerif, sans: fontSans, mono: fontMono,
                        fontSize: fontSize, path: path)
                    if cancel.isCancelled { throw XtchError.message("cancelled") }
                    pdfURL = pdfDest
                }
                files[idx].stage = "pack"
                files[idx].percent = 0
                appendLog(path: path, "Packing \(pdfURL.lastPathComponent) → \(dest.lastPathComponent)")
                let destURL = dest
                let w = width, h = height, ss = supersample
                try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                    DispatchQueue.global(qos: .userInitiated).async {
                        let uiLock = NSLock()
                        var lastUI = Date.distantPast
                        do {
                            try XtchPacker.pack(pdfURL: pdfURL, destURL: destURL, options: .init(
                                width: w, height: h, supersample: ss,
                                pageCompression: compress,
                                onPage: { n, total in
                                    let now = Date()
                                    uiLock.lock()
                                    let send = n == 1 || n == total || now.timeIntervalSince(lastUI) >= 0.1
                                    if send { lastUI = now }
                                    uiLock.unlock()
                                    guard send else { return }
                                    DispatchQueue.main.async {
                                        self.setPackProgress(path: path, page: n, total: total)
                                    }
                                },
                                shouldCancel: { cancel.isCancelled }
                            ))
                            cont.resume()
                        } catch {
                            cont.resume(throwing: error)
                        }
                    }
                }
                if let i = files.firstIndex(where: { $0.path == path }) {
                    files[i].stage = "done"
                    files[i].percent = 100
                    files[i].outputPath = destURL.path
                    appendLog(path: path, "Wrote \(destURL.path)")
                }
            } catch {
                let cancelled = cancel.isCancelled
                    || error.localizedDescription.lowercased().contains("cancelled")
                if let i = files.firstIndex(where: { $0.path == path }) {
                    files[i].stage = cancelled ? "cancelled" : "error"
                    files[i].message = cancelled ? nil : error.localizedDescription
                    files[i].percent = cancelled ? files[i].percent : 0
                }
                if cancelled {
                    appendLog(path: path, "Cancelled")
                } else {
                    logConvertError(path: path, error: error)
                }
                if cancelled { break }
            }
        }
    }

    private func setPackProgress(path: String, page: Int, total: Int) {
        guard let i = files.firstIndex(where: { $0.path == path }) else { return }
        files[i].stage = "pack"
        files[i].percent = total > 0 ? Double(page) / Double(total) * 100 : 0
        files[i].message = "Packing page \(page)/\(total)"
        if page == 1 || page == total {
            appendLog(path: path, "Packing page \(page)/\(total)")
        }
    }

    private func presentOpenPanel(_ panel: NSOpenPanel, completion: @escaping (NSApplication.ModalResponse) -> Void) {
        guard !filePanelOpen else { return }
        filePanelOpen = true
        let finish: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            Task { @MainActor in
                self?.filePanelOpen = false
                completion(response)
            }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow ?? NSApp.windows.first(where: \.isVisible) {
            panel.beginSheetModal(for: window, completionHandler: finish)
        } else {
            panel.begin(completionHandler: finish)
        }
    }

    private func outputDirectory(for path: String) -> URL {
        if let outputDir { return URL(fileURLWithPath: outputDir, isDirectory: true) }
        return URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("output", isDirectory: true)
    }

    private func xtchDestination(for path: String) -> URL {
        let stem = AsciiText.slug(URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent)
        return outputDirectory(for: path).appendingPathComponent("\(stem)_\(selectedDevice).xtch")
    }

    // MARK: - Settings

    func languageChanged(_ newValue: String) {
        applyLanguage(newValue, save: true)
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
        storedConfig.fontSerif = serif
        storedConfig.fontSans = sans
        storedConfig.fontMono = mono
        storedConfig.fontSize = fontSize
        storedConfig.language = language
        if mode == .xtch {
            storedConfig.pageCompression = pageCompression
        }
        do {
            try DeviceConfigStore.save(storedConfig, kind: mode.rawValue)
        } catch {
            settingsError = error.localizedDescription
        }
    }

    func saveDevices(_ drafts: [DeviceDraft], defaultKey: String) async throws {
        guard !drafts.isEmpty else { throw AppError.message(L10n.t("errAtLeastOneDevice")) }
        var seen = Set<String>()
        var devices: [DeviceInfo] = []
        for draft in drafts {
            let key = draft.key.trimmingCharacters(in: .whitespaces)
            if key.isEmpty { throw AppError.message(L10n.t("errEmptyKey")) }
            if seen.contains(key) { throw AppError.message(L10n.t("errDuplicateKey", ["key": key])) }
            seen.insert(key)
            devices.append(DeviceInfo(
                key: key, label: draft.label, width: draft.width, height: draft.height,
                supersample: draft.supersample, orientation: draft.orientation))
        }
        storedConfig.devices = devices
        storedConfig.defaultKey = seen.contains(defaultKey) ? defaultKey : devices.first?.key
        try DeviceConfigStore.save(storedConfig, kind: mode.rawValue)
        await reloadForMode()
    }

    private func applyLanguage(_ language: String, save: Bool) {
        self.language = language
        let preset = BookLanguage.recommended(language)
        fontSerif = preset.serif
        fontSans = preset.sans
        fontMono = preset.mono
        if save {
            Task { await saveSettings() }
        }
    }

    private func applyConfigToForm() {
        ignoreSaves = true
        defer { ignoreSaves = false }
        language = storedConfig.language ?? BookLanguage.detectFromLocale()
        pageCompression = storedConfig.pageCompression
        fontSerif = storedConfig.fontSerif
        fontSans = storedConfig.fontSans
        fontMono = storedConfig.fontMono
        fontSize = storedConfig.fontSize
        settingsError = ""
        settingsStatus = ""
    }

    private func detectAndApplyLanguage(_ newFiles: [String]) async {
        let sample = Array(newFiles.prefix(20))
        var counts: [String: Int] = [:]
        for path in sample {
            let lang = await Task.detached { [calibre] in
                EpubBook.language(at: path) ?? calibre.detectLanguage(path: path)
            }.value
            if let idx = files.firstIndex(where: { $0.path == path }) {
                files[idx].detectedLanguage = lang
            }
            if let lang, !lang.isEmpty {
                counts[lang, default: 0] += 1
            }
        }
        guard let detected = counts.max(by: { $0.value < $1.value })?.key, detected != language else { return }
        applyLanguage(detected, save: true)
        flashStatus(L10n.t("detectedApplied", ["lang": L10n.t(BookLanguage.nameKey(detected))]))
    }

    // MARK: - Convert helpers

    private func prepareFileForConvert(_ path: String) {
        guard let i = files.firstIndex(where: { $0.path == path }) else { return }
        files[i].stage = nil
        files[i].message = nil
        files[i].percent = nil
        files[i].outputPath = nil
        files[i].log = []
        expandedLogs.insert(path)
    }

    private func popConvertJob() -> String? {
        while let path = convertJobs.first {
            convertJobs.removeFirst()
            if files.contains(where: { $0.path == path }) { return path }
        }
        return nil
    }

    /// PDF files always come from Calibre. WebKit snapshots make huge PDFs
    /// (fonts re-embedded per page); ebook-convert print-to-PDF does not.
    private func convertEbookToPDF(
        src: URL, dest: URL, width: Int, height: Int,
        serif: String, sans: String, mono: String, fontSize: Int,
        path: String
    ) async throws {
        let size = "\(width)x\(height)"
        appendLog(path: path, "ebook-convert → \(dest.path)")
        try await runCalibre(
            src: src, dest: dest, size: size,
            serif: serif, sans: sans, mono: mono, fontSize: fontSize, path: path)
    }

    private func runCalibre(
        src: URL, dest: URL, size: String,
        serif: String, sans: String, mono: String, fontSize: Int, path: String
    ) async throws {
        let calibre = self.calibre
        let cancel = packCancel
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    try calibre.ebookToPDF(
                        src: src, dest: dest, size: size,
                        serif: serif, sans: sans, mono: mono, fontSize: fontSize,
                        onProgress: { percent, message in
                            DispatchQueue.main.async {
                                self.setCalibreProgress(path: path, percent: percent, message: message)
                            }
                        },
                        onLog: { line in
                            DispatchQueue.main.async {
                                self.appendLog(path: path, line)
                            }
                        },
                        shouldCancel: { cancel.isCancelled }
                    )
                    cont.resume()
                } catch {
                    cont.resume(throwing: error)
                }
            }
        }
    }

    private func setCalibreProgress(path: String, percent: Int, message: String) {
        guard let i = files.firstIndex(where: { $0.path == path }) else { return }
        files[i].stage = "convert"
        files[i].percent = Double(percent)
        files[i].message = message
    }

    private func markConvertError(path: String, error: Error) {
        let cancelled = packCancel.isCancelled || isCancelError(error)
        if let i = files.firstIndex(where: { $0.path == path }) {
            files[i].stage = cancelled ? "cancelled" : "error"
            files[i].message = cancelled ? nil : shortError(error)
            files[i].percent = cancelled ? files[i].percent : 0
        }
        if cancelled {
            appendLog(path: path, "Cancelled")
        } else {
            logConvertError(path: path, error: error)
        }
    }

    private func markRemainingCancelled() {
        for i in files.indices where convertingPaths.contains(files[i].path)
            && files[i].stage != "done" && files[i].stage != "error" && files[i].stage != "cancelled" {
            files[i].stage = "cancelled"
            appendLog(path: files[i].path, "Cancelled")
        }
    }

    private func appendLog(path: String, _ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let i = files.firstIndex(where: { $0.path == path }) else { return }
        files[i].log.append(trimmed)
        if files[i].log.count > 2000 {
            files[i].log.removeFirst(files[i].log.count - 2000)
        }
    }

    private func logConvertError(path: String, error: Error) {
        if let error = error as? CalibreError, case .failed = error {
            appendLog(path: path, "ebook-convert failed")
            return
        }
        if let error = error as? WebKitConvertError, case .failed(let s) = error {
            appendLog(path: path, "WebKit convert failed: \(s)")
            return
        }
        appendLog(path: path, error.localizedDescription)
    }

    private func shortError(_ error: Error) -> String {
        if let error = error as? CalibreError, case .failed = error {
            return "ebook-convert failed"
        }
        if let error = error as? WebKitConvertError, case .failed(let s) = error {
            if s.count > 200 { return "WebKit convert failed: " + String(s.prefix(180)) + "…" }
            return "WebKit convert failed: \(s)"
        }
        let text = error.localizedDescription
        if text.count > 200 { return String(text.prefix(200)) + "…" }
        return text
    }

    private func isCancelError(_ error: Error) -> Bool {
        if let error = error as? CalibreError, case .cancelled = error { return true }
        if let error = error as? WebKitConvertError, case .cancelled = error { return true }
        return error.localizedDescription.lowercased().contains("cancelled")
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

    private static func dirOf(_ path: String) -> String {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
            return path
        }
        return URL(fileURLWithPath: path).deletingLastPathComponent().path
    }
}
