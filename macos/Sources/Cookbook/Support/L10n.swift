import Foundation

/// UI-chrome strings. Follows the OS locale; independent of the book's Language setting.
enum L10n {
    private static let table: [String: [String: String]] = load()
    private static let language: String = detectUiLanguage()

    static func t(_ key: String, _ vars: [String: String] = [:]) -> String {
        var str = table[language]?[key] ?? table["english"]?[key] ?? key
        for (name, value) in vars {
            str = str.replacingOccurrences(of: "{\(name)}", with: value)
        }
        return str
    }

    private static func load() -> [String: [String: String]] {
        for url in stringsCandidates() {
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
                return obj
            }
        }
        return [:]
    }

    /// Do not use `Bundle.module`: SwiftPM's accessor looks for
    /// `Cookbook.app/Cookbook_Cookbook.bundle` and `fatalError`s in a packaged app.
    private static func stringsCandidates() -> [URL] {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL { dirs.append(resources) }
        dirs.append(Bundle.main.bundleURL)
        dirs.append(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources"))
        let exeDir = URL(fileURLWithPath: CommandLine.arguments[0])
            .standardized.deletingLastPathComponent()
        dirs.append(exeDir)

        var urls: [URL] = []
        if let url = Bundle.main.url(forResource: "strings", withExtension: "json") {
            urls.append(url)
        }
        for dir in dirs {
            urls.append(dir.appendingPathComponent("strings.json"))
            urls.append(dir.appendingPathComponent("Cookbook_Cookbook.bundle/strings.json"))
        }
        var seen = Set<String>()
        return urls.filter { url in
            seen.insert(url.path).inserted
                && FileManager.default.isReadableFile(atPath: url.path)
        }
    }

    private static func detectUiLanguage() -> String {
        let locale = (Locale.preferredLanguages.first ?? Locale.current.identifier).lowercased()
        if locale.hasPrefix("ja") { return "japanese" }
        if locale.hasPrefix("ko") { return "korean" }
        if locale.hasPrefix("zh-tw") || locale.hasPrefix("zh-hk")
            || locale.hasPrefix("zh-mo") || locale.hasPrefix("zh-hant")
            || locale.contains("hant") {
            return "chineseTraditional"
        }
        if locale.hasPrefix("zh") { return "chineseSimplified" }
        if locale.hasPrefix("es") { return "spanish" }
        if locale.hasPrefix("fr") { return "french" }
        if locale.hasPrefix("de") { return "german" }
        if locale.hasPrefix("pt") { return "portuguese" }
        if locale.hasPrefix("it") { return "italian" }
        if locale.hasPrefix("ru") { return "russian" }
        if locale.hasPrefix("uk") { return "ukrainian" }
        if locale.hasPrefix("pl") { return "polish" }
        if locale.hasPrefix("nl") { return "dutch" }
        if locale.hasPrefix("ar") { return "arabic" }
        if locale.hasPrefix("he") || locale.hasPrefix("iw") { return "hebrew" }
        if locale.hasPrefix("hi") { return "hindi" }
        if locale.hasPrefix("tr") { return "turkish" }
        if locale.hasPrefix("vi") { return "vietnamese" }
        if locale.hasPrefix("id") || locale.hasPrefix("in") { return "indonesian" }
        if locale.hasPrefix("el") { return "greek" }
        if locale.hasPrefix("sv") { return "swedish" }
        if locale.hasPrefix("cs") { return "czech" }
        if locale.hasPrefix("fa") { return "persian" }
        if locale.hasPrefix("th") { return "thai" }
        return "english"
    }
}
