import AppKit
import Foundation

/// Unpack XTCH pages to NSImage for the in-app preview sheet.
enum XtchPreview {
    static func images(from url: URL, maxPages: Int = 15) throws -> (images: [NSImage], pageCount: Int) {
        let data = try Data(contentsOf: url)
        if data.count < XtchFormat.headerSize {
            throw XtchError.message("not an XTCH file: \(url.path)")
        }
        let magic = data.leUInt32(at: 0)
        if magic != XtchFormat.xtchMagic {
            throw XtchError.message("not an XTCH file: \(url.path)")
        }
        let pageCount = Int(data.leUInt16(at: 6))
        if pageCount == 0 { return ([], 0) }
        let pageTableOff = Int(data.leUInt64(at: 24))
        let n = maxPages > 0 ? min(maxPages, pageCount) : pageCount
        var images: [NSImage] = []
        for i in 0..<n {
            let entry = pageTableOff + i * XtchFormat.pageTableEntrySize
            let offset = Int(data.leUInt64(at: entry))
            let size = Int(data.leUInt32(at: entry + 8))
            let page = data.subdata(in: offset..<(offset + size))
            let unpacked = try XtchPacker.unpackPlanes(page)
            if let image = nsImage(gray: unpacked.gray, width: unpacked.width, height: unpacked.height) {
                images.append(image)
            }
        }
        return (images, pageCount)
    }

    private static func nsImage(gray: [UInt8], width: Int, height: Int) -> NSImage? {
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceWhite, bytesPerRow: width, bitsPerPixel: 8
        ), let base = rep.bitmapData else { return nil }
        // NSBitmapImageRep / SwiftUI treat row 0 as the bottom of the image.
        // Unpacked gray is top-down (y = 0 is the top of the page).
        gray.withUnsafeBytes { src in
            guard let p = src.bindMemory(to: UInt8.self).baseAddress else { return }
            for y in 0..<height {
                let srcRow = p + (height - 1 - y) * width
                UnsafeMutableRawPointer(base + y * width).copyMemory(from: srcRow, byteCount: width)
            }
        }
        let image = NSImage(size: NSSize(width: width, height: height))
        image.addRepresentation(rep)
        return image
    }
}
