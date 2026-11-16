import AppKit
import ApplicationServices

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
    var onLanguageChange: (() -> Void)?
    var onRequestControl: (() -> Void)?
    var onOpenHapp: (() -> Void)?
    private var diagnosticText: NSTextView?
    private var permissionLabel: NSTextField?
    private var serviceLabel: NSTextField?
    var connectionStatus: (() -> String)?
    private var errorsOnly = false
    private var savedSubscription: String?
    private var savedServers: [ServerCandidate] = []
    private var refreshTimer: Timer?
    private var countryLocale: Locale { UIStrings.locale }
    private var countrySearch: NSSearchField?
    private var countryScroll: NSScrollView?
    private var mirroredViews = Set<ObjectIdentifier>()
    private var countryCallbackKeys: [ObjectIdentifier] = []
    private var successNotificationControl: NSButton?
    private var failureNotificationControl: NSButton?
    func refreshNotificationControls() {
        failureNotificationControl?.state = store.preferences.notifications ? .on : .off
        successNotificationControl?.isEnabled = store.preferences.notifications
    }
    init(store: MonitorStore) { self.store = store }
    private var countries: [String] { Locale.Region.isoRegions.map(\.identifier).filter { $0.count == 2 }.sorted {
        (countryLocale.localizedString(forRegionCode: $0) ?? $0) < (countryLocale.localizedString(forRegionCode: $1) ?? $1)
    } }
    private func countryTitle(_ code: String) -> String { "\(countryLocale.localizedString(forRegionCode: code) ?? code) (\(code))" }
    private func label(_ text: String, x: CGFloat = 12, y: CGFloat, width: CGFloat = 700, localized: Bool = true) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: localized ? L(text) : text)
        label.frame = NSRect(x: x, y: y, width: width, height: 36)
        label.font = .systemFont(ofSize: 13)
        return label
    }
    private func checkbox(_ title: String, checked: Bool, x: CGFloat, y: CGFloat, width: CGFloat = 130, callback: @escaping (Bool) -> Void) -> NSButton {
        let button = NSButton(checkboxWithTitle: L(title), target: self, action: #selector(invoke(_:)))
        button.frame = NSRect(x: x, y: y, width: width, height: 26)
        button.state = checked ? .on : .off
        callbacks[ObjectIdentifier(button)] = { [weak button] in if let button { callback(button.state == .on) } }
        return button
    }
    @objc private func invoke(_ sender: NSControl) { callbacks[ObjectIdentifier(sender)]?() }
    private func changed() { store.save(); onChange?() }
    private func scroll(document: NSView) -> NSScrollView {
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 750, height: 480))
        scroll.hasVerticalScroller = true
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = document
        document.autoresizingMask = [.width]
        return scroll
    }
    private func addTab(_ title: String, _ view: NSView) {
        let tab = NSTabViewItem(identifier: title)
        tab.label = L(title); tab.view = view; tabs.addTabViewItem(tab)
    }
    func show(subscription: String?, servers: [ServerCandidate], history: Bool = false) {
        refreshTimer?.invalidate(); window?.close()
        savedSubscription = subscription; savedServers = servers
        NSApp.setActivationPolicy(.regular)
        callbacks.removeAll(); mirroredViews.removeAll()
        countryCallbackKeys = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 800, height: 550), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = L("Настройки Happ Monitor")
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
            let button = NSButton(title: L(entry.0), target: self, action: #selector(invoke(_:)))
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
        search.placeholderString = L("Найти страну по названию или коду"); search.delegate = self
        search.setAccessibilityLabel(L("Поиск страны")); countrySearch = search; countryPage.addSubview(search)
        let list = scroll(document: TopOriginView(frame: .zero))
        list.frame = NSRect(x: 0, y: 48, width: 750, height: 422); countryScroll = list
        countryPage.addSubview(list); rebuildCountryList(); addTab("Страны", countryPage)

        let serverDoc = TopOriginView(frame: NSRect(x: 0, y: 0, width: 750, height: max(460, CGFloat(servers.count * 46 + 130))))
        serverDoc.addSubview(label(subscription ?? "Подписка не определена. Откройте Happ и выберите сервер.", y: 8, localized: subscription == nil))
        serverDoc.addSubview(label("Закреплённый сервер:", y: 50, width: 220))
        let pinned = NSPopUpButton(frame: NSRect(x: 220, y: 46, width: 450, height: 30))
        pinned.addItem(withTitle: L("Автоматический выбор"))
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
                serverDoc.addSubview(label(server.name, y: y + 4, width: 220, localized: false))
                let popup = NSPopUpButton(frame: NSRect(x: 240, y: y, width: 270, height: 30))
                let inferred = countryCode(for: server.name).map(countryTitle) ?? L("не определена")
                popup.addItem(withTitle: L("Авто: ") + inferred); popup.lastItem?.representedObject = ""
                for code in countries { popup.addItem(withTitle: countryTitle(code)); popup.lastItem?.representedObject = code }
                if let country = rule.country, let item = popup.itemArray.first(where: { $0.representedObject as? String == country }) { popup.select(item) }
                popup.target = self; popup.action = #selector(invoke(_:))
                popup.setAccessibilityLabel(L("Страна сервера: %@".replacingOccurrences(of: "%@", with: server.name)))
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
                blocked.setAccessibilityLabel(L("Запретить сервер: %@".replacingOccurrences(of: "%@", with: server.name))); serverDoc.addSubview(blocked)
                let favorite = checkbox("Избранный", checked: rule.favorite, x: 625, y: y, width: 120) { [weak self] value in
                    guard let self else { return }; var rule = self.store.preferences.rules[key] ?? ServerRule()
                    rule.favorite = value; self.store.preferences.rules[key] = rule; self.changed()
                }
                favorite.setAccessibilityLabel(L("Избранный сервер: %@".replacingOccurrences(of: "%@", with: server.name))); serverDoc.addSubview(favorite)
            }
        }
        addTab("Серверы", scroll(document: serverDoc))
        let historyScroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 750, height: 470))
        historyScroll.hasVerticalScroller = true
        let text = NSTextView(frame: historyScroll.bounds)
        text.isEditable = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        text.autoresizingMask = [.width]; text.isVerticallyResizable = true
        let formatter = DateFormatter(); formatter.locale = UIStrings.locale; formatter.dateStyle = .short; formatter.timeStyle = .medium
        text.string = store.history.reversed().map { "\(formatter.string(from: $0.date))  \(L($0.message))" }.joined(separator: "\n\n")
        if text.string.isEmpty { text.string = L("Событий пока нет.") }
        historyScroll.documentView = text
        addTab("История", historyScroll)
        addLanguageTab()
        addDiagnosticsTab()
        mirrorAndAlign(window.contentView!)
        if history { tabs.selectTabViewItem(at: 3) }
        window.center(); window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
    }
    func windowWillClose(_ notification: Notification) { refreshTimer?.invalidate(); NSApp.setActivationPolicy(.accessory) }
    func controlTextDidChange(_ notification: Notification) {
        if notification.object as? NSSearchField === countrySearch { rebuildCountryList() }
    }
    private func rebuildCountryList() {
        for key in countryCallbackKeys { callbacks.removeValue(forKey: key) }; countryCallbackKeys = []
        let query = countrySearch?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let filtered = countries.filter { code in
            query.isEmpty || [countryTitle(code), Locale(identifier: "ru").localizedString(forRegionCode: code) ?? "", Locale(identifier: "en").localizedString(forRegionCode: code) ?? ""].contains { $0.localizedCaseInsensitiveContains(query) }
        }
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
            excluded.setAccessibilityLabel(L("Исключить: %@".replacingOccurrences(of: "%@", with: countryTitle(code))))
            countryCallbackKeys.append(ObjectIdentifier(excluded)); doc.addSubview(excluded)
            let favorite = checkbox("Избранная", checked: store.preferences.favoriteCountries.contains(code), x: 540, y: y) { [weak self] value in
                guard let self else { return }
                self.store.preferences.favoriteCountries.removeAll { $0 == code }
                if value { self.store.preferences.favoriteCountries.append(code) }; self.changed()
            }
            favorite.setAccessibilityLabel(L("Избранная страна: %@".replacingOccurrences(of: "%@", with: countryTitle(code))))
            countryCallbackKeys.append(ObjectIdentifier(favorite)); doc.addSubview(favorite)
        }
        countryScroll?.documentView = doc
        mirrorAndAlign(doc); doc.scroll(.zero)
    }
    private func mirrorAndAlign(_ view: NSView) {
        if let field = view as? NSTextField {
            field.baseWritingDirection = UIStrings.rtl ? .rightToLeft : .leftToRight
            field.alignment = UIStrings.rtl ? .right : .left
        }
        if let text = view as? NSTextView { text.baseWritingDirection = UIStrings.rtl ? .rightToLeft : .leftToRight }
        if UIStrings.rtl, view is TopOriginView, !mirroredViews.contains(ObjectIdentifier(view)) {
            for child in view.subviews { child.frame.origin.x = view.bounds.width - child.frame.maxX }
            mirroredViews.insert(ObjectIdentifier(view))
        }
        for child in view.subviews { mirrorAndAlign(child) }
    }
    private func button(_ title: String, x: CGFloat, y: CGFloat, width: CGFloat, in view: NSView, callback: @escaping () -> Void) {
        let control = NSButton(title: L(title), target: self, action: #selector(invoke(_:)))
        control.frame = NSRect(x: x, y: y, width: width, height: 30); control.bezelStyle = .rounded
        callbacks[ObjectIdentifier(control)] = callback; view.addSubview(control)
    }
    private func addLanguageTab() {
        let view = TopOriginView(frame: NSRect(x: 0, y: 0, width: 750, height: 470))
        view.addSubview(label("Язык интерфейса", y: 24))
        let popup = NSPopUpButton(frame: NSRect(x: 12, y: 70, width: 440, height: 32))
        for entry in UIStrings.languages {
            popup.addItem(withTitle: entry.1); popup.lastItem?.representedObject = entry.0
            if entry.0 == UIStrings.preference { popup.select(popup.lastItem) }
        }
        popup.target = self; popup.action = #selector(invoke(_:))
        popup.setAccessibilityLabel(L("Язык интерфейса"))
        callbacks[ObjectIdentifier(popup)] = { [weak self, weak popup] in
            guard let self, let code = popup?.selectedItem?.representedObject as? String else { return }
            UIStrings.preference = code
            DiagnosticLog.shared.record("language.changed", fields: ["language": code])
            self.onLanguageChange?()
            self.show(subscription: self.savedSubscription, servers: self.savedServers)
            self.tabs.selectTabViewItem(withIdentifier: "Язык")
        }
        view.addSubview(popup)
        view.addSubview(label("Язык меняется сразу. Язык Happ на эту настройку не влияет.", y: 130))
        addTab("Язык", view)
    }
    private func addDiagnosticsTab() {
        let view = TopOriginView(frame: NSRect(x: 0, y: 0, width: 750, height: 470))
        let permission = label("Доступ к управлению: \(L(AXIsProcessTrusted() ? "разрешён" : "не выдан"))", y: 4, width: 470)
        permissionLabel = permission; view.addSubview(permission)
        let service = label("", x: 485, y: 4, width: 240); serviceLabel = service; view.addSubview(service)
        view.addSubview(label("Начните с подключения в Happ. Затем разрешите управление и выполните проверку из меню HM.", y: 37))
        button("Открыть Happ", x: 12, y: 80, width: 180, in: view) { [weak self] in self?.onOpenHapp?() }
        button("Разрешить управление Happ…", x: 200, y: 80, width: 280, in: view) { [weak self] in self?.onRequestControl?() }
        view.addSubview(checkbox("Только ошибки", checked: errorsOnly, x: 490, y: 80, width: 230) { [weak self] value in self?.errorsOnly = value; self?.refreshDiagnostics() })
        let scroller = NSScrollView(frame: NSRect(x: 12, y: 120, width: 720, height: 232))
        scroller.hasVerticalScroller = true; scroller.hasHorizontalScroller = false
        let text = NSTextView(frame: scroller.bounds); text.isEditable = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular); text.isVerticallyResizable = true
        text.autoresizingMask = [.width]; scroller.documentView = text; view.addSubview(scroller); diagnosticText = text
        button("Обновить", x: 12, y: 360, width: 130, in: view) { [weak self] in self?.refreshDiagnostics() }
        button("Скопировать ошибку", x: 150, y: 360, width: 220, in: view) {
            let error = DiagnosticLog.shared.report(errorsOnly: true).split(separator: "\n").last.map(String.init) ?? L("Журнал пуст")
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(error, forType: .string)
        }
        button("Экспорт…", x: 380, y: 360, width: 160, in: view) { [weak self] in self?.previewExport() }
        button("Очистить…", x: 550, y: 360, width: 180, in: view) { [weak self] in
            let alert = NSAlert(); alert.messageText = L("Удалить локальные логи?")
            alert.addButton(withTitle: L("Удалить")); alert.addButton(withTitle: L("Отмена"))
            if alert.runModal() == .alertFirstButtonReturn {
                do { try DiagnosticLog.shared.clear() } catch { self?.showDiagnosticError() }
                self?.refreshDiagnostics()
            }
        }
        let note = label("Логи хранятся локально до 24 часов, максимум 20 МБ. После сна или закрытия очистка выполняется при следующем запуске. Экспорт отправляется только вручную.", y: 404)
        note.frame.size.height = 64; view.addSubview(note)
        addTab("Диагностика", view); refreshDiagnostics()
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            guard let self, self.tabs.selectedTabViewItem?.identifier as? String == "Диагностика" else { return }
            self.refreshDiagnostics()
        }
    }
    private func refreshDiagnostics() {
        permissionLabel?.stringValue = L("Доступ к управлению: \(L(AXIsProcessTrusted() ? "разрешён" : "не выдан"))")
        let status = ["Connected": "подключено", "Disconnected": "отключено", "Connecting": "подключение", "Disconnecting": "отключение"][connectionStatus?() ?? ""] ?? "неизвестно"
        serviceLabel?.stringValue = L("Служба Happ: \(L(status))")
        let report = DiagnosticLog.shared.report(errorsOnly: errorsOnly)
        diagnosticText?.string = DiagnosticLog.shared.unavailable ? L("Запись журнала недоступна. Проверьте свободное место и права доступа.") : (report.isEmpty ? L("Журнал пуст") : report)
    }
    private func showDiagnosticError() {
        let alert = NSAlert(); alert.messageText = L("Не удалось сохранить отчёт"); alert.runModal()
    }
    private func previewExport() {
        let report = DiagnosticLog.shared.report()
        let alert = NSAlert(); alert.messageText = L("Отчёт показан ниже. Проверьте его перед сохранением.")
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 600, height: 300)); scroll.hasVerticalScroller = true
        let text = NSTextView(frame: scroll.bounds); text.isEditable = false; text.isSelectable = true
        text.font = .monospacedSystemFont(ofSize: 11, weight: .regular); text.string = report.isEmpty ? L("Журнал пуст") : report
        scroll.documentView = text; alert.accessoryView = scroll
        alert.addButton(withTitle: L("Сохранить отчёт")); alert.addButton(withTitle: L("Отмена"))
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Happ-Monitor-diagnostics.jsonl"
        if panel.runModal() == .OK, let url = panel.url {
            do { try report.write(to: url, atomically: true, encoding: .utf8) } catch { showDiagnosticError() }
        }
    }
    func showDiagnostics(subscription: String?, servers: [ServerCandidate]) {
        show(subscription: subscription, servers: servers); tabs.selectTabViewItem(withIdentifier: "Диагностика")
    }

}
