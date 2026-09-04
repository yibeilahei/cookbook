import Foundation

/// Owns the Python backend child process and speaks its JSON-lines protocol
/// (see backend/server.py). Lifecycle is tied to the app's: started at launch,
/// shut down on quit.
final class BackendClient {
    enum ClientError: LocalizedError {
        case notStarted
        case exited
        case backend(String)
        case unexpectedResponse

        var errorDescription: String? {
            switch self {
            case .notStarted: return "Backend is not running."
            case .exited: return "Backend process exited before responding."
            case .backend(let message): return message
            case .unexpectedResponse: return "Backend returned an unexpected response."
            }
        }
    }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdoutPipe = Pipe()
    private let stderrPipe = Pipe()
    private var stdoutBuffer = Data()
    private var nextId = 1
    private var pending: [Int: CheckedContinuation<Any, Error>] = [:]
    private let lock = NSLock()
    private var started = false

    /// Called on a background queue for `progress` / `batch` messages.
    var onEvent: (([String: Any]) -> Void)?

    func start(command: URL, arguments: [String], cwd: URL?) throws {
        process.executableURL = command
        process.arguments = arguments
        process.currentDirectoryURL = cwd
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        process.terminationHandler = { [weak self] _ in
            self?.failAll(ClientError.exited)
        }
        stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            self?.consumeStdout(handle.availableData)
        }
        stderrPipe.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            fputs("[backend] \(text)", stderr)
        }
        try process.run()
        started = true
    }

    func call(_ cmd: String, _ params: [String: Any] = [:]) async throws -> Any {
        guard started else { throw ClientError.notStarted }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            let id = nextId
            nextId += 1
            pending[id] = continuation
            lock.unlock()

            var body = params
            body["id"] = id
            body["cmd"] = cmd
            do {
                var data = try JSONSerialization.data(withJSONObject: body)
                data.append(0x0A)
                stdinPipe.fileHandleForWriting.write(data)
            } catch {
                lock.lock()
                pending.removeValue(forKey: id)
                lock.unlock()
                continuation.resume(throwing: error)
            }
        }
    }

    func callDict(_ cmd: String, _ params: [String: Any] = [:]) async throws -> [String: Any] {
        let result = try await call(cmd, params)
        guard let dict = asStringDict(result) else { throw ClientError.unexpectedResponse }
        return dict
    }

    func stop() {
        guard started else { return }
        started = false
        stdoutPipe.fileHandleForReading.readabilityHandler = nil
        stderrPipe.fileHandleForReading.readabilityHandler = nil
        if process.isRunning {
            try? callFireAndForget("shutdown")
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [process] in
                if process.isRunning { process.terminate() }
            }
        }
    }

    private func callFireAndForget(_ cmd: String) throws {
        lock.lock()
        let id = nextId
        nextId += 1
        lock.unlock()
        let body: [String: Any] = ["id": id, "cmd": cmd]
        var data = try JSONSerialization.data(withJSONObject: body)
        data.append(0x0A)
        try stdinPipe.fileHandleForWriting.write(contentsOf: data)
    }

    private func consumeStdout(_ chunk: Data) {
        if chunk.isEmpty {
            // EOF
            return
        }
        stdoutBuffer.append(chunk)
        while let range = stdoutBuffer.firstRange(of: Data([0x0A])) {
            let line = stdoutBuffer.subdata(in: stdoutBuffer.startIndex..<range.lowerBound)
            stdoutBuffer.removeSubrange(stdoutBuffer.startIndex...range.lowerBound)
            handleLine(line)
        }
    }

    private func handleLine(_ lineData: Data) {
        let trimmed = lineData.drop(while: { $0 == 0x20 || $0 == 0x0D }).filter { $0 != 0x0D }
        guard !trimmed.isEmpty else { return }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(trimmed)),
              let msg = asStringDict(obj) else {
            if let text = String(data: Data(trimmed), encoding: .utf8) {
                fputs("Backend sent a non-JSON line on stdout: \(text)\n", stderr)
            }
            return
        }
        if let type = msg["type"] as? String, type == "progress" || type == "batch" {
            onEvent?(msg)
            return
        }
        let id = jsonInt(msg["id"])
        lock.lock()
        let continuation = id.flatMap { pending.removeValue(forKey: $0) }
        lock.unlock()
        guard let continuation else { return }
        let ok = jsonBool(msg["ok"]) ?? false
        if ok {
            continuation.resume(returning: msg["result"] ?? NSNull())
        } else {
            let message = msg["error"] as? String ?? "Unknown backend error"
            continuation.resume(throwing: ClientError.backend(message))
        }
    }

    private func failAll(_ error: Error) {
        lock.lock()
        let waiting = pending
        pending.removeAll()
        lock.unlock()
        for (_, continuation) in waiting {
            continuation.resume(throwing: error)
        }
    }
}

func asStringDict(_ value: Any) -> [String: Any]? {
    if let dict = value as? [String: Any] { return dict }
    if let dict = value as? NSDictionary {
        var out: [String: Any] = [:]
        for (key, val) in dict {
            if let key = key as? String { out[key] = val }
        }
        return out
    }
    return nil
}

func jsonInt(_ value: Any?) -> Int? {
    if let i = value as? Int { return i }
    if let n = value as? NSNumber { return n.intValue }
    if let d = value as? Double { return Int(d) }
    return nil
}

func jsonBool(_ value: Any?) -> Bool? {
    if let b = value as? Bool { return b }
    if let n = value as? NSNumber { return n.boolValue }
    return nil
}

func jsonDouble(_ value: Any?) -> Double? {
    if let d = value as? Double { return d }
    if let n = value as? NSNumber { return n.doubleValue }
    if let i = value as? Int { return Double(i) }
    return nil
}
