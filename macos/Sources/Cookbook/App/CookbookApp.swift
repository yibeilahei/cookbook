import AppKit
import SwiftUI

/// SwiftUI entry point. Conversion runs in-process (WebKit or Calibre + Swift packer).

@main
struct CookbookApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                .onAppear {
                    NSApp.setActivationPolicy(.regular)
                    NSApp.activate(ignoringOtherApps: true)
                    model.startIfNeeded()
                    appDelegate.model = model
                }
        }
        .defaultSize(width: 1100, height: 740)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button(L10n.t("addFiles")) { model.pickInputs() }
                    .keyboardShortcut("o")
            }
            CommandMenu(L10n.t("convert")) {
                Button(L10n.t("convert")) {
                    Task { await model.convert() }
                }
                .keyboardShortcut("r")
                .disabled(model.files.isEmpty)
                Button(L10n.t("cancel")) {
                    Task { await model.cancel() }
                }
                .keyboardShortcut(".")
                .disabled(!model.converting)
            }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    var model: AppModel? {
        didSet { flushPendingOpens() }
    }
    private var pendingOpens: [String] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        if ConvertBench.launchIfRequested() { return }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        let paths = urls.map(\.path)
        if model != nil {
            Task { await model?.addPaths(paths) }
        } else {
            pendingOpens.append(contentsOf: paths)
        }
    }

    private func flushPendingOpens() {
        guard let model, !pendingOpens.isEmpty else { return }
        let paths = pendingOpens
        pendingOpens = []
        Task { await model.addPaths(paths) }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model?.stop()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }
}
