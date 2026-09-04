import Foundation
import zlib

enum RawDeflate {
    /// Raw-DEFLATE (no zlib wrapper; wbits = -15).
    static func compress(_ input: Data) -> Data? {
        if input.isEmpty { return Data() }
        var stream = z_stream()
        let status = deflateInit2_(
            &stream, Z_BEST_COMPRESSION, Z_DEFLATED, -15, 8, Z_DEFAULT_STRATEGY,
            ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { return nil }
        defer { deflateEnd(&stream) }

        var output = Data()
        let chunk = 64 * 1024
        var inOffset = 0
        input.withUnsafeBytes { inRaw in
            guard let inBase = inRaw.bindMemory(to: UInt8.self).baseAddress else { return }
            while inOffset < input.count {
                let inN = min(chunk, input.count - inOffset)
                var outBuf = [UInt8](repeating: 0, count: chunk)
                let flush = (inOffset + inN >= input.count) ? Z_FINISH : Z_NO_FLUSH
                let code: Int32 = outBuf.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_in = UnsafeMutablePointer(mutating: inBase.advanced(by: inOffset))
                    stream.avail_in = uInt(inN)
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(outPtr.count)
                    return deflate(&stream, flush)
                }
                let produced = chunk - Int(stream.avail_out)
                if produced > 0 { output.append(contentsOf: outBuf.prefix(produced)) }
                inOffset += inN - Int(stream.avail_in)
                if code == Z_STREAM_END { break }
                if code != Z_OK { output = Data(); break }
            }
        }
        return output
    }

    static func decompress(_ input: Data) -> Data? {
        if input.isEmpty { return Data() }
        var stream = z_stream()
        let status = inflateInit2_(
            &stream, -15, ZLIB_VERSION, Int32(MemoryLayout<z_stream>.size)
        )
        guard status == Z_OK else { return nil }
        defer { inflateEnd(&stream) }

        var output = Data()
        let chunk = 64 * 1024
        var inOffset = 0
        input.withUnsafeBytes { inRaw in
            guard let inBase = inRaw.bindMemory(to: UInt8.self).baseAddress else { return }
            while inOffset < input.count {
                let inN = min(chunk, input.count - inOffset)
                var outBuf = [UInt8](repeating: 0, count: chunk)
                let code: Int32 = outBuf.withUnsafeMutableBufferPointer { outPtr in
                    stream.next_in = UnsafeMutablePointer(mutating: inBase.advanced(by: inOffset))
                    stream.avail_in = uInt(inN)
                    stream.next_out = outPtr.baseAddress
                    stream.avail_out = uInt(outPtr.count)
                    return inflate(&stream, Z_NO_FLUSH)
                }
                let produced = chunk - Int(stream.avail_out)
                if produced > 0 { output.append(contentsOf: outBuf.prefix(produced)) }
                inOffset += inN - Int(stream.avail_in)
                if code == Z_STREAM_END { break }
                if code != Z_OK && code != Z_BUF_ERROR { output = Data(); break }
            }
        }
        return output
    }
}
