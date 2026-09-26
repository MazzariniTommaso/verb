import Foundation
import Darwin
import VerbCore

// One bounded child per operation. No shell interpolation and no transcript in argv.
final class CLIProcess: @unchecked Sendable {
    enum Framing { case lines, contentLength }
    private let process = Process()
    private let output = Pipe(), errors = Pipe()
    private let input: InputWriter
    private var buffer = Data(), stderr = Data(), totalBytes = 0
    private let deadline: Date
    private let framing: Framing
    private let lifecycle = NSLock()
    private var stopped = false
    var exitCode: Int32 { process.terminationStatus }
    var errorText: String { String(decoding: stderr.suffix(2000), as: UTF8.self) }
    /// A child that exits without reading its input would otherwise take Verb down with SIGPIPE.
    /// Ignored, the write fails instead. Process starts each child with default signal handling.
    private static let brokenPipesFail: Void = { _ = signal(SIGPIPE, SIG_IGN) }()
    init(executable: String, arguments: [String], directory: URL, environment: [String: String], timeout: TimeInterval = 60, framing: Framing = .lines) throws {
        let deadline = Date().addingTimeInterval(timeout), pipe = Pipe()
        self.framing = framing; self.deadline = deadline; input = InputWriter(pipe.fileHandleForWriting, until: deadline)
        process.executableURL = URL(fileURLWithPath: executable); process.arguments = arguments
        process.currentDirectoryURL = directory; process.environment = environment
        process.standardInput = pipe; process.standardOutput = output; process.standardError = errors
        _ = Self.brokenPipesFail
        try process.run()
        for fd in [output.fileHandleForReading.fileDescriptor, errors.fileHandleForReading.fileDescriptor] { _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK) }
    }
    deinit { stop() }
    func stop() {
        lifecycle.lock(); defer { lifecycle.unlock() }
        guard !stopped else { return }; stopped = true
        input.cancel()
        let child = process, leader = process.processIdentifier
        guard leader > 0 else { return }
        // Collected before any signal, while the parent links that lead to them still hold. Once
        // the child is reaped its PID is free for someone else, so only its group is left to reach.
        let tree = ProcessTree(leader: leader, alive: child.isRunning)
        if child.isRunning { child.terminate() }
        tree.send(SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.6) {
            let survivors = tree.refreshed(leaderAlive: child.isRunning)
            if child.isRunning { kill(leader, SIGKILL) }
            survivors.send(SIGKILL)
        }
    }
    func send(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object)
        var message = framing == .contentLength ? Data("Content-Length: \(data.count)\r\n\r\n".utf8) : Data()
        message.append(data); if framing == .lines { message.append(10) }
        input.write(message)
    }
    func sendText(_ text: String) { input.write(Data(text.utf8), thenClose: true) }
    private func drain(_ handle: FileHandle) -> Data {
        var result = Data(), bytes = [UInt8](repeating: 0, count: 16384)
        // Bound each drain so cancellation and the other pipe keep making progress.
        for _ in 0..<8 {
            let count = Darwin.read(handle.fileDescriptor, &bytes, bytes.count)
            if count <= 0 { break }; result.append(contentsOf: bytes.prefix(count))
        }
        return result
    }
    private func pump() throws {
        try Task.checkCancellation()
        guard Date() < deadline else { stop(); throw VerbError("The CLI took too long. The original transcript is safe. Check its login or usage limit and retry.") }
        let data = drain(output.fileHandleForReading); buffer.append(data); totalBytes += data.count
        let diagnostics = drain(errors.fileHandleForReading); stderr.append(diagnostics)
        if stderr.count > 16000 { stderr = Data(stderr.suffix(16000)) }
        guard totalBytes <= 4_000_000 else { stop(); throw VerbError("The CLI returned too much output. Your original transcript is safe.") }
    }
    private func frame() throws -> Data? {
        if framing == .lines {
            guard let end = buffer.firstIndex(of: 10) else { return nil }
            let value = buffer.prefix(upTo: end); buffer.removeSubrange(...end); return Data(value)
        }
        guard let header = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let fields = String(decoding: buffer.prefix(upTo: header.lowerBound), as: UTF8.self).components(separatedBy: "\r\n")
        guard let line = fields.first(where: { $0.lowercased().hasPrefix("content-length:") }), let length = Int(line.dropFirst(15).trimmingCharacters(in: .whitespaces)), (0...4_000_000).contains(length) else { throw VerbError("Invalid CLI protocol header.") }
        let start = header.upperBound
        guard buffer.count - start >= length else { return nil }
        let value = buffer.subdata(in: start..<(start + length)); buffer.removeSubrange(0..<(start + length)); return value
    }
    func next() async throws -> [String: Any] {
        while true {
            try pump()
            while let data = try frame() {
                if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
            }
            if !process.isRunning {
                // Read any final bytes written immediately before termination.
                try pump()
                if let data = try frame(), let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] { return object }
                throw VerbError("The CLI closed before completing its response. Check that it is current and signed in. " + errorText)
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }
    func collect() async throws -> String {
        while true {
            try pump()
            if !process.isRunning { try pump(); break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        guard process.terminationStatus == 0 else { throw VerbError("The CLI failed (\(process.terminationStatus)). Check its login, model access and usage limits. " + errorText) }
        // A child that exited without reading the whole request answered something else.
        let settle = Date().addingTimeInterval(0.5)
        while input.busy, Date() < settle { try await Task.sleep(nanoseconds: 20_000_000) }
        guard input.delivered else { throw VerbError("The CLI closed before completing its response. Check that it is current and signed in. " + errorText) }
        return String(decoding: buffer, as: UTF8.self)
    }
    func request(_ method: String, _ params: [String: Any], id: Int) async throws -> [String: Any] {
        try send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        while true {
            let event = try await next()
            if event["id"] as? Int == id, event["method"] == nil {
                if let error = event["error"] as? [String: Any] { throw VerbError("CLI: " + (error["message"] as? String ?? "Request failed")) }
                return event["result"] as? [String: Any] ?? [:]
            }
            try denyRequest(event)
        }
    }
    func denyRequest(_ event: [String: Any]) throws {
        guard let id = event["id"], let method = event["method"] as? String else { return }
        if method == "session/request_permission" { try send(["jsonrpc": "2.0", "id": id, "result": ["outcome": ["outcome": "cancelled"]]]) }
        else if method.contains("permission") { try send(["jsonrpc": "2.0", "id": id, "result": ["kind": "denied-interactively-by-user"]]) }
        else { try send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Verb only processes text; tools and interactive requests are unavailable."]]) }
    }
}

/// Writes the child's stdin on a serial queue of its own, in order, so a child that reads slowly
/// or not at all can't hold up the deadline or the output pump. Only this queue touches the
/// descriptor, and a write gives up at the deadline or on cancel, so none outlives the operation.
private final class InputWriter: @unchecked Sendable {
    private let handle: FileHandle
    private let deadline: Date
    private let queue = DispatchQueue(label: "app.verb.cli-input")
    private let state = NSLock()
    private var cancelled = false, pending = 0, failed = false
    private var open = true // Read and written on the queue only.
    init(_ handle: FileHandle, until deadline: Date) {
        self.handle = handle; self.deadline = deadline
        _ = fcntl(handle.fileDescriptor, F_SETFL, fcntl(handle.fileDescriptor, F_GETFL) | O_NONBLOCK)
    }
    var busy: Bool { state.lock(); defer { state.unlock() }; return pending > 0 }
    /// Everything queued so far reached the pipe.
    var delivered: Bool { state.lock(); defer { state.unlock() }; return pending == 0 && !failed }
    func write(_ data: Data, thenClose close: Bool = false) {
        state.lock(); pending += 1; state.unlock()
        queue.async { [self] in
            let written = data.isEmpty || deliver(data)
            if !written || close { finish() }
            state.lock(); pending -= 1; failed = failed || !written; state.unlock()
        }
    }
    func cancel() { state.lock(); cancelled = true; state.unlock(); queue.async { [self] in finish() } }
    private var isCancelled: Bool { state.lock(); defer { state.unlock() }; return cancelled }
    private func deliver(_ data: Data) -> Bool {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> Bool in
            var offset = 0
            while offset < bytes.count {
                guard open, Date() < deadline, !isCancelled else { return false }
                let count = Darwin.write(handle.fileDescriptor, bytes.baseAddress! + offset, bytes.count - offset)
                if count > 0 { offset += count; continue }
                // A full pipe waits for the child to read. Anything else, such as EPIPE once the child
                // exited, ends the request, and the reader reports the CLI's own error.
                guard count < 0, errno == EAGAIN || errno == EINTR else { return false }
                var ready = pollfd(fd: handle.fileDescriptor, events: Int16(POLLOUT), revents: 0)
                _ = poll(&ready, 1, 100)
            }
            return true
        }
    }
    private func finish() { guard open else { return }; open = false; try? handle.close() }
}

/// Everything the child started, so stopping it stops them too and a launcher's worker never
/// outlives a cancel or a timeout. Each process is kept with its start time: a PID that started
/// later belongs to someone else by the time a signal is sent.
private struct ProcessTree: Sendable {
    struct Member: Hashable, Sendable { let pid: pid_t; let started: UInt64 }
    let leader: pid_t
    var members: [Member]
    init(leader: pid_t, alive: Bool) { self.leader = leader; members = alive ? Self.descendants(of: [leader]) : [] }
    /// The same tree with whatever its survivors started since.
    func refreshed(leaderAlive: Bool) -> ProcessTree {
        var tree = self, known = Set(members)
        let roots = (leaderAlive ? [leader] : []) + members.filter { Self.started($0.pid) == $0.started }.map(\.pid)
        for member in Self.descendants(of: roots) where known.insert(member).inserted { tree.members.append(member) }
        return tree
    }
    func send(_ signal: Int32) {
        // Process starts the child as the leader of its own group; the group also reaches
        // workers whose parent already exited.
        if leader != getpgrp() { killpg(leader, signal) }
        for member in members where Self.started(member.pid) == member.started { kill(member.pid, signal) }
    }
    private static func started(_ pid: pid_t) -> UInt64? {
        var info = proc_bsdinfo(); let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return info.pbi_start_tvsec * 1_000_000 + info.pbi_start_tvusec
    }
    private static func descendants(of roots: [pid_t]) -> [Member] {
        var found: [Member] = [], pending = roots, seen = Set(roots)
        while let parent = pending.popLast(), found.count < 1000 {
            var children = [pid_t](repeating: 0, count: Int(max(proc_listchildpids(parent, nil, 0), 0)) + 16)
            let count = Int(proc_listchildpids(parent, &children, Int32(children.count * MemoryLayout<pid_t>.size)))
            for pid in children.prefix(max(count, 0)) where pid > 0 && seen.insert(pid).inserted {
                guard let started = started(pid) else { continue }
                found.append(Member(pid: pid, started: started)); pending.append(pid)
            }
        }
        return found
    }
}
