import Foundation

struct DiagnosticEvent: Codable {
    let timestamp: Date
    let level: String
    let event: String
    let operation: String?
    let fields: [String: String]
}
/// Only allowlisted technical fields reach disk. No raw errors, server names or subscription URLs.
final class DiagnosticLog {
    static let shared = DiagnosticLog()
    static let retention: TimeInterval = 24 * 60 * 60
    static let maximumBytes = 20 * 1024 * 1024
    private let queue = DispatchQueue(label: "happ-monitor.diagnostics", qos: .utility)
    let directory: URL
    private let clock: () -> Date
    private var lastCleanup = Date.distantPast
    private var failure: String?
    private let allowed: Set<String> = ["version", "os", "status", "stage", "duration_ms", "latency_ms", "healthy", "verified", "error_code", "attempt", "candidate_count", "sample", "manual", "paused", "automatic", "permission", "reason", "language", "http_status", "endpoint", "candidate_id"]
    init(directory: URL? = nil, clock: @escaping () -> Date = Date.init) {
        self.directory = directory ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Happ Monitor", isDirectory: true)
        self.clock = clock
    }
    func record(_ event: String, level: String = "info", operation: String? = nil, fields: [String: String] = [:]) {
        let time = clock()
        let safe = fields.filter { allowed.contains($0.key) }.mapValues { String($0.prefix(160)) }
        let entry = DiagnosticEvent(timestamp: time, level: level, event: event, operation: operation, fields: safe)
        queue.async { self.append(entry) }
    }
    private func encoder() -> JSONEncoder { let e = JSONEncoder(); e.dateEncodingStrategy = .iso8601; e.outputFormatting = [.sortedKeys]; return e }
    private func decoder() -> JSONDecoder { let d = JSONDecoder(); d.dateDecodingStrategy = .iso8601; return d }
    private func files() -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.lastPathComponent.hasPrefix("events-") && $0.pathExtension == "jsonl" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
    private func entries(_ url: URL) -> [DiagnosticEvent] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return data.split(separator: 10).compactMap { try? decoder().decode(DiagnosticEvent.self, from: Data($0)) }
    }
    private func prepare() throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
    }
    private func cleanup(now: Date, force: Bool = false) throws {
        guard force || now.timeIntervalSince(lastCleanup) >= 60 else { return }
        try prepare()
        for file in files() {
            let old = entries(file)
            let keep = old.filter { now.timeIntervalSince($0.timestamp) < Self.retention && $0.timestamp <= now }
            if keep.isEmpty { try FileManager.default.removeItem(at: file) }
            else if keep.count != old.count {
                var data = Data()
                for entry in keep { data.append(try encoder().encode(entry)); data.append(10) }
                try data.write(to: file, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            }
        }
        try enforceLimit()
        lastCleanup = now
    }
    private func enforceLimit() throws {
        let list = files()
        var sizes: [(URL, Int)] = list.map { ($0, ((try? FileManager.default.attributesOfItem(atPath: $0.path)[.size]) as? NSNumber)?.intValue ?? 0) }
        var total = sizes.reduce(0) { $0 + $1.1 }
        while total > Self.maximumBytes, !sizes.isEmpty {
            let first = sizes.removeFirst(); try FileManager.default.removeItem(at: first.0); total -= first.1
        }
    }
    private func append(_ event: DiagnosticEvent) {
        do {
            try cleanup(now: clock())
            let hour = Int(event.timestamp.timeIntervalSince1970 / 3600)
            let url = directory.appendingPathComponent("events-\(hour).jsonl")
            var data = try encoder().encode(event); data.append(10)
            if !FileManager.default.fileExists(atPath: url.path) {
                guard FileManager.default.createFile(atPath: url.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { throw CocoaError(.fileWriteUnknown) }
            }
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.seekToEnd(); try handle.write(contentsOf: data)
            try enforceLimit(); failure = nil
        } catch { failure = "write_failed" }
    }
    func maintenance() { queue.async { do { try self.cleanup(now: self.clock(), force: true) } catch { self.failure = "cleanup_failed" } } }
    func snapshot(errorsOnly: Bool = false) -> [DiagnosticEvent] {
        queue.sync {
            do { try cleanup(now: clock(), force: true) } catch { failure = "cleanup_failed" }
            return files().flatMap(entries).filter { !errorsOnly || $0.level == "error" }.sorted { $0.timestamp < $1.timestamp }
        }
    }
    var unavailable: Bool { queue.sync { failure != nil } }
    func clear() throws { try queue.sync { for file in files() { try FileManager.default.removeItem(at: file) }; failure = nil } }
    func report(errorsOnly: Bool = false) -> String {
        let events = snapshot(errorsOnly: errorsOnly)
        return events.compactMap { try? encoder().encode($0) }.compactMap { String(data: $0, encoding: .utf8) }.joined(separator: "\n")
    }
}

func diagnosticReason(_ message: String) -> String {
    if message.contains("доступ") || message.contains("Универсальный") { return "permission_or_ui_access" }
    if message.contains("врем") || message.contains("замер") { return "timeout_or_measurement" }
    if message.contains("настройк") || message.contains("разрешён") || message.contains("стабильных") { return "selection_rules" }
    if message.contains("измен") { return "state_changed" }
    if message.contains("трафик") || message.contains("Трафик") || message.contains("HTTPS") { return "traffic_check" }
    if message.contains("пауз") || message.contains("приостанов") { return "paused" }
    if message.contains("отмен") { return "user_cancelled" }
    return "result"
}
