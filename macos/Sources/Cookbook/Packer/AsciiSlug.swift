import Foundation

/// ASCII-safe filenames and chapter names (ICU Latin fold).
enum AsciiText {
    /// Latin-fold (ICU) and collapse whitespace.
    static func fold(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        let ascii = String(latin.unicodeScalars.map { $0.isASCII ? Character($0) : " " })
        return ascii.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    /// ASCII-safe filename stem; `"book"` if nothing remains.
    static func slug(_ text: String) -> String {
        let folded = fold(text).lowercased()
        let mapped = folded.map { ch -> Character in
            (ch.isLetter || ch.isNumber) ? ch : "-"
        }
        let collapsed = String(mapped)
            .split(separator: "-")
            .joined(separator: "-")
        return collapsed.isEmpty ? "book" : collapsed
    }
}
