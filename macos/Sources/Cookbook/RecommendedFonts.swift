import Foundation

struct FontPreset: Hashable {
    var serif: String
    var sans: String
    var mono: String
}

enum BookLanguage {
    static let all: [String] = [
        "latin", "japanese", "chinese_simplified", "chinese_traditional",
        "korean", "cyrillic", "greek", "arabic", "hebrew", "devanagari", "thai",
        "bengali", "tamil", "telugu", "kannada", "malayalam", "gujarati",
        "gurmukhi", "odia", "sinhala", "myanmar", "ethiopic", "khmer",
        "other",
    ]

    static let romanizable: Set<String> = [
        "japanese", "chinese_simplified", "chinese_traditional", "korean",
    ]

    static func optKey(_ language: String) -> String {
        camelKey("opt", language)
    }

    static func nameKey(_ language: String) -> String {
        camelKey("langName", language)
    }

    static func asciiRomanization(for language: String) -> String {
        if language == "chinese_simplified" || language == "chinese_traditional" {
            return "chinese"
        }
        return language
    }

    static func detectFromLocale() -> String {
        let locale = (Locale.preferredLanguages.first ?? Locale.current.identifier).lowercased()
        if locale.hasPrefix("ja") { return "japanese" }
        if locale.hasPrefix("zh") {
            if locale.contains("hant") || locale.contains("-tw")
                || locale.contains("-hk") || locale.contains("-mo") {
                return "chinese_traditional"
            }
            return "chinese_simplified"
        }
        if locale.hasPrefix("yue") { return "chinese_traditional" }
        if locale.hasPrefix("kok") { return "devanagari" }
        if locale.hasPrefix("ko") { return "korean" }
        let cyrillic = ["ru", "uk", "bg", "sr", "mk", "be", "mn", "kk", "ky", "tt", "tg"]
        if cyrillic.contains(where: { locale.hasPrefix($0) }) { return "cyrillic" }
        if locale.hasPrefix("el") { return "greek" }
        let arabic = ["ar", "fa", "ur", "ps", "ku", "ug", "sd", "bal"]
        if arabic.contains(where: { locale.hasPrefix($0) }) { return "arabic" }
        if locale.hasPrefix("he") || locale.hasPrefix("iw") || locale.hasPrefix("yi") { return "hebrew" }
        let deva = ["hi", "mr", "ne", "sa", "bho", "mai", "doi"]
        if deva.contains(where: { locale.hasPrefix($0) }) { return "devanagari" }
        if locale.hasPrefix("th") { return "thai" }
        if locale.hasPrefix("bn") || locale.hasPrefix("as") { return "bengali" }
        if locale.hasPrefix("ta") { return "tamil" }
        if locale.hasPrefix("te") { return "telugu" }
        if locale.hasPrefix("kn") { return "kannada" }
        if locale.hasPrefix("ml") { return "malayalam" }
        if locale.hasPrefix("gu") { return "gujarati" }
        if locale.hasPrefix("pa") { return "gurmukhi" }
        if locale.hasPrefix("or") { return "odia" }
        if locale.hasPrefix("si") { return "sinhala" }
        if locale.hasPrefix("my") { return "myanmar" }
        if locale.hasPrefix("am") || locale.hasPrefix("ti") { return "ethiopic" }
        if locale.hasPrefix("km") { return "khmer" }
        return "latin"
    }

    static func recommended(_ language: String) -> FontPreset {
        presets[language] ?? presets["latin"]!
    }

    private static func camelKey(_ prefix: String, _ language: String) -> String {
        let rest = language.split(separator: "_").map { part -> String in
            let s = String(part)
            return s.prefix(1).uppercased() + s.dropFirst()
        }.joined()
        return prefix + rest
    }

    private static let presets: [String: FontPreset] = [
        "latin": .init(serif: "Times New Roman", sans: "Helvetica", mono: "Menlo"),
        "japanese": .init(serif: "Hiragino Mincho ProN", sans: "Hiragino Sans", mono: "Menlo"),
        "chinese_simplified": .init(serif: "Songti SC", sans: "PingFang SC", mono: "Menlo"),
        "chinese_traditional": .init(serif: "Songti TC", sans: "PingFang TC", mono: "Menlo"),
        "korean": .init(serif: "AppleMyungjo", sans: "Apple SD Gothic Neo", mono: "Menlo"),
        "cyrillic": .init(serif: "Times New Roman", sans: "Helvetica", mono: "Menlo"),
        "greek": .init(serif: "Times New Roman", sans: "Helvetica", mono: "Menlo"),
        "arabic": .init(serif: "Al Bayan", sans: "Geeza Pro", mono: "Geeza Pro"),
        "hebrew": .init(serif: "New Peninim MT", sans: "Arial Hebrew", mono: "Arial Hebrew"),
        "devanagari": .init(serif: "Devanagari Sangam MN", sans: "Devanagari Sangam MN", mono: "Devanagari Sangam MN"),
        "thai": .init(serif: "Ayuthaya", sans: "Thonburi", mono: "Thonburi"),
        "bengali": .init(serif: "Kohinoor Bangla", sans: "Kohinoor Bangla", mono: "Kohinoor Bangla"),
        "tamil": .init(serif: "Kohinoor Tamil", sans: "Kohinoor Tamil", mono: "Kohinoor Tamil"),
        "telugu": .init(serif: "Kohinoor Telugu", sans: "Kohinoor Telugu", mono: "Kohinoor Telugu"),
        "kannada": .init(serif: "Kannada Sangam MN", sans: "Kannada Sangam MN", mono: "Kannada Sangam MN"),
        "malayalam": .init(serif: "Malayalam Sangam MN", sans: "Malayalam Sangam MN", mono: "Malayalam Sangam MN"),
        "gujarati": .init(serif: "Gujarati Sangam MN", sans: "Gujarati Sangam MN", mono: "Gujarati Sangam MN"),
        "gurmukhi": .init(serif: "Gurmukhi MN", sans: "Gurmukhi MN", mono: "Gurmukhi MN"),
        "odia": .init(serif: "Oriya Sangam MN", sans: "Oriya Sangam MN", mono: "Oriya Sangam MN"),
        "sinhala": .init(serif: "Sinhala Sangam MN", sans: "Sinhala Sangam MN", mono: "Sinhala Sangam MN"),
        "myanmar": .init(serif: "Myanmar MN", sans: "Myanmar Sangam MN", mono: "Myanmar MN"),
        "ethiopic": .init(serif: "Kefa", sans: "Kefa", mono: "Kefa"),
        "khmer": .init(serif: "Khmer MN", sans: "Khmer Sangam MN", mono: "Khmer MN"),
        "other": .init(serif: "Helvetica Neue", sans: "Helvetica Neue", mono: "Menlo"),
    ]
}
