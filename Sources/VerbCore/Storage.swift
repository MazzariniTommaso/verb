import Foundation
import CSQLite

public struct DataPaths: Sendable {
    public let root: URL
    public var audio: URL { root.appendingPathComponent("Audio", isDirectory: true) }
    public var models: URL { root.appendingPathComponent("Models", isDirectory: true) }
    public var settings: URL { root.appendingPathComponent("settings.json") }
    public var library: URL { root.appendingPathComponent("library.json") }
    public var stats: URL { root.appendingPathComponent("stats.json") }
    public init(root: URL? = nil) throws {
        self.root = root ?? DataPaths.defaultRoot()
        for dir in [self.root, audio, models] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        }
        // Recordings, notes and meetings are readable by you only, like the rest of the folder.
        let manager = FileManager.default
        for dir in ["Audio", "Notes", "Meetings"].map({ self.root.appendingPathComponent($0, isDirectory: true) }) where manager.fileExists(atPath: dir.path) {
            try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
            for item in manager.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey])?.compactMap({ $0 as? URL }) ?? [] {
                let folder = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                try? manager.setAttributes([.posixPermissions: folder ? 0o700 : 0o600], ofItemAtPath: item.path)
            }
        }
    }
    /// Verb keeps its data in Application Support/Verb.
    public static func defaultRoot(in support: URL = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]) -> URL {
        support.appendingPathComponent("Verb", isDirectory: true)
    }
    public func audioURL(_ name: String) -> URL? {
        guard name == (name as NSString).lastPathComponent, !name.contains("..") else { return nil }
        return audio.appendingPathComponent(name)
    }
}
public enum JSONStore {
    public static func load<T: Codable>(_ type: T.Type, from url: URL, fallback: @autoclosure () -> T) throws -> T {
        guard FileManager.default.fileExists(atPath: url.path) else { return fallback() }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw VerbError("Could not read \(url.lastPathComponent). The original file has been preserved: \(error.localizedDescription)") }
        do { return try JSONDecoder().decode(type, from: data) }
        catch {
            // A value this build doesn't know, or one missing, gives way to its default and the rest
            // is kept; the file as it was stays beside it.
            if let salvaged = salvage(type, from: data, defaults: fallback()) {
                try? data.write(to: url.appendingPathExtension("unreadable"), options: .atomic)
                return salvaged
            }
            throw VerbError("Could not read \(url.lastPathComponent). The original file has been preserved: \(error.localizedDescription)")
        }
    }
    /// The file's values over the defaults, with each one that can't be decoded replaced by its
    /// default or, where there is none, left out.
    static func salvage<T: Codable>(_ type: T.Type, from data: Data, defaults: T) -> T? {
        guard let file = try? JSONSerialization.jsonObject(with: data), let base = (try? JSONEncoder().encode(defaults)).flatMap({ try? JSONSerialization.jsonObject(with: $0) }) else { return nil }
        var object = merged(base, file)
        for _ in 0..<64 {
            guard let json = try? JSONSerialization.data(withJSONObject: object) else { return nil }
            do { return try JSONDecoder().decode(type, from: json) }
            catch let error as DecodingError {
                let path: [CodingKey]
                switch error {
                case .keyNotFound(let key, let context): path = context.codingPath + [key]
                case .typeMismatch(_, let context), .valueNotFound(_, let context), .dataCorrupted(let context): path = context.codingPath
                @unknown default: return nil
                }
                guard !path.isEmpty, let repaired = replacing(object, at: path[...], from: base) else { return nil }
                object = repaired
            } catch { return nil }
        }
        return nil
    }
    private static func merged(_ base: Any, _ file: Any) -> Any {
        guard let base = base as? [String: Any], let file = file as? [String: Any] else { return file }
        return base.merging(file) { old, new in merged(old, new) }
    }
    /// The object with the value at the path set to its default, or removed when there is none;
    /// nil when nothing could change.
    private static func replacing(_ object: Any, at path: ArraySlice<CodingKey>, from base: Any?) -> Any? {
        guard let key = path.first else { return nil }
        let rest = path.dropFirst()
        if var dictionary = object as? [String: Any] {
            let name = key.stringValue, fallback = (base as? [String: Any])?[name]
            if !rest.isEmpty, let inner = dictionary[name], let repaired = replacing(inner, at: rest, from: fallback) { dictionary[name] = repaired; return dictionary }
            // The value itself, or one that can't be repaired inside: its default, or nothing.
            if let fallback, !(dictionary[name].map { ($0 as AnyObject).isEqual(fallback) } ?? false) { dictionary[name] = fallback; return dictionary }
            if dictionary[name] != nil { dictionary.removeValue(forKey: name); return dictionary }
            return nil
        }
        if var array = object as? [Any], let index = key.intValue, array.indices.contains(index) {
            // An element of a list that can't be repaired is left out.
            if !rest.isEmpty, let repaired = replacing(array[index], at: rest, from: nil) { array[index] = repaired } else { array.remove(at: index) }
            return array
        }
        return nil
    }
    public static func save<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(value).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
public final class HistoryStore {
    private var db: OpaquePointer?
    private let paths: DataPaths
    public init(paths: DataPaths) throws {
        self.paths = paths
        guard sqlite3_open_v2(paths.root.appendingPathComponent("history.sqlite").path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else { throw VerbError("Could not open local history.") }
        // The database and its journal hold what you said: readable by you only.
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.root.appendingPathComponent("history.sqlite" + suffix).path) }
        sqlite3_busy_timeout(db, 5000)
        try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL; CREATE TABLE IF NOT EXISTS records (id TEXT PRIMARY KEY, created REAL NOT NULL, payload BLOB NOT NULL); PRAGMA user_version=1;")
    }
    deinit { sqlite3_close(db) }
    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else { throw VerbError("Local history could not be saved: \(String(cString: sqlite3_errmsg(db)))") }
    }
    public func save(_ record: DictationRecord) throws {
        let data = try JSONEncoder().encode(record)
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO records(id,created,payload) VALUES(?,?,?)", -1, &statement, nil) == SQLITE_OK else { throw VerbError("Could not prepare a history update.") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, record.id.uuidString, -1, transient)
        sqlite3_bind_double(statement, 2, record.createdAt.timeIntervalSince1970)
        _ = data.withUnsafeBytes { sqlite3_bind_blob(statement, 3, $0.baseAddress, Int32(data.count), transient) }
        guard sqlite3_step(statement) == SQLITE_DONE else { throw VerbError("History write failed. Check available disk space.") }
    }
    public func all() throws -> [DictationRecord] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "SELECT payload FROM records ORDER BY created DESC", -1, &statement, nil) == SQLITE_OK else { throw VerbError("Could not read history.") }
        defer { sqlite3_finalize(statement) }
        var records: [DictationRecord] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { break }
            guard result == SQLITE_ROW else { throw VerbError("History is unreadable. Your database has been preserved.") }
            // An entry Verb can't read is left in the database and skipped, so the rest still opens.
            guard let blob = sqlite3_column_blob(statement, 0), let record = try? JSONDecoder().decode(DictationRecord.self, from: Data(bytes: blob, count: Int(sqlite3_column_bytes(statement, 0)))) else { continue }
            records.append(record)
        }
        return records
    }
    public func delete(_ record: DictationRecord) throws {
        // UUID is generated/decoded as a UUID, never free-form SQL input.
        try exec("DELETE FROM records WHERE id='\(record.id.uuidString)'")
        if let name = record.audioName, let url = paths.audioURL(name), FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
    }
    public func prune(retention: Retention, keepAudio: Bool, now: Date = Date()) throws {
        for var record in try all() {
            if retention == .none || (retention.rawValue > 0 && now.timeIntervalSince(record.createdAt) > Double(retention.rawValue) * 86400) { try delete(record); continue }
            // A dictation that failed or was cancelled keeps its recording for Retry until it expires.
            let retryable = record.status == .failed || record.status == .cancelled
            if let name = record.audioName, (!keepAudio && !retryable) || now.timeIntervalSince(record.createdAt) > 14 * 86400, let url = paths.audioURL(name) {
                if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
                record.audioName = nil; try save(record)
            }
        }
    }
    public func recoverInterrupted() throws {
        for var record in try all() where record.status == .processing || record.status == .recorded {
            // A recording cut short never had its sizes written: put them right, so it plays and retries.
            if let name = record.audioName, let url = paths.audioURL(name) { WAVRepair.repair(url) }
            record.status = .failed; record.error = "Processing was interrupted. Retry the saved audio."; try save(record)
        }
    }
    public func removeOrphanedAudio() throws {
        let referenced = Set(try all().compactMap(\.audioName))
        for url in try FileManager.default.contentsOfDirectory(at: paths.audio, includingPropertiesForKeys: nil) {
            guard UUID(uuidString: url.deletingPathExtension().lastPathComponent) != nil, !referenced.contains(url.lastPathComponent) else { continue }
            try FileManager.default.removeItem(at: url)
        }
    }
}

/// A dictation's WAV file whose sizes were never written because Verb stopped mid-recording:
/// they are set from the file's length, so every second recorded can be played and retried.
public enum WAVRepair {
    public static func repair(_ url: URL) {
        guard let handle = try? FileHandle(forUpdating: url) else { return }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 4096), header.count >= 44,
              header.prefix(4) == Data("RIFF".utf8), header.subdata(in: 8..<12) == Data("WAVE".utf8),
              let length = try? handle.seekToEnd(), length > 44, length < UInt64(UInt32.max) else { return }
        func number(at offset: Int) -> UInt32 { header.subdata(in: offset..<offset + 4).withUnsafeBytes { UInt32(littleEndian: $0.loadUnaligned(as: UInt32.self)) } }
        func write(_ value: UInt32, at offset: Int) throws {
            try handle.seek(toOffset: UInt64(offset))
            var little = value.littleEndian
            try handle.write(contentsOf: Data(bytes: &little, count: 4))
        }
        var offset = 12
        while offset + 8 <= header.count {
            let size = number(at: offset + 4)
            if header.subdata(in: offset..<offset + 4) == Data("data".utf8) {
                let actual = UInt32(length) - UInt32(offset) - 8
                if size != actual { try? write(actual, at: offset + 4); try? write(UInt32(length) - 8, at: 4) }
                return
            }
            offset += 8 + Int(size) + Int(size % 2)
        }
    }
}
