import Foundation

func runFeatureTests() -> Int {
    var count = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        count += 1
        if !value() { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    check(UIStrings.catalog.count >= 160, "bundled translation catalogue")
    for code in ["en", "zh-Hans", "es", "fr", "ar"] {
        for (key, row) in UIStrings.catalog {
            check(!(row[code] ?? "").isEmpty, "translation \(code): \(key)")
            let args = key.components(separatedBy: "%@").count - 1
            let value = row[code] ?? ""
            for i in 0..<args { check(value.contains("{\(i)}"), "placeholder \(i) in \(code)") }
            let sample = key.replacingOccurrences(of: "%@", with: "NODE_42")
            let translated = UIStrings.text(sample, language: code)
            check(!translated.contains("{0}"), "placeholder substituted in \(code)")
            if args > 0 { check(translated.contains("NODE_42"), "dynamic name preserved in \(code)") }
        }
        check(UIStrings.text("Настройки Happ Monitor", language: code) != "Настройки Happ Monitor", "settings translated")
    }
    check(UIStrings.resolved("system", preferred: ["fr-CA"]) == "fr", "French locale")
    check(UIStrings.resolved("system", preferred: ["zh-Hant-TW"]) == "zh-Hans", "Chinese fallback")
    check(UIStrings.resolved("system", preferred: ["de-DE"]) == "en", "unsupported fallback")
    check(UIStrings.resolved("ru", preferred: ["en-US"]) == "ru", "explicit language")
    check(UIStrings.resolved("invalid", preferred: ["ar-SA"]) == "ar", "invalid preference fallback")
    check(UIStrings.text("Сервер: Custom %@ {0}", language: "en").contains("Custom %@ {0}"), "opaque names")
    check(UIStrings.text("Подключён: Node {1} · HTTPS 42 мс", language: "en").contains("Node {1}"), "names cannot inject format slots")
    let arabic = UIStrings.text("Сервер: Node 42", language: "ar")
    check(arabic.contains("\u{2068}Node 42\u{2069}"), "RTL name isolation")
    check(UIStrings.text("Проверка соединения…", language: "ru") == "Проверка соединения…", "Russian original")

    let folder = FileManager.default.temporaryDirectory.appendingPathComponent("HappDiagnosticsTests-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: folder) }
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    let log = DiagnosticLog(directory: folder, clock: { now })
    log.record("test.started", operation: "op-1", fields: ["status": "Connected", "token": "SECRET", "server_name": "PRIVATE", "subscription_url": "SECRET_URL"])
    check(log.snapshot().count == 1, "log write")
    check(log.snapshot()[0].fields == ["status": "Connected"], "only approved fields logged")
    check(!log.report().contains("SECRET"), "no disallowed secret fields")
    check(log.snapshot()[0].operation == "op-1", "operation correlation")
    let mode = (try? FileManager.default.attributesOfItem(atPath: folder.path)[.posixPermissions]) as? NSNumber
    check(mode?.intValue == 0o700, "log directory private")
    now = now.addingTimeInterval(24 * 3600 - 1)
    check(log.snapshot().count == 1, "record kept within 24h")
    log.record("test.failed", level: "error", operation: "op-2", fields: ["error_code": "28"])
    check(log.snapshot(errorsOnly: true).count == 1, "error filter")
    now = now.addingTimeInterval(1)
    check(log.snapshot().count == 1, "exact 24h expiration")
    check(log.snapshot()[0].event == "test.failed", "new record retained")
    let restarted = DiagnosticLog(directory: folder, clock: { now })
    check(restarted.snapshot().count == 1, "records survive restart")
    check(restarted.report().contains("op-2"), "export includes operation")
    let file = (try! FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)).first!
    let fileMode = (try? FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]) as? NSNumber
    check(fileMode?.intValue == 0o600, "log file private")
    now = now.addingTimeInterval(24 * 3600)
    check(restarted.snapshot().isEmpty, "expired files cleared on next launch/read")
    log.record("after.expiration")
    _ = log.snapshot()
    try! log.clear()
    check(log.snapshot().isEmpty, "manual clear")
    let broken = folder.appendingPathComponent("not-directory")
    try! Data("x".utf8).write(to: broken)
    let unavailable = DiagnosticLog(directory: broken)
    unavailable.record("test")
    _ = unavailable.snapshot()
    check(unavailable.unavailable, "write error exposed without crashing")
    let large = folder.appendingPathComponent("events-1.jsonl")
    try! Data(repeating: 65, count: DiagnosticLog.maximumBytes + 1).write(to: large)
    _ = log.snapshot()
    check(!FileManager.default.fileExists(atPath: large.path), "oversized invalid shard removed")
    let bigEntry = DiagnosticEvent(timestamp: now, level: "info", event: "size.test", operation: nil, fields: ["status": String(repeating: "A", count: DiagnosticLog.maximumBytes + 1)])
    let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
    try! encoder.encode(bigEntry).write(to: large)
    _ = log.snapshot()
    check(!FileManager.default.fileExists(atPath: large.path), "20 MB cap enforced on valid records")
    var preferences = MonitorPreferences()
    check(selectionExclusion("Россия", subscription: "S", preferences: preferences) == "country_excluded", "diagnose country exclusion")
    preferences.excludedCountries = []; preferences.blockUnknown = true
    check(selectionExclusion("Custom", subscription: "S", preferences: preferences) == "unknown_country", "diagnose unknown country")
    preferences.blockUnknown = false; preferences.pinned["S"] = "A"
    check(selectionExclusion("B", subscription: "S", preferences: preferences) == "other_server_pinned", "diagnose pinned server")
    preferences.pinned = [:]; preferences.rules[MonitorPreferences.key("S", "B")] = ServerRule(blocked: true)
    check(selectionExclusion("B", subscription: "S", preferences: preferences) == "server_excluded", "diagnose explicit exclusion")
    return count
}
