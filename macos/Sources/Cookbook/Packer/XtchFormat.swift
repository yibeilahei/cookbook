import Foundation

/// XTCH container and XTH page constants. Layout: docs/xtch.md
enum XtchFormat {
    static let xtchMagic: UInt32 = 0x4843_5458 // "XTCH"
    static let xthMagic: UInt32 = 0x0048_5458  // "XTH\0"
    static let headerSize = 56
    static let titleOffset = 0x38
    static let titleLen = 128
    static let authorLen = 64
    static let metadataSize = 256
    static let chapterTableOff = titleOffset + metadataSize // 0x138
    static let pageTableEntrySize = 16
    static let xthPageHeaderSize = 22
    static let chapterEntrySize = 96
    static let chapterNameLen = 80
}

struct XtchChapter {
    var name: String
    var startPage: Int // 1-based
    var endPage: Int
}

enum XtchError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self {
        case .message(let s): return s
        }
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var v = value.littleEndian
        Swift.withUnsafeBytes(of: &v) { append(contentsOf: $0) }
    }

    func leUInt8(at offset: Int) -> UInt8 { self[offset] }

    func leUInt16(at offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func leUInt32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }

    func leUInt64(at offset: Int) -> UInt64 {
        UInt64(leUInt32(at: offset)) | UInt64(leUInt32(at: offset + 4)) << 32
    }
}
