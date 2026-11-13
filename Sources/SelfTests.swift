import Foundation

func runSelfTests() {
    var count = 0
    func check(_ value: @autoclosure () -> Bool, _ message: String) {
        count += 1
        guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
    }
    check(parseCandidate("Германия, vless, ping 116, , selected")?.ping == 116, "ping")
    check(parseCandidate("Германия, vless, ping n/a, ,") == nil, "unavailable ping")
    check(parseCandidate("Германия, vless, ping -1, ,") == nil, "negative ping")
    check(parseCandidate("Подписка") == nil, "not a server")
    check(subscriptionDisplayName("subscription: My renamed profile") == "My renamed profile", "renamed profile")
    check(subscriptionDisplayName("subscription: ✨ Другая подписка 42 ") == "✨ Другая подписка 42", "unicode profile")
    check(selectedServerDescription("Германия, vless, ping 116, , selected"), "selected")
    check(!selectedServerDescription("selected VPN, vless, ping 116, ,"), "not selected")
    for name in ["Россия", "🇷🇺 Server", "Russia 2", "RU-01", "[RUS] #2", "РФ", "Moscow", "Санкт-Петербург", "Russian Federation"] {
        check(isRussianServer(name), "Russian: \(name)")
    }
    for name in ["Германия", "Peru", "Belarus", "Brussels", "США 👍", "Torrents Free"] { check(!isRussianServer(name), "not Russian: \(name)") }
    check(countryCode(for: "🇩🇪 Node") == "DE", "country flag")
    check(countryCode(for: "Германия") == "DE", "country Russian name")
    check(countryCode(for: "Netherlands") == "NL", "country English name")
    check(countryCode(for: "США 👍") == "US", "country USA")
    check(countryCode(for: "DE-01") == "DE", "country code")
    check(countryCode(for: "Torrents Free") == nil, "unknown country")
    let sub = "Test profile"
    let now = Date(timeIntervalSince1970: 10000)
    var prefs = MonitorPreferences()
    check(!serverAllowed("Россия", subscription: sub, preferences: prefs), "Russia forbidden")
    prefs.rules[MonitorPreferences.key(sub, "Россия")] = ServerRule(country: "DE")
    check(!serverAllowed("Россия", subscription: sub, preferences: prefs), "manual override cannot enable Russia")
    prefs.rules[MonitorPreferences.key(sub, "Custom")] = ServerRule(country: "RU")
    check(!serverAllowed("Custom", subscription: sub, preferences: prefs), "manual Russia forbidden")
    prefs.rules[MonitorPreferences.key(sub, "Custom")] = ServerRule(country: "NL")
    check(effectiveCountry("Custom", subscription: sub, preferences: prefs) == "NL", "country override")
    prefs.excludedCountries.append("DE")
    check(!serverAllowed("Германия", subscription: sub, preferences: prefs), "country exclusion")
    prefs.excludedCountries.removeAll { $0 == "DE" }
    prefs.blockUnknown = true
    check(!serverAllowed("Torrents Free", subscription: sub, preferences: prefs), "unknown blocked")
    prefs.blockUnknown = false
    check(serverAllowed("Torrents Free", subscription: sub, preferences: prefs), "unknown allowed")
    prefs.rules[MonitorPreferences.key(sub, "Custom")] = ServerRule(country: "NL", blocked: true)
    check(!serverAllowed("Custom", subscription: sub, preferences: prefs), "server blocked")
    prefs.records[MonitorPreferences.key(sub, "Германия")] = ServerRecord(successes: 1, failures: 1, blockedUntil: now.addingTimeInterval(10))
    check(!serverAllowed("Германия", subscription: sub, preferences: prefs, now: now), "cooldown")
    check(serverAllowed("Германия", subscription: sub, preferences: prefs, now: now.addingTimeInterval(11)), "cooldown expiry")
    prefs.records = [:]
    let samples = [
        [ServerCandidate(name: "Россия", ping: 1), ServerCandidate(name: "Германия", ping: 90), ServerCandidate(name: "США", ping: 120), ServerCandidate(name: "Flaky", ping: 2)],
        [ServerCandidate(name: "Россия", ping: 2), ServerCandidate(name: "Германия", ping: 1000), ServerCandidate(name: "США", ping: 130)],
        [ServerCandidate(name: "Россия", ping: 1), ServerCandidate(name: "Германия", ping: 100), ServerCandidate(name: "США", ping: 125)]
    ]
    var ranked = rankedServers(samples: samples, subscription: sub, preferences: prefs, now: now)
    check(ranked.map(\.name) == ["Германия", "США"], "median and majority exclude spikes and flaky server")
    check(ranked.first?.ping == 100, "median")
    prefs.pinned[sub] = "США"
    check(rankedServers(samples: samples, subscription: sub, preferences: prefs, now: now).map(\.name) == ["США"], "pinned only")
    prefs.pinned[sub] = "Россия"
    check(rankedServers(samples: samples, subscription: sub, preferences: prefs, now: now).isEmpty, "pinned forbidden has no fallback")
    prefs.pinned = [:]; prefs.favoriteCountries = ["US"]
    ranked = rankedServers(samples: samples, subscription: sub, preferences: prefs, now: now)
    check(ranked.first?.name == "Германия", "favorite does not dominate significantly faster server")
    prefs.records[MonitorPreferences.key(sub, "Германия")] = ServerRecord(successes: 0, failures: 3, blockedUntil: nil)
    check(rankedServers(samples: samples, subscription: sub, preferences: prefs, now: now).first?.name == "США", "failure history ranking")
    prefs.pauseUntil = now.addingTimeInterval(900)
    check(prefs.paused(at: now), "timed pause")
    check(!prefs.paused(at: now.addingTimeInterval(901)), "pause expires")
    prefs.manualPause = true
    check(prefs.paused(at: now.addingTimeInterval(100000)), "manual pause does not expire")
    let info = parseVPNInfo("Connected\n IPv4 : <dictionary> { Addresses : <array> { 0 : 198.18.0.1 } InterfaceName : utun9 }")
    check(info.connected && info.interface == "utun9" && info.address == "198.18.0.1", "tunnel parsing")
    let absent = parseVPNInfo("Disconnected\nStatus : 0")
    check(!absent.connected && absent.interface == nil, "no tunnel when disconnected")
    check(!TunnelProbe.check(absent).healthy, "cannot get green without tunnel")
    check(probeLatency(code: 0, output: "204 0.25 198.18.0.1", expectedAddress: "198.18.0.1") == 250, "healthy tunnel response")
    check(probeLatency(code: 0, output: "204 0.25 192.168.1.10", expectedAddress: "198.18.0.1") == nil, "direct interface cannot produce green")
    check(probeLatency(code: 0, output: "302 0.25 198.18.0.1", expectedAddress: "198.18.0.1") == nil, "captive redirect rejected")
    check(probeLatency(code: 0, output: "200 0.25 198.18.0.1", expectedAddress: "198.18.0.1") == nil, "unexpected endpoint content rejected")
    check(probeLatency(code: 7, output: "204 0.25 198.18.0.1", expectedAddress: "198.18.0.1") == nil, "curl failure rejected")
    check(probeLatency(code: 0, output: "204 nan 198.18.0.1", expectedAddress: "198.18.0.1") == nil, "invalid timing rejected")
    check(keepWorkingServer(current: ServerCandidate(name: "A", ping: 160), best: ServerCandidate(name: "B", ping: 150), pinned: nil), "small gain does not switch")
    check(!keepWorkingServer(current: ServerCandidate(name: "A", ping: 160), best: ServerCandidate(name: "B", ping: 60), pinned: nil), "large gain permits switch")
    check(!keepWorkingServer(current: ServerCandidate(name: "A", ping: 160), best: ServerCandidate(name: "B", ping: 150), pinned: "B"), "explicit pin takes precedence")
    let suite = "HappMonitorTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = MonitorStore(defaults: defaults)
    store.preferences = prefs; store.save(); store.log("Test event")
    let reloaded = MonitorStore(defaults: defaults)
    check(reloaded.preferences.manualPause, "pause persists across relaunch")
    check(reloaded.preferences.favoriteCountries == ["US"], "countries persist")
    reloaded.preferences.excludedCountries = []; reloaded.save()
    let unrestricted = MonitorStore(defaults: defaults)
    check(!unrestricted.preferences.excludedCountries.contains("RU"), "unchecked Russia stays unchecked after relaunch")
    check(serverAllowed("Россия", subscription: "Other profile", preferences: unrestricted.preferences), "Russia allowed when exclusion unchecked")
    check(reloaded.history.count == 1, "history persists")
    for index in 0..<150 { store.log("Test \(index)") }
    check(store.history.count == 100, "history bounded")
    print("\(count) checks passed")
}
