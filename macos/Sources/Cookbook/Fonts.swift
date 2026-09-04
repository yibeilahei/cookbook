import AppKit

struct SystemFont: Identifiable, Hashable {
    var family: String
    var display: String
    var id: String { family }
}

enum FontLister {
    static func list() -> [SystemFont] {
        let mgr = NSFontManager.shared
        var seen = Set<String>()
        var fonts: [SystemFont] = []
        for family in mgr.availableFontFamilies {
            if family.isEmpty || seen.contains(family) { continue }
            seen.insert(family)
            let display = mgr.localizedName(forFamily: family, face: nil)
            fonts.append(SystemFont(family: family, display: display))
        }
        fonts.sort { $0.display.localizedCaseInsensitiveCompare($1.display) == .orderedAscending }
        if fonts.isEmpty {
            fonts = ["Hiragino Mincho ProN", "Hiragino Sans", "Menlo", "Helvetica", "Times New Roman"]
                .map { SystemFont(family: $0, display: $0) }
        }
        return fonts
    }
}
