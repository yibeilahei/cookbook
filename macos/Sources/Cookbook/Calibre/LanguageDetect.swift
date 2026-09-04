import Foundation

/// Map Calibre/ebook-meta language codes to Cookbook script buckets.
enum LanguageDetect {
    static let chineseCodes: Set<String> = ["chi", "zho", "zh", "yue"]

    static func bucket(for code: String) -> String {
        codes[code] ?? "other"
    }

    static func chineseScript(_ text: String) -> String? {
        let simp = CharacterSet(charactersIn: "国对会后时来东业发经现说这为过门开关")
        let trad = CharacterSet(charactersIn: "國對會後時來東業發經現說這為過門開關")
        var s = 0, t = 0
        for ch in text.unicodeScalars {
            if simp.contains(ch) { s += 1 }
            if trad.contains(ch) { t += 1 }
        }
        if s > 0 && t == 0 { return "chinese_simplified" }
        if t > 0 && s == 0 { return "chinese_traditional" }
        return nil
    }

    private static let codes: [String: String] = [
        "jpn": "japanese", "ja": "japanese",
        "kor": "korean", "ko": "korean",
        "rus": "cyrillic", "ru": "cyrillic", "ukr": "cyrillic", "uk": "cyrillic",
        "bul": "cyrillic", "bg": "cyrillic", "srp": "cyrillic", "sr": "cyrillic",
        "mkd": "cyrillic", "mk": "cyrillic", "bel": "cyrillic", "be": "cyrillic",
        "mon": "cyrillic", "mn": "cyrillic", "kaz": "cyrillic", "kk": "cyrillic",
        "kir": "cyrillic", "ky": "cyrillic", "tat": "cyrillic", "tt": "cyrillic",
        "tgk": "cyrillic", "tg": "cyrillic",
        "gre": "greek", "ell": "greek", "el": "greek",
        "ara": "arabic", "ar": "arabic", "per": "arabic", "fas": "arabic", "fa": "arabic",
        "urd": "arabic", "ur": "arabic", "pus": "arabic", "ps": "arabic",
        "kur": "arabic", "ku": "arabic", "uig": "arabic", "ug": "arabic",
        "snd": "arabic", "sd": "arabic", "bal": "arabic", "pnb": "arabic", "lah": "arabic",
        "heb": "hebrew", "he": "hebrew", "iw": "hebrew", "yid": "hebrew", "yi": "hebrew",
        "hin": "devanagari", "hi": "devanagari", "mar": "devanagari", "mr": "devanagari",
        "nep": "devanagari", "ne": "devanagari", "san": "devanagari", "sa": "devanagari",
        "bho": "devanagari", "mai": "devanagari", "kok": "devanagari", "doi": "devanagari",
        "ben": "bengali", "bn": "bengali", "asm": "bengali", "as": "bengali",
        "tam": "tamil", "ta": "tamil", "tel": "telugu", "te": "telugu",
        "kan": "kannada", "kn": "kannada", "mal": "malayalam", "ml": "malayalam",
        "guj": "gujarati", "gu": "gujarati", "pan": "gurmukhi", "pa": "gurmukhi",
        "ori": "odia", "or": "odia", "sin": "sinhala", "si": "sinhala",
        "bur": "myanmar", "mya": "myanmar", "my": "myanmar",
        "amh": "ethiopic", "am": "ethiopic", "tir": "ethiopic", "ti": "ethiopic",
        "khm": "khmer", "km": "khmer", "tha": "thai", "th": "thai",
        "eng": "latin", "en": "latin", "fre": "latin", "fra": "latin", "fr": "latin",
        "ger": "latin", "deu": "latin", "de": "latin", "spa": "latin", "es": "latin",
        "por": "latin", "pt": "latin", "ita": "latin", "it": "latin",
        "dut": "latin", "nld": "latin", "nl": "latin", "swe": "latin", "sv": "latin",
        "nor": "latin", "nob": "latin", "nno": "latin", "no": "latin",
        "dan": "latin", "da": "latin", "fin": "latin", "fi": "latin",
        "pol": "latin", "pl": "latin", "cze": "latin", "ces": "latin", "cs": "latin",
        "slo": "latin", "slk": "latin", "sk": "latin", "hun": "latin", "hu": "latin",
        "rum": "latin", "ron": "latin", "ro": "latin", "hrv": "latin", "hr": "latin",
        "slv": "latin", "sl": "latin", "est": "latin", "et": "latin",
        "lav": "latin", "lv": "latin", "lit": "latin", "lt": "latin",
        "tur": "latin", "tr": "latin", "ind": "latin", "id": "latin",
        "may": "latin", "msa": "latin", "ms": "latin", "vie": "latin", "vi": "latin",
        "tgl": "latin", "fil": "latin", "tl": "latin", "cat": "latin", "ca": "latin",
        "eus": "latin", "baq": "latin", "eu": "latin", "glg": "latin", "gl": "latin",
        "ice": "latin", "isl": "latin", "is": "latin", "gle": "latin", "ga": "latin",
        "wel": "latin", "cym": "latin", "cy": "latin", "afr": "latin", "af": "latin",
        "alb": "latin", "sqi": "latin", "sq": "latin", "aze": "latin", "az": "latin",
        "uzb": "latin", "uz": "latin", "swa": "latin", "sw": "latin",
    ]
}
