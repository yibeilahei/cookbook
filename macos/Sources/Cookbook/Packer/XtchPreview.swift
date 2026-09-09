import AppKit
import Foundation

/// Unpack XTCH pages to NSImage for the in-app preview sheet.
enum XtchPreview {

    /// Parsed XTCH file; decode pages on demand so a long book stays in RAM as one file, not every bitmap.
    struct Document: Sendable {
        let data: Data
        let pageCount: Int
        private let pageTableOff: Int

        init(url: URL) throws {
            let data = try Data(contentsOf: url)
            if data.count < XtchFormat.headerSize {
                throw XtchError.message("not an XTCH file: \(url.path)")
            }
            let magic = data.leUInt32(at: 0)
            if magic != XtchFormat.xtchMagic {
                throw XtchError.message("not an XTCH file: \(url.path)")
            }
            self.data = data
            self.pageCount = Int(data.leUInt16(at: 6))
            self.pageTableOff = Int(data.leUInt64(at: 24))
        }

        func image(at index: Int) throws -> NSImage {
            guard index >= 0, index < pageCount else {
                throw XtchError.message("page \(index + 1) is out of range")
            }
            let entry = pageTableOff + index * XtchFormat.pageTableEntrySize
            guard entry + XtchFormat.pageTableEntrySize <= data.count else {
                throw XtchError.message("page \(index + 1) table entry is invalid")
            }
            let offset = Int(data.leUInt64(at: entry))
            let size = Int(data.leUInt32(at: entry + 8))
            guard offset >= 0, size >= 0, offset + size <= data.count else {
                throw XtchError.message("page \(index + 1) table entry is invalid")
            }
            let page = data.subdata(in: offset..<(offset + size))
            let unpacked = try XtchPacker.unpackPlanes(page)
            guard let image = XtchPreview.nsImage(
                gray: unpacked.gray, width: unpacked.width, height: unpacked.height
            ) else {
                throw XtchError.message("could not render page \(index + 1)")
            }
            return image
        }

        func images(from start: Int, count: Int) throws -> [NSImage] {
            guard pageCount > 0, count > 0 else { return [] }
            let from = max(0, start)
            let to = min(from + count, pageCount)
            guard from < to else { return [] }
            return try (from..<to).map { try image(at: $0) }
        }
    }

    private static func nsImage(gray: [UInt8], width: Int, height: Int) -> NSImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceWhite, bytesPerRow: width, bitsPerPixel: 8
        ), let base = rep.bitmapData else { return nil }
        gray.withUnsafeBytes { src in
            if let p = src.baseAddress {
                UnsafeMutableRawPointer(base).copyMemory(from: p, byteCount: width * height)
            }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
}
