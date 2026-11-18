import Foundation

/// Append-only, local event storage. It stores observations, never camera frames or input content.
public final class JSONLEventStore {
    public let directoryURL: URL

    private let lock = NSLock()
    private let encoder: JSONEncoder
    private let calendar: Calendar

    public init(directoryURL: URL, calendar: Calendar = .current) throws {
        self.directoryURL = directoryURL
        self.calendar = calendar

        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601

        try FileManager.default.createDirectory(
            at: directoryURL,
            withIntermediateDirectories: true
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directoryURL.path
        )
    }

    public func append(_ record: ObservationRecord) throws {
        try appendEncodable(record, prefix: "observations", date: record.timestamp)
    }

    public func append(_ feedback: PredictionFeedback) throws {
        try appendEncodable(feedback, prefix: "feedback", date: feedback.timestamp)
    }

    public func append(_ feedback: IdleEpisodeFeedback) throws {
        try appendEncodable(feedback, prefix: "episode-feedback", date: feedback.timestamp)
    }

    public func loadObservationRecords() throws -> [ObservationRecord] {
        try loadAll(prefix: "observations", as: ObservationRecord.self)
            .sorted { $0.timestamp < $1.timestamp }
    }

    public func loadFeedback() throws -> [PredictionFeedback] {
        try loadAll(prefix: "feedback", as: PredictionFeedback.self)
            .sorted { $0.timestamp < $1.timestamp }
    }

    public func loadEpisodeFeedback() throws -> [IdleEpisodeFeedback] {
        try loadAll(prefix: "episode-feedback", as: IdleEpisodeFeedback.self)
            .sorted { $0.timestamp < $1.timestamp }
    }

    public func purgeFiles(olderThanDays days: Int, now: Date = Date()) throws {
        lock.lock()
        defer { lock.unlock() }

        guard let cutoff = calendar.date(byAdding: .day, value: -days, to: now) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )

        for url in urls where isOwnedJSONL(url) {
            let values = try url.resourceValues(forKeys: [.contentModificationDateKey])
            if let modified = values.contentModificationDate, modified < cutoff {
                try FileManager.default.removeItem(at: url)
            }
        }
    }

    public func deleteAll() throws {
        lock.lock()
        defer { lock.unlock() }

        let urls = try FileManager.default.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in urls where isOwnedJSONL(url) || url.lastPathComponent == "learning-summary.md" {
            try FileManager.default.removeItem(at: url)
        }
    }

    private func appendEncodable<T: Encodable>(_ value: T, prefix: String, date: Date) throws {
        lock.lock()
        defer { lock.unlock() }

        var data = try encoder.encode(value)
        data.append(0x0A)
        let url = fileURL(prefix: prefix, date: date)

        if !FileManager.default.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600],
                ofItemAtPath: url.path
            )
            return
        }

        let handle = try FileHandle(forUpdating: url)
        defer { try? handle.close() }
        try prepareForAppend(handle)
        try handle.write(contentsOf: data)
    }

    private func prepareForAppend(_ handle: FileHandle) throws {
        let end = try handle.seekToEnd()
        guard end > 0 else { return }
        try handle.seek(toOffset: end - 1)
        if try handle.read(upToCount: 1)?.last == 0x0A { return }

        // Only an interrupted final write needs a backward scan. Leave every
        // earlier byte intact, even when the last record spans several chunks.
        var start = end
        while start > 0 {
            let length = min(start, 4096)
            start -= length
            try handle.seek(toOffset: start)
            let chunk = try handle.read(upToCount: Int(length)) ?? Data()
            if let newline = chunk.lastIndex(of: 0x0A) {
                start += UInt64(newline + 1)
                break
            }
        }
        try handle.seek(toOffset: start)
        let tail = try handle.readToEnd() ?? Data()
        if Self.isCompleteJSON(tail) {
            // The full value reached disk before the terminating newline.
            try handle.write(contentsOf: Data([0x0A]))
        } else {
            try handle.truncate(atOffset: start)
            try handle.seek(toOffset: start)
        }
    }

    private static func isCompleteJSON(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed)) != nil
    }

    private func loadAll<T: Decodable>(prefix: String, as type: T.Type) throws -> [T] {
        let urls = try lock.withLock {
            try FileManager.default.contentsOfDirectory(
                at: directoryURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
            .filter { $0.lastPathComponent.hasPrefix(prefix + "-") && $0.pathExtension == "jsonl" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var values: [T] = []
        for url in urls {
            // Snapshot one day at a time. Decoding can take much longer than the
            // read and should never hold up the next monitoring tick's append.
            let snapshot: Data? = try lock.withLock {
                do { return try Data(contentsOf: url) }
                catch CocoaError.fileReadNoSuchFile { return nil } // purged since enumeration
            }
            guard let data = snapshot else { continue }
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: false)
            for (index, line) in lines.enumerated() where !line.isEmpty {
                do {
                    values.append(try decoder.decode(T.self, from: Data(line)))
                } catch {
                    // An unterminated JSON prefix can be discarded on the next append.
                    // A complete value with an unexpected schema is a real decoding error.
                    if index == lines.count - 1 && !Self.isCompleteJSON(Data(line)) { continue }
                    throw error
                }
            }
        }
        return values
    }

    private func fileURL(prefix: String, date: Date) -> URL {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        let name = String(format: "%@-%04d-%02d-%02d.jsonl", prefix, year, month, day)
        return directoryURL.appendingPathComponent(name)
    }

    private func isOwnedJSONL(_ url: URL) -> Bool {
        guard url.pathExtension == "jsonl" else { return false }
        let name = url.lastPathComponent
        return name.hasPrefix("observations-")
            || name.hasPrefix("feedback-")
            || name.hasPrefix("episode-feedback-")
    }
}
