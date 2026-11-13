import Foundation

struct ServerRule: Codable {
    var country: String? = nil
    var blocked = false
    var favorite = false
}
struct ServerRecord: Codable {
    var successes = 0
    var failures = 0
    var blockedUntil: Date? = nil
}
struct MonitorPreferences: Codable {
    var automatic = true
    var manualPause = false
    var pauseUntil: Date? = nil
    var excludedCountries = ["RU"]
    var favoriteCountries: [String] = []
    var blockUnknown = false
    var notifications = true
    var notifySuccess = false
    var notificationPermissionRequested = false
    var rules: [String: ServerRule] = [:]
    var records: [String: ServerRecord] = [:]
    var pinned: [String: String] = [:]
    func paused(at now: Date = Date()) -> Bool { manualPause || (pauseUntil.map { $0 > now } ?? false) }
    static func key(_ subscription: String, _ server: String) -> String { subscription + "\u{1F}" + server }
}
struct HistoryEntry: Codable {
    var date: Date
    var message: String
}
final class MonitorStore {
    static let shared = MonitorStore()
    var preferences: MonitorPreferences
    private(set) var history: [HistoryEntry]
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        preferences = defaults.data(forKey: "preferences.v2").flatMap { try? JSONDecoder().decode(MonitorPreferences.self, from: $0) } ?? MonitorPreferences()
        history = defaults.data(forKey: "history.v2").flatMap { try? JSONDecoder().decode([HistoryEntry].self, from: $0) } ?? []
    }
    private let defaults: UserDefaults
    func save() { if let data = try? JSONEncoder().encode(preferences) { defaults.set(data, forKey: "preferences.v2") } }
    func log(_ message: String) {
        if let last = history.last, last.message == message, Date().timeIntervalSince(last.date) < 120 { return }
        history.append(HistoryEntry(date: Date(), message: message))
        history = Array(history.suffix(100))
        if let data = try? JSONEncoder().encode(history) { defaults.set(data, forKey: "history.v2") }
    }
    func outcome(subscription: String, server: String, success: Bool) {
        let key = MonitorPreferences.key(subscription, server)
        var record = preferences.records[key] ?? ServerRecord()
        if success { record.successes += 1; record.blockedUntil = nil }
        else { record.failures += 1; record.blockedUntil = Date().addingTimeInterval(600) }
        preferences.records[key] = record
        save()
    }
}

private let countryCache = NSCache<NSString, NSString>()
func countryCode(for name: String) -> String? {
    let key = name as NSString
    if let cached = countryCache.object(forKey: key) { return cached.length == 0 ? nil : cached as String }
    let result = inferCountryCode(for: name)
    countryCache.setObject((result ?? "") as NSString, forKey: key)
    return result
}
private func inferCountryCode(for name: String) -> String? {
    if isRussianServer(name) { return "RU" }
    let scalars = Array(name.unicodeScalars)
    if scalars.count > 1 {
        for index in 0..<(scalars.count - 1) {
            let a = scalars[index].value, b = scalars[index + 1].value
            if (0x1F1E6...0x1F1FF).contains(a) && (0x1F1E6...0x1F1FF).contains(b) {
                let code = String(UnicodeScalar(a - 0x1F1E6 + 65)!) + String(UnicodeScalar(b - 0x1F1E6 + 65)!)
                if Locale.Region.isoRegions.map(\.identifier).contains(code) { return code }
            }
        }
    }
    for code in Locale.Region.isoRegions.map(\.identifier) where code.count == 2 {
        let labels = [Locale(identifier: "ru_RU").localizedString(forRegionCode: code), Locale(identifier: "en_US").localizedString(forRegionCode: code), code].compactMap { $0 }
        for label in labels {
            let pattern = "(?i)(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: label) + "(?![\\p{L}\\p{N}])"
            if name.range(of: pattern, options: .regularExpression) != nil { return code }
        }
    }
    if name.range(of: #"(?i)(?<![\p{L}])(сша|usa|uk)(?![\p{L}])"#, options: .regularExpression) != nil {
        return name.lowercased().contains("uk") ? "GB" : "US"
    }
    return nil
}
func effectiveCountry(_ name: String, subscription: String, preferences: MonitorPreferences) -> String? {
    if isRussianServer(name) { return "RU" }
    return preferences.rules[MonitorPreferences.key(subscription, name)]?.country ?? countryCode(for: name)
}
func serverAllowed(_ name: String, subscription: String, preferences: MonitorPreferences, now: Date = Date(), checkCooldown: Bool = true) -> Bool {
    let key = MonitorPreferences.key(subscription, name)
    let rule = preferences.rules[key] ?? ServerRule()
    let country = effectiveCountry(name, subscription: subscription, preferences: preferences)
    if rule.blocked { return false }
    if let country = country, preferences.excludedCountries.contains(country) { return false }
    if country == nil && preferences.blockUnknown { return false }
    if checkCooldown, let until = preferences.records[key]?.blockedUntil, until > now { return false }
    if let pinned = preferences.pinned[subscription], !pinned.isEmpty, pinned != name { return false }
    return true
}
func rankedServers(samples: [[ServerCandidate]], subscription: String, preferences: MonitorPreferences, now: Date = Date()) -> [ServerCandidate] {
    var values: [String: [Int]] = [:]
    for sample in samples {
        for (name, servers) in Dictionary(grouping: sample, by: \.name) {
            if let ping = servers.map(\.ping).min(), ping > 0 { values[name, default: []].append(ping) }
        }
    }
    let minimum = max(1, samples.count / 2 + 1)
    let candidates = values.compactMap { name, pings -> ServerCandidate? in
        guard pings.count >= minimum, serverAllowed(name, subscription: subscription, preferences: preferences, now: now) else { return nil }
        let sorted = pings.sorted()
        return ServerCandidate(name: name, ping: sorted[sorted.count / 2])
    }
    func score(_ server: ServerCandidate) -> Double {
        let key = MonitorPreferences.key(subscription, server.name)
        let record = preferences.records[key] ?? ServerRecord()
        let rate = Double(record.failures) / Double(max(1, record.successes + record.failures))
        let country = effectiveCountry(server.name, subscription: subscription, preferences: preferences)
        let favorite = preferences.rules[key]?.favorite == true || country.map { preferences.favoriteCountries.contains($0) } == true
        return Double(server.ping) * (1 + rate * 2) * (favorite ? 0.8 : 1)
    }
    return candidates.sorted { score($0) == score($1) ? $0.name < $1.name : score($0) < score($1) }
}
func keepWorkingServer(current: ServerCandidate, best: ServerCandidate, pinned: String?) -> Bool {
    guard pinned == nil || pinned == "" else { return current.name == best.name }
    return current.name == best.name || current.ping - best.ping < max(30, current.ping / 5)
}

struct CommandResult { let code: Int32; let output: String }
func runCommand(_ executable: String, _ arguments: [String], timeout: Double = 10) -> CommandResult {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
        try process.run()
        let work = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: work)
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        work.cancel()
        return CommandResult(code: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    } catch { return CommandResult(code: -1, output: "") }
}
struct VPNInfo {
    let status: String
    let interface: String?
    let address: String?
    var connected: Bool { status == "Connected" }
}
func parseVPNInfo(_ output: String) -> VPNInfo {
    func capture(_ pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let range = Range(match.range(at: 1), in: output) else { return nil }
        return String(output[range])
    }
    return VPNInfo(status: output.components(separatedBy: .newlines).first ?? "Unknown",
                   interface: capture(#"InterfaceName\s*:\s*(utun\d+)"#),
                   address: capture(#"Addresses\s*:\s*<array>\s*\{\s*0\s*:\s*([0-9.]+)"#))
}
func happStatus() -> VPNInfo {
    let result = runCommand("/usr/sbin/scutil", ["--nc", "status", "Happ"], timeout: 5)
    return result.code == 0 ? parseVPNInfo(result.output) : VPNInfo(status: "Unknown", interface: nil, address: nil)
}
struct ProbeResult {
    let healthy: Bool
    let verified: Bool
    let milliseconds: Int?
    let message: String
}
func probeLatency(code: Int32, output: String, expectedAddress: String) -> Int? {
    let parts = output.split(separator: " ").map(String.init)
    guard code == 0, parts.count == 3, parts[0] == "204", parts[2] == expectedAddress,
          let seconds = Double(parts[1]), seconds.isFinite, seconds >= 0, seconds < 60 else { return nil }
    return Int(seconds * 1000)
}
final class TunnelProbe {
    static let endpoints = ["https://www.gstatic.com/generate_204", "https://cp.cloudflare.com/generate_204"]
    static func check(_ vpn: VPNInfo) -> ProbeResult {
        guard vpn.connected, let interface = vpn.interface, interface.range(of: #"^utun[0-9]+$"#, options: .regularExpression) != nil,
              let address = vpn.address else { return ProbeResult(healthy: false, verified: false, milliseconds: nil, message: "Интерфейс туннеля не определён") }
        for url in endpoints {
            let result = runCommand("/usr/bin/curl", ["-q", "--silent", "--ipv4", "--noproxy", "*", "--interface", "if!" + interface,
                "--connect-timeout", "4", "--max-time", "7", "--max-filesize", "4096", "--output", "/dev/null", "--write-out", "%{http_code} %{time_total} %{local_ip}", url], timeout: 9)
            if let milliseconds = probeLatency(code: result.code, output: result.output, expectedAddress: address) {
                return ProbeResult(healthy: true, verified: true, milliseconds: milliseconds, message: "HTTPS через туннель работает")
            }
        }
        return ProbeResult(healthy: false, verified: true, milliseconds: nil, message: "Контрольные HTTPS-запросы через туннель не прошли")
    }
}
