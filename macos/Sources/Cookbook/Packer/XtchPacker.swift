import AppKit
import Foundation
import PDFKit
import Accelerate

/// Rasterize a PDF and pack 2-bit XTH pages into an XTCH container.
enum XtchPacker {
    struct Options {
        var width: Int
        var height: Int
        var supersample: Int
        var pageCompression: Bool
        var onPage: ((Int, Int) -> Void)?
        var shouldCancel: (() -> Bool)?
    }

    static func pack(pdfURL: URL, destURL: URL, options: Options) throws {
        if options.height % 8 != 0 {
            throw XtchError.message("height \(options.height) must be a multiple of 8")
        }
        guard let doc = PDFDocument(url: pdfURL) else {
            throw XtchError.message("Could not open PDF: \(pdfURL.path)")
        }
        let pageCount = doc.pageCount
        if pageCount == 0 { throw XtchError.message("\(pdfURL.path) has no pages") }
        if pageCount > 0xFFFF { throw XtchError.message("\(pageCount) pages exceeds the 65535 limit") }

        let attrs = doc.documentAttributes ?? [:]
        let title = attrs[PDFDocumentAttribute.titleAttribute] as? String ?? ""
        let author = attrs[PDFDocumentAttribute.authorAttribute] as? String ?? ""
        let chapters = chapters(from: doc, pageCount: pageCount)

        try FileManager.default.createDirectory(
            at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        var pageBodies = [Data](repeating: Data(), count: pageCount)
        var firstError: Error?
        let errorLock = NSLock()
        var completed = 0
        let workers = min(ProcessInfo.processInfo.activeProcessorCount, pageCount)
        let parallel = workers > 1 && pageCount >= 8

        func renderOne(_ i: Int) {
            if options.shouldCancel?() == true { return }
            do {
                pageBodies[i] = try renderPageBody(
                    doc: doc, pageIndex: i, options: options)
                errorLock.lock()
                completed += 1
                let n = completed
                errorLock.unlock()
                options.onPage?(n, pageCount)
            } catch {
                errorLock.lock()
                if firstError == nil { firstError = error }
                errorLock.unlock()
            }
        }

        if parallel {
            DispatchQueue.concurrentPerform(iterations: pageCount) { i in
                if firstError != nil || options.shouldCancel?() == true { return }
                renderOne(i)
            }
        } else {
            for i in 0..<pageCount {
                if options.shouldCancel?() == true {
                    throw XtchError.message("cancelled")
                }
                renderOne(i)
            }
        }
        if options.shouldCancel?() == true { throw XtchError.message("cancelled") }
        if let firstError { throw firstError }

        try writeContainer(
            destURL: destURL, pageBodies: pageBodies, width: options.width,
            height: options.height, chapters: chapters, title: title, author: author)
    }

    private static func renderPageBody(doc: PDFDocument, pageIndex: Int, options: Options) throws -> Data {
        guard let page = doc.page(at: pageIndex) else {
            throw XtchError.message("Missing PDF page \(pageIndex + 1)")
        }
        let gray = try rasterize(page: page, supersample: options.supersample)
        let fitted = fitToPanel(gray.pixels, srcWidth: gray.width, srcHeight: gray.height,
                                srcRow: gray.rowBytes, dstWidth: options.width, dstHeight: options.height)
        var planes = packPlanes(gray: fitted, width: options.width, height: options.height)
        var compression: UInt8 = 0
        if options.pageCompression, let deflated = RawDeflate.compress(planes), deflated.count < planes.count {
            planes = deflated
            compression = 1
        }
        var header = Data()
        header.appendLE(XtchFormat.xthMagic)
        header.appendLE(UInt16(options.width))
        header.appendLE(UInt16(options.height))
        header.appendLE(UInt8(0))
        header.appendLE(compression)
        header.appendLE(UInt32(planes.count))
        header.appendLE(UInt64(0))
        return header + planes
    }

    private struct GrayBuf {
        var pixels: [UInt8]
        var width: Int
        var height: Int
        var rowBytes: Int
    }

    private static func rasterize(page: PDFPage, supersample: Int) throws -> GrayBuf {
        let box = page.bounds(for: .mediaBox)
        let scale = CGFloat(max(supersample, 1))
        let pixelW = max(1, Int((box.width * scale).rounded()))
        let pixelH = max(1, Int((box.height * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: pixelW, pixelsHigh: pixelH,
            bitsPerSample: 8, samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
            colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 8
        ) else {
            throw XtchError.message("Could not allocate page bitmap")
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        guard let gc = NSGraphicsContext(bitmapImageRep: rep) else {
            throw XtchError.message("Could not create graphics context")
        }
        NSGraphicsContext.current = gc
        let ctx = gc.cgContext
        ctx.setFillColor(gray: 1, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: pixelW, height: pixelH))
        ctx.saveGState()
        ctx.translateBy(x: 0, y: CGFloat(pixelH))
        ctx.scaleBy(x: scale, y: -scale)
        ctx.translateBy(x: -box.origin.x, y: -box.origin.y)
        page.draw(with: .mediaBox, to: ctx)
        ctx.restoreGState()

        let row = rep.bytesPerRow
        guard let base = rep.bitmapData else { throw XtchError.message("Empty bitmap") }
        var pixels = [UInt8](repeating: 0, count: row * pixelH)
        pixels.withUnsafeMutableBytes { dst in
            dst.copyMemory(from: UnsafeRawBufferPointer(start: base, count: row * pixelH))
        }
        return GrayBuf(pixels: pixels, width: pixelW, height: pixelH, rowBytes: row)
    }

    private static func fitToPanel(_ src: [UInt8], srcWidth: Int, srcHeight: Int, srcRow: Int,
                                   dstWidth: Int, dstHeight: Int) -> [UInt8] {
        let scale = min(Double(dstWidth) / Double(srcWidth), Double(dstHeight) / Double(srcHeight))
        let newW = max(1, Int((Double(srcWidth) * scale).rounded()))
        let newH = max(1, Int((Double(srcHeight) * scale).rounded()))
        var scaled = [UInt8](repeating: 255, count: newW * newH)
        src.withUnsafeBytes { srcRaw in
            scaled.withUnsafeMutableBytes { dstRaw in
                var srcBuf = vImage_Buffer(
                    data: UnsafeMutableRawPointer(mutating: srcRaw.baseAddress),
                    height: vImagePixelCount(srcHeight),
                    width: vImagePixelCount(srcWidth),
                    rowBytes: srcRow)
                var dstBuf = vImage_Buffer(
                    data: dstRaw.baseAddress,
                    height: vImagePixelCount(newH),
                    width: vImagePixelCount(newW),
                    rowBytes: newW)
                vImageScale_Planar8(&srcBuf, &dstBuf, nil, vImage_Flags(kvImageHighQualityResampling))
            }
        }
        var canvas = [UInt8](repeating: 255, count: dstWidth * dstHeight)
        let ox = (dstWidth - newW) / 2
        let oy = (dstHeight - newH) / 2
        for y in 0..<newH {
            let dstY = oy + y
            if dstY < 0 || dstY >= dstHeight { continue }
            let srcOff = y * newW
            let dstOff = dstY * dstWidth + ox
            canvas.replaceSubrange(dstOff..<(dstOff + newW), with: scaled[srcOff..<(srcOff + newW)])
        }
        return canvas
    }

    /// Gray → two XTH bit planes, column-major, right-to-left, MSB-first (top = bit 7).
    static func packPlanes(gray: [UInt8], width: Int, height: Int) -> Data {
        let colBytes = (height + 7) / 8
        var p1 = [UInt8](repeating: 0, count: width * colBytes)
        var p2 = [UInt8](repeating: 0, count: width * colBytes)
        for y in 0..<height {
            for x in 0..<width {
                let g = gray[y * width + x]
                let pv: UInt8
                if g >= 192 { pv = 0 }
                else if g >= 128 { pv = 2 }
                else if g >= 64 { pv = 1 }
                else { pv = 3 }
                let col = width - 1 - x
                let byteIndex = col * colBytes + y / 8
                let bit = UInt8(7 - (y % 8))
                if (pv >> 1) & 1 != 0 { p1[byteIndex] |= 1 << bit }
                if pv & 1 != 0 { p2[byteIndex] |= 1 << bit }
            }
        }
        var out = Data(p1)
        out.append(contentsOf: p2)
        return out
    }

    static func unpackPlanes(_ pageBytes: Data) throws -> (gray: [UInt8], width: Int, height: Int) {
        if pageBytes.count < XtchFormat.xthPageHeaderSize {
            throw XtchError.message("truncated XTH page")
        }
        let magic = pageBytes.leUInt32(at: 0)
        if magic != XtchFormat.xthMagic { throw XtchError.message("invalid XTH page magic") }
        let width = Int(pageBytes.leUInt16(at: 4))
        let height = Int(pageBytes.leUInt16(at: 6))
        let compression = pageBytes.leUInt8(at: 9)
        let dataSize = Int(pageBytes.leUInt32(at: 10))
        var body = pageBytes.subdata(in: XtchFormat.xthPageHeaderSize..<(XtchFormat.xthPageHeaderSize + dataSize))
        if compression == 1 {
            guard let raw = RawDeflate.decompress(body) else {
                throw XtchError.message("failed to inflate XTH page")
            }
            body = raw
        } else if compression != 0 {
            throw XtchError.message("unsupported XTH compression \(compression)")
        }
        let colBytes = (height + 7) / 8
        let planeSize = width * colBytes
        if body.count < planeSize * 2 { throw XtchError.message("XTH page body shorter than plane data") }
        let p1 = [UInt8](body[0..<planeSize])
        let p2 = [UInt8](body[planeSize..<(planeSize * 2)])
        var gray = [UInt8](repeating: 0, count: width * height)
        for y in 0..<height {
            for x in 0..<width {
                let col = width - 1 - x
                let byteIndex = col * colBytes + y / 8
                let bit = UInt8(7 - (y % 8))
                let b1 = (p1[byteIndex] >> bit) & 1
                let b2 = (p2[byteIndex] >> bit) & 1
                let pv = (b1 << 1) | b2
                let g: UInt8
                switch pv {
                case 0: g = 255
                case 2: g = 170
                case 1: g = 85
                default: g = 0
                }
                gray[y * width + x] = g
            }
        }
        return (gray, width, height)
    }

    private static func chapters(from doc: PDFDocument, pageCount: Int) -> [XtchChapter] {
        var entries: [(String, Int)] = []
        func walk(_ node: PDFOutline) {
            if let dest = node.destination, let page = dest.page {
                let idx = doc.index(for: page) + 1
                if (1...pageCount).contains(idx) {
                    let name = AsciiText.fold(node.label ?? "")
                    if !name.isEmpty { entries.append((name, idx)) }
                }
            }
            for i in 0..<node.numberOfChildren {
                if let child = node.child(at: i) { walk(child) }
            }
        }
        if let root = doc.outlineRoot { walk(root) }
        entries.sort { $0.1 < $1.1 }
        var chapters: [XtchChapter] = []
        for i in 0..<entries.count {
            let (name, start) = entries[i]
            var end = i + 1 < entries.count ? entries[i + 1].1 - 1 : pageCount
            end = min(max(end, start), pageCount)
            chapters.append(XtchChapter(name: name, startPage: start, endPage: end))
        }
        return chapters
    }

    private static func writeContainer(destURL: URL, pageBodies: [Data], width: Int, height: Int,
                                       chapters: [XtchChapter], title: String, author: String) throws {
        let pageCount = pageBodies.count
        var chapterTable = Data()
        for ch in chapters {
            var name = Array(AsciiText.fold(ch.name).utf8.prefix(XtchFormat.chapterNameLen))
            if name.count < XtchFormat.chapterNameLen {
                name += [UInt8](repeating: 0, count: XtchFormat.chapterNameLen - name.count)
            }
            chapterTable.append(contentsOf: name)
            chapterTable.appendLE(UInt16(ch.startPage))
            chapterTable.appendLE(UInt16(ch.endPage))
            chapterTable.append(contentsOf: [UInt8](repeating: 0, count: 12))
        }
        let chapterOffset = chapters.isEmpty ? 0 : XtchFormat.chapterTableOff
        let pageTableOff = XtchFormat.chapterTableOff + chapterTable.count
        let dataOffset = pageTableOff + pageCount * XtchFormat.pageTableEntrySize

        var pageTable = Data()
        var offset = dataOffset
        for body in pageBodies {
            pageTable.appendLE(UInt64(offset))
            pageTable.appendLE(UInt32(body.count))
            pageTable.appendLE(UInt16(width))
            pageTable.appendLE(UInt16(height))
            offset += body.count
        }

        var header = Data()
        header.appendLE(XtchFormat.xtchMagic)
        header.appendLE(UInt8(1)) // versionMajor
        header.appendLE(UInt8(0)) // versionMinor
        header.appendLE(UInt16(pageCount))
        header.appendLE(UInt8(0)) // readDirection
        header.appendLE(UInt8(1)) // hasMetadata
        header.appendLE(UInt8(0)) // hasThumbnails
        header.appendLE(UInt8(chapters.isEmpty ? 0 : 1))
        header.appendLE(UInt32(1)) // currentPage
        header.appendLE(UInt64(XtchFormat.titleOffset))
        header.appendLE(UInt64(pageTableOff))
        header.appendLE(UInt64(dataOffset))
        header.appendLE(UInt64(0)) // thumbOffset
        header.appendLE(UInt32(chapterOffset))
        header.appendLE(UInt32(0)) // padding

        var metadata = Data()
        metadata.append(fixedUTF8(title, length: XtchFormat.titleLen))
        metadata.append(fixedUTF8(author, length: XtchFormat.authorLen))
        metadata.append(fixedUTF8("", length: 32)) // publisher
        metadata.append(fixedUTF8("", length: 16)) // language
        metadata.appendLE(UInt32(0)) // createTime
        metadata.appendLE(UInt16(0)) // coverPage
        metadata.appendLE(UInt16(chapters.count))
        metadata.append(contentsOf: [UInt8](repeating: 0, count: 8))

        var file = Data()
        file.append(header)
        file.append(metadata)
        file.append(chapterTable)
        file.append(pageTable)
        for body in pageBodies { file.append(body) }
        try file.write(to: destURL)
    }

    private static func fixedUTF8(_ text: String, length: Int) -> Data {
        var bytes = Array(text.utf8.prefix(length - 1))
        bytes.append(0)
        if bytes.count < length {
            bytes += [UInt8](repeating: 0, count: length - bytes.count)
        }
        return Data(bytes)
    }
}
