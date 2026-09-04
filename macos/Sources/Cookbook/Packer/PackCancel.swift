import Foundation

/// Shared cancel flag for Calibre and the in-process .xtch packer.
final class PackCancel: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func reset() { lock.lock(); flag = false; lock.unlock() }
    func cancel() { lock.lock(); flag = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
