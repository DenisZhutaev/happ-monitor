import AppKit

private final class TopOriginView: NSView {
    override var isFlipped: Bool { true }
    override init(frame frameRect: NSRect) { super.init(frame: frameRect); setAccessibilityElement(true); setAccessibilityRole(.group) }
    required init?(coder: NSCoder) { super.init(coder: coder); setAccessibilityElement(true); setAccessibilityRole(.group) }
    override func accessibilityChildren() -> [Any]? { subviews }
}
final class SettingsWindow: NSObject, NSWindowDelegate, NSSearchFieldDelegate {
    private var window: NSWindow?
    private var tabs: NSTabView!
    private var callbacks: [ObjectIdentifier: () -> Void] = [:]
    private let store: MonitorStore
    var onChange: (() -> Void)?
    var onRequestNotifications: (() -> Void)?
    var onPause: ((Int) -> Void)?
    var onResume: (() -> Void)?
    private var countrySearch: NSSearchField?
    private var countryScroll: NSScrollView?
    private var countryCallbackKeys: [ObjectIdentifier] = []
    private var successNotificationControl: NSButton?
    private var failureNotificationControl: NSButton?
    func refreshNotificationControls() {
        failureNotificationControl?.state = store.preferences.notifications ? .on : .off
        successNotificationControl?.isEnabled = store.preferences.notifications
    }
    init(store: MonitorStore) { self.store = store }
    private let countries = Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }.sorted {
        (Locale(identifier: "ru_RU").localizedString(forRegionCode: $0) ?? $0) < (Locale(identifier: "ru_RU").localizedString(forRegionCode: $1) ?? $1)
    }
    private func countryTitle(_ code: String) -> String { "\(Locale(identifier: "ru_RU").localizedString(forRegionCode: code) ?? code) (\(code))" }
    private func label(_ text: String, x: CGFloat = 12, y: CGFloat, width: CGFloat = 700) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.frame = NSRect(x: x, y: y, width: width, height: 36)
        label.font = .systemFont(ofSize: 13)
        return label
    }
    private func checkbox(_ title: String, checked: Bool, x: CGFloat, y: CGFloat, width: CGFloat = 130, callback: @escaping (Bool) -> Void) -> NSButton {
        let button = NSButton(checkboxWithTitle: title, target: self, action: #selector(invoke(_:)))
        button.frame = NSRect(x: x, y: y, width: width, height: 26)
        button.state = checked ? .on : .off
        callbacks[ObjectIdentifier(button)] = { [weak button] in if let button { callback(button.state == .on) } }
        return button
    }
    @objc private func invoke(_ sender: NSControl) { callbacks[ObjectIdentifier(sender)]?() }
    private func changed() { store.save(); onChange?() }
    private func scroll(document: NSView) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 780, height: 480))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = document
        document.autoresizingMask = [.width]
        return scroll
    }
    private func addTab(_ title: String, _ view: NSView) {
        let tab = NSTabViewItem(identifier: title)
        tab.label = title; tab.view = view; tabs.addTabViewItem(tab)
    }
    func show(subscription: String?, servers: [ServerCandidate], history: Bool = false) {
        window?.close()
        NSApp.setActivationPolicy(.regular)
        callbacks.removeAll()
        countryCallbackKeys = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 550), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "Настройки Happ Monitor"
        window.delegate = self
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 800, height: 550)
        self.window = window
        tabs = NSTabView(frame: NSRect(x: 12, y: 12, width: 776, height: 526))
        tabs.autoresizingMask = [.width, .height]
        window.contentView?.addSubview(tabs)
        let general = TopOriginView(frame: NSRect(x: 0, y: 0, width: 750, height: 470))
        general.addSubview(label("Зелёный: трафик через VPN проходит. Жёлтый: проверка ещё не завершена или контрольные запросы не проходят. Красный: VPN отключён.", y: 14))
        general.addSubview(label("Проверка выполняется каждые 20 секунд запросами к Google или Cloudflare. Названия серверов и данные подписки им не передаются.", y: 64))
        general.addSubview(checkbox("Автовосстановление", checked: store.preferences.automatic, x: 12, y: 116, width: 400) { [weak self] value in self?.store.preferences.automatic = value; self?.changed() })
        let failureControl = checkbox("Уведомлять, если восстановить VPN не удалось", checked: store.preferences.notifications, x: 12, y: 154, width: 600) { [weak self] value in
            self?.store.preferences.notifications = value; self?.successNotificationControl?.isEnabled = value
            self?.changed(); if value { self?.onRequestNotifications?() }
        }
        failureNotificationControl = failureControl; general.addSubview(failureControl)
        let successControl = checkbox("Также уведомлять об успешном восстановлении", checked: store.preferences.notifySuccess, x: 12, y: 192, width: 600) { [weak self] value in self?.store.preferences.notifySuccess = value; self?.changed() }
        successControl.isEnabled = store.preferences.notifications; successNotificationControl = successControl; general.addSubview(successControl)
        general.addSubview(checkbox("Не выбирать серверы с неизвестной страной", checked: store.preferences.blockUnknown, x: 12, y: 230, width: 600) { [weak self] value in self?.store.preferences.blockUnknown = value; self?.changed() })
        general.addSubview(label("Страны исключаются галочками. Если страна сервера не определилась, укажите её на вкладке «Серверы».", y: 278))
        general.addSubview(label("Для переключения серверов может понадобиться открытое окно Happ. Сама проверка соединения работает в фоне.", y: 332))
        general.addSubview(label("Настройки сохраняются сразу. Неудачный сервер исключается на 10 минут. При выборе учитываются три замера и история подключений.", y: 392))
        for (index, entry) in [("Пауза 15 мин", 15), ("Пауза на час", 60), ("До включения", -1), ("Возобновить", 0)].enumerated() {
            let button = NSButton(title: entry.0, target: self, action: #selector(invoke(_:)))
            button.frame = NSRect(x: 12 + index * 180, y: 435, width: 170, height: 28)
            button.bezelStyle = .rounded
            callbacks[ObjectIdentifier(button)] = { [weak self] in
                if entry.1 == 0 { self?.onResume?() } else { self?.onPause?(entry.1) }
            }
            general.addSubview(button)
        }
        addTab("Основные", general)

        let countryPage = TopOriginView(frame: NSRect(x: 0, y: 0, width: 750, height: 470))
        let search = NSSearchField(frame: NSRect(x: 12, y: 10, width: 400, height: 28))
        search.placeholderString = "Найти страну по названию или коду"; search.delegate = self
        search.setAccessibilityLabel("Поиск страны"); countrySearch = search; countryPage.addSubview(search)
        let list = scroll(document: TopOriginView(frame: .zero))
        list.frame = NSRect(x: 0, y: 48, width: 750, height: 422); countryScroll = list
        countryPage.addSubview(list); rebuildCountryList(); addTab("Страны", countryPage)

        let serverDoc = TopOriginView(frame: NSRect(x: 0, y: 0, width: 750, height: max(460, CGFloat(servers.count * 46 + 130))))
        serverDoc.addSubview(label(subscription ?? "Подписка не определена. Откройте Happ и выберите сервер.", y: 8))
        serverDoc.addSubview(label("Закреплённый сервер:", y: 50, width: 220))
        let pinned = NSPopUpButton(frame: NSRect(x: 220, y: 46, width: 450, height: 30))
        pinned.addItem(withTitle: "Автоматический выбор")
        pinned.lastItem?.representedObject = ""
        for server in servers {
            pinned.addItem(withTitle: server.name); pinned.lastItem?.representedObject = server.name
        }
        if let subscription, let name = store.preferences.pinned[subscription],
           let item = pinned.itemArray.first(where: { $0.representedObject as? String == name }) { pinned.select(item) }
        pinned.isEnabled = subscription != nil
        pinned.target = self; pinned.action = #selector(invoke(_:))
        callbacks[ObjectIdentifier(pinned)] = { [weak self, weak pinned] in
            guard let self, let subscription else { return }
            self.store.preferences.pinned[subscription] = pinned?.selectedItem?.representedObject as? String
            self.changed()
        }
        serverDoc.addSubview(pinned)
        serverDoc.addSubview(label("При закреплении другие серверы не выбираются. Исключения стран и серверов имеют приоритет.", y: 83))
        if let subscription {
            for (index, server) in servers.enumerated() {
                let y = CGFloat(index * 46 + 126)
                let key = MonitorPreferences.key(subscription, server.name)
                let rule = store.preferences.rules[key] ?? ServerRule()
                serverDoc.addSubview(label(server.name, y: y + 4, width: 220))
                let popup = NSPopUpButton(frame: NSRect(x: 240, y: y, width: 270, height: 30))
                let inferred = countryCode(for: server.name).map(countryTitle) ?? "не определена"
                popup.addItem(withTitle: "Авто: " + inferred); popup.lastItem?.representedObject = ""
                for code in countries { popup.addItem(withTitle: countryTitle(code)); popup.lastItem?.representedObject = code }
                if let country = rule.country, let item = popup.itemArray.first(where: { $0.representedObject as? String == country }) { popup.select(item) }
                popup.target = self; popup.action = #selector(invoke(_:))
                popup.setAccessibilityLabel("Страна сервера: " + server.name)
                callbacks[ObjectIdentifier(popup)] = { [weak self, weak popup] in
                    guard let self else { return }
                    var rule = self.store.preferences.rules[key] ?? ServerRule()
                    let country = popup?.selectedItem?.representedObject as? String
                    rule.country = country == "" ? nil : country
                    self.store.preferences.rules[key] = rule; self.changed()
                }
                serverDoc.addSubview(popup)
                let blocked = checkbox("Запрет", checked: rule.blocked, x: 525, y: y, width: 95) { [weak self] value in
                    guard let self else { return }; var rule = self.store.preferences.rules[key] ?? ServerRule()
                    rule.blocked = value; self.store.preferences.rules[key] = rule; self.changed()
                }
                blocked.setAccessibilityLabel("Запретить сервер: " + server.name); serverDoc.addSubview(blocked)
                let favorite = checkbox("Избранный", checked: rule.favorite, x: 625, y: y, width: 120) { [weak self] value in
                    guard let self else { return }; var rule = self.store.preferences.rules[key] ?? ServerRule()
                    rule.favorite = value; self.store.preferences.rules[key] = rule; self.changed()
                }
                favorite.setAccessibilityLabel("Избранный сервер: " + server.name); serverDoc.addSubview(favorite)
            }
        }
        addTab("Серверы", scroll(document: serverDoc))
        let historyScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 750, height: 470))
        historyScroll.hasVerticalScroller = true
        let text = NSTextView(frame: historyScroll.bounds)
        text.isEditable = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.autoresizingMask = [.width]; text.isVerticallyResizable = true
        let formatter = DateFormatter(); formatter.dateFormat = "dd.MM HH:mm:ss"
        text.string = store.history.reversed().map { "\(formatter.string(from: $0.date))  \($0.message)" }.joined(separator: "\n\n")
        if text.string.isEmpty { text.string = "Событий пока нет." }
        historyScroll.documentView = text
        addTab("История", historyScroll)
        if history { tabs.selectTabViewItem(at: 3) }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { NSApp.setActivationPolicy(.accessory) }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === countrySearch { rebuildCountryList() }
    }
    private func rebuildCountryList() {
        for key in countryCallbackKeys { callbacks.removeValue(forKey: key) }; countryCallbackKeys = []
        let query = countrySearch?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let filtered = countries.filter { query.isEmpty || countryTitle($0).localizedCaseInsensitiveContains(query) }
        let doc = TopOriginView(frame: NSRect(x: 0, y: 0, width: 750, height: max(420, CGFloat(filtered.count * 34 + 60))))
        doc.addSubview(label(filtered.isEmpty ? "Ничего не найдено" : "Исключение запрещает автовыбор. Избранное даёт небольшой приоритет.", y: 10))
        for (index, code) in filtered.enumerated() {
            let y = CGFloat(index * 34 + 60)
            doc.addSubview(label(countryTitle(code), y: y + 4, width: 350))
            let excluded = checkbox("Исключить", checked: store.preferences.excludedCountries.contains(code), x: 380, y: y) { [weak self] value in
                guard let self else { return }
                self.store.preferences.excludedCountries.removeAll { $0 == code }
                if value { self.store.preferences.excludedCountries.append(code) }; self.changed()
            }
            excluded.setAccessibilityLabel("Исключить: " + countryTitle(code))
            countryCallbackKeys.append(ObjectIdentifier(excluded)); doc.addSubview(excluded)
            let favorite = checkbox("Избранная", checked: store.preferences.favoriteCountries.contains(code), x: 540, y: y) { [weak self] value in
                guard let self else { return }
                self.store.preferences.favoriteCountries.removeAll { $0 == code }
                if value { self.store.preferences.favoriteCountries.append(code) }; self.changed()
            }
            favorite.setAccessibilityLabel("Избранная страна: " + countryTitle(code))
            countryCallbackKeys.append(ObjectIdentifier(favorite)); doc.addSubview(favorite)
        }
        countryScroll?.documentView = doc
        doc.scroll(.zero)
    }
}
