import AppKit

/// Uses real settings views with isolated preferences; never controls Happ or the network.
func runUISelfTests() {
    let app = NSApplication.shared
    app.setActivationPolicy(.regular)
    let suite = "HappMonitorUITests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    let store = MonitorStore(defaults: defaults)
    let settings = SettingsWindow(store: store)
    defer { defaults.removePersistentDomain(forName: suite); UIStrings.overrideLanguage = nil }
    var count = 0
    func check(_ value: Bool, _ message: String) { count += 1; if !value { fputs("FAIL UI: \(message)\n", stderr); exit(1) } }
    func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(descendants) }
    let servers = [ServerCandidate(name: "Demo Server 42", ping: 42), ServerCandidate(name: "🇫🇷 Paris", ping: 60)]
    for code in ["ru", "en", "zh-Hans", "es", "fr", "ar"] {
        UIStrings.overrideLanguage = code
        settings.show(subscription: "Demo subscription", servers: servers)
        guard let window = app.windows.first(where: { $0.title == L("Настройки Happ Monitor") }), let root = window.contentView, let tabs = root.subviews.first as? NSTabView else { fputs("Missing settings window\n", stderr); exit(1) }
        check(tabs.tabViewItems.count == 6, "six tabs in \(code)")
        for tab in tabs.tabViewItems {
            let source = tab.identifier as! String
            check(tab.label == L(source), "tab localized: \(code)/\(source)")
            tabs.selectTabViewItem(tab)
            window.layoutIfNeeded()
            guard let view = tab.view else { exit(1) }
            let views = descendants(view)
            if source == "Основные" {
                let labels = views.compactMap { $0 as? NSTextField }
                check(!labels.isEmpty, "general labels exist")
                for label in labels {
                    if code != "ru" { check(label.stringValue.range(of: "[А-Яа-яЁё]", options: .regularExpression) == nil, "no untranslated general text \(code)") }
                    check(label.alignment == (code == "ar" ? .right : .left), "text alignment \(code)")
                }
                let pause = views.compactMap { $0 as? NSButton }.first { $0.title == L("Пауза 15 мин") }!
                let resume = views.compactMap { $0 as? NSButton }.first { $0.title == L("Возобновить") }!
                check(code == "ar" ? pause.frame.minX > resume.frame.minX : pause.frame.minX < resume.frame.minX, "pause row mirrors for RTL")
            }
            if source == "Серверы" {
                check(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Demo subscription" }, "subscription unchanged \(code)")
                check(views.compactMap { $0 as? NSTextField }.contains { $0.stringValue == "Demo Server 42" }, "server unchanged \(code)")
            }
            if source == "Язык" {
                let popup = views.compactMap { $0 as? NSPopUpButton }.first!
                check(popup.numberOfItems == 7, "six languages plus system option")
            }
            for button in views.compactMap({ $0 as? NSButton }) {
                check(button.frame.minX >= 0 && button.frame.maxX <= (button.superview?.bounds.width ?? 0) + 1, "button inside layout \(code)/\(source): \(button.title) \(button.frame) parent=\(button.superview?.bounds ?? .zero)")
            }
        }
        check(store.preferences.excludedCountries == ["RU"] && store.preferences.automatic, "language preserves rules \(code)")
        window.close()
    }
    print("\(count) UI checks passed across 6 languages")
}
