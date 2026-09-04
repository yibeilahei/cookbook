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
        let urls = [
            Bundle.module.url(forResource: "strings", withExtension: "json"),
            Bundle.main.url(forResource: "strings", withExtension: "json"),
        ].compactMap { $0 }
        for url in urls {
            if let data = try? Data(contentsOf: url),
               let obj = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
                return obj
            }
        }
        return [:]
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
