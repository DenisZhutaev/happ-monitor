import AppKit
import ApplicationServices
import ServiceManagement
import UserNotifications

if CommandLine.arguments.contains("--self-test") { runSelfTests(); exit(0) }
if CommandLine.arguments.contains("--status") {
    let status = happStatus(); print("Happ: \(status.status); tunnel: \(status.interface ?? "unavailable")"); exit(0)
}
if CommandLine.arguments.contains("--probe") {
    let result = TunnelProbe.check(happStatus())
    print("\(result.message); verified=\(result.verified); healthy=\(result.healthy); ms=\(result.milliseconds ?? -1)")
    exit(result.healthy ? 0 : 1)
}
if CommandLine.arguments.contains("--control-check") {
    do {
        let control = HappControl()
        print("\(try control.subscriptionName()); selected: \(try control.selectedServerName() ?? "unknown"); servers: \(try control.servers().count)")
        exit(0)
    } catch { print(error.localizedDescription); exit(1) }
}

final class MonitorNotifications {
    private var lastFailure: Date = .distantPast
    func request(store: MonitorStore, explain: Bool = false, completion: (() -> Void)? = nil) {
        let center = UNUserNotificationCenter.current()
        center.getNotificationSettings { settings in
            if settings.authorizationStatus == .denied {
                DispatchQueue.main.async {
                    store.preferences.notifications = false; store.save()
                    if explain {
                        let alert = NSAlert(); alert.messageText = "Уведомления отключены в macOS"
                        alert.informativeText = "Разрешите их в разделе «Системные настройки → Уведомления → Happ Monitor», затем включите эту настройку снова."
                        alert.runModal()
                    }
                    completion?()
                }
                return
            }
            guard settings.authorizationStatus == .notDetermined else { DispatchQueue.main.async { completion?() }; return }
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                DispatchQueue.main.async {
                    store.preferences.notificationPermissionRequested = true
                    if !granted { store.preferences.notifications = false; store.log("Уведомления macOS не разрешены") }
                    store.save()
                    completion?()
                }
            }
        }
    }
    func send(_ message: String, success: Bool, store: MonitorStore) {
        guard store.preferences.notifications, !success || store.preferences.notifySuccess else { return }
        if !success {
            guard Date().timeIntervalSince(lastFailure) > 900 else { return }
            lastFailure = Date()
        }
        let content = UNMutableNotificationContent()
        content.title = success ? "VPN восстановлен" : "Не удалось восстановить VPN"
        content.body = message
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: success ? "vpn-restored" : "vpn-failure", content: content, trigger: nil))
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let store = MonitorStore.shared
    private let control = HappControl()
    private let notifications = MonitorNotifications()
    private lazy var settings = SettingsWindow(store: store)
    private var item: NSStatusItem!
    private let menu = NSMenu()
    private var timer: Timer?
    private var vpn = VPNInfo(status: "Unknown", interface: nil, address: nil)
    private var health: ProbeResult?
    private var healthAt: Date?
    private var probeFailures = 0
    private var probing = false
    private var generation = 0
    private var fetchingStatus = false
    private var lastStatusPoll = Date.distantPast
    private var lastSnapshot = Date.distantPast
    private var lastProbe = Date.distantPast
    private var lastCheck = Date()
    private var connectedSince: Date?
    private var downSince: Date?
    private var subscription: String?
    private var selected: String?
    private var serverSnapshot: [ServerCandidate] = []
    private var snapshotFresh = false
    private var message = "Проверка соединения…"
    private var pauseDisconnectError: String?
    private var nextRecovery = Date.distantPast
    private enum Phase { case idle, preparing, measuring, connecting }
    private var phase = Phase.idle
    private var recovering: Bool { phase != .idle }
    private var recoveryStarted = Date.distantPast
    private var attemptStarted = Date()
    private var measurementStarted = Date()
    private var sawMeasurement = false
    private var baseline: [String] = []
    private var settled: [String] = []
    private var settledTicks = 0
    private var samples: [[ServerCandidate]] = []
    private var queue: [ServerCandidate] = []
    private var candidate: ServerCandidate?
    private var connectedTicks = 0
    private var attemptedConnect = false
    private var manualOptimization = false
    private var wasHealthyBeforeRecovery = false
    private var originalServer: String?
    private var recoverySubscription: String?
    private var candidateProbeStarted = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = menu; menu.delegate = self
        settings.onChange = { [weak self] in self?.preferencesChanged() }
        settings.onRequestNotifications = { [weak self] in
            guard let self else { return }
            self.notifications.request(store: self.store, explain: true) { [weak self] in self?.settings.refreshNotificationControls() }
        }
        settings.onPause = { [weak self] minutes in let item = NSMenuItem(); item.tag = minutes; self?.pauseVPN(item) }
        settings.onResume = { [weak self] in self?.resumeVPN() }
        if store.preferences.notifications { notifications.request(store: store) }
        if CommandLine.arguments.contains("--request-accessibility") { requestAccessibility() }
        store.log("Happ Monitor запущен")
        tick()
        if CommandLine.arguments.contains("--show-settings") { openSettings() }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.tick() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(woke), name: NSWorkspace.didWakeNotification, object: nil)
    }
    @objc private func woke() {
        generation += 1; health = nil; healthAt = nil; probeFailures = 0
        lastProbe = .distantPast; lastStatusPoll = .distantPast
        if recovering { cancelRecovery("Проверка после пробуждения") }
        store.log("Mac вышел из сна; состояние проверяется заново")
    }
    private func tick() {
        if let until = store.preferences.pauseUntil, Date() >= until {
            store.preferences.pauseUntil = nil; store.save()
            store.log("Пауза завершена; автовосстановление возобновлено")
            nextRecovery = .distantPast
        }
        if Date().timeIntervalSince(lastStatusPoll) >= 2 && !fetchingStatus {
            fetchingStatus = true; lastStatusPoll = Date()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let value = happStatus()
                DispatchQueue.main.async { [weak self] in self?.applyStatus(value) }
            }
        }
        if Date().timeIntervalSince(lastSnapshot) >= 5 && !recovering { readSnapshot() }
        if recovering { stepRecovery() }
        else if vpn.connected && !probing && Date().timeIntervalSince(lastProbe) >= 20 { startProbe(forCandidate: false) }
        if !recovering && store.preferences.automatic && !store.preferences.paused() && Date() >= nextRecovery {
            if vpn.status == "Disconnected", let downSince, Date().timeIntervalSince(downSince) >= 8 {
                beginRecovery(manual: false)
            } else if vpn.connected && probeFailures >= 2 {
                beginRecovery(manual: false)
            }
        }
        renderIcon(); rebuildMenu()
        if CommandLine.arguments.contains("--verify-state") { writeState() }
    }
    private func applyStatus(_ value: VPNInfo) {
        fetchingStatus = false
        let changed = value.status != vpn.status || value.interface != vpn.interface
        if changed {
            generation += 1; health = nil; healthAt = nil; lastProbe = .distantPast; probeFailures = 0
            if value.connected {
                connectedSince = Date(); downSince = nil
                store.log("macOS: VPN подключён; проверяется прохождение трафика")
            } else {
                connectedSince = nil
                if value.status == "Disconnected" { downSince = Date(); store.log("macOS: VPN отключён") }
                else { downSince = nil }
            }
        }
        vpn = value; lastCheck = Date()
        if CommandLine.arguments.contains("--verify-recovery"), phase == .idle, recoveryStarted == Date.distantPast {
            beginRecovery(manual: true)
        }
    }
    private func readSnapshot() {
        lastSnapshot = Date()
        do {
            let name = try control.subscriptionName()
            let selectedName = try control.selectedServerName()
            let servers = try control.servers()
            if subscription != name { store.log("Выбрана подписка: \(name)") }
            if selected != selectedName {
                generation += 1; health = nil; healthAt = nil; probeFailures = 0; lastProbe = .distantPast
                if let selectedName { store.log("Выбран сервер: \(selectedName)") }
            }
            subscription = name; selected = selectedName; serverSnapshot = servers; snapshotFresh = true
        } catch { snapshotFresh = false }
    }
    private func startProbe(forCandidate: Bool) {
        guard vpn.connected && !probing else { return }
        probing = true; lastProbe = Date()
        let epoch = generation, snapshot = vpn
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = TunnelProbe.check(snapshot)
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.probing = false
                guard self.generation == epoch, self.vpn.connected, self.vpn.interface == snapshot.interface else {
                    if forCandidate { self.candidateProbeStarted = false }
                    return
                }
                let previous = self.health?.healthy
                self.health = result; self.healthAt = Date()
                if self.message == "Проверка соединения…" {
                    self.message = result.healthy ? "Автовосстановление готово" : result.message
                }
                if result.healthy { self.probeFailures = 0 }
                else if result.verified { self.probeFailures += 1 }
                if previous != result.healthy { self.store.log(result.message) }
                if forCandidate && self.phase == .connecting && !self.store.preferences.paused() {
                    if result.healthy, let server = self.candidate {
                        self.finishRecovery("Подключён: \(server.name) · HTTPS \(result.milliseconds ?? 0) мс", success: true)
                    } else if result.verified { self.failCandidate("Трафик через туннель не проходит") }
                    else { self.candidateProbeStarted = false }
                }
                self.renderIcon(); self.rebuildMenu()
            }
        }
    }
    private func beginRecovery(manual: Bool) {
        guard !recovering && !store.preferences.paused() else { return }
        phase = .preparing; generation += 1; recoveryStarted = Date()
        manualOptimization = manual
        wasHealthyBeforeRecovery = health?.healthy == true && healthAt.map { Date().timeIntervalSince($0) < 45 } == true
        originalServer = selected
        samples = []; queue = []; candidate = nil; recoverySubscription = nil
        message = "Подготовка списка серверов…"
        store.log(manual ? "Запущен ручной подбор сервера" : "Запущено автовосстановление")
        if !AXIsProcessTrusted() { finishRecovery("Нужен доступ для управления Happ", success: false); return }
        do { _ = try control.subscriptionName() }
        catch {
            // Only reveal Happ when recovery actually needs its server list.
            NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Happ.app"), configuration: NSWorkspace.OpenConfiguration())
            try? control.revealMainWindow()
        }
    }
    private func startMeasurement() throws {
        phase = .measuring; measurementStarted = Date(); settledTicks = 0
        baseline = try control.candidates().map { "\($0.name):\($0.ping)" }; settled = []
        message = "Замер пинга \(samples.count + 1) из 3…"
        try control.measure(); sawMeasurement = try control.testing()
    }
    private func stepRecovery() {
        guard store.preferences.automatic || manualOptimization else { cancelRecovery("Автовосстановление выключено"); return }
        guard !store.preferences.paused() else { cancelRecovery("Автовосстановление приостановлено"); return }
        if Date().timeIntervalSince(recoveryStarted) > 240 { finishRecovery("Истекло время восстановления", success: false); return }
        do {
            switch phase {
            case .idle: break
            case .preparing:
                do {
                    try control.beginRecovery()
                    recoverySubscription = try control.subscriptionName(); subscription = recoverySubscription
                    selected = try control.selectedServerName(); serverSnapshot = try control.servers(); snapshotFresh = true
                    try startMeasurement()
                } catch {
                    if Date().timeIntervalSince(recoveryStarted) > 15 { throw ControlError.message("Нет доступа к списку серверов. Откройте главное окно Happ на текущем рабочем столе") }
                }
            case .measuring:
                let testing = try control.testing(); if testing { sawMeasurement = true }
                let results = try control.candidates()
                let signature = results.map { "\($0.name):\($0.ping)" }
                settledTicks = signature == settled ? settledTicks + 1 : 0; settled = signature
                // Settled results are also valid after a fast run that ended between ticks.
                let completed = !testing && ((sawMeasurement && settledTicks >= 1) || (signature != baseline && settledTicks >= 3))
                if completed {
                    samples.append(results)
                    if samples.count < 3 { try startMeasurement() }
                    else { try chooseMeasuredServer() }
                } else if Date().timeIntervalSince(measurementStarted) > 60 {
                    throw ControlError.message("Не удалось подтвердить завершение свежего замера пинга")
                }
            case .connecting:
                if let name = try control.selectedServerName(), name != candidate?.name { throw ControlError.message("Выбор сервера изменён в Happ; восстановление остановлено") }
                if let server = candidate, let sub = recoverySubscription,
                   !serverAllowed(server.name, subscription: sub, preferences: store.preferences) {
                    throw ControlError.message("Сервер больше не разрешён настройками выбора")
                }
                connectedTicks = vpn.connected ? connectedTicks + 1 : 0
                let elapsed = Date().timeIntervalSince(attemptStarted)
                if connectedTicks >= 3 && elapsed >= 3 && !candidateProbeStarted && !probing {
                    candidateProbeStarted = true; startProbe(forCandidate: true)
                }
                if elapsed >= 6 && vpn.status == "Disconnected" && !attemptedConnect {
                    attemptedConnect = true
                    DispatchQueue.global(qos: .utility).async { _ = runCommand("/usr/sbin/scutil", ["--nc", "start", "Happ"], timeout: 8) }
                }
                if elapsed > 40 { failCandidate("Подключение или HTTPS-проверка не подтверждены") }
            }
        } catch { finishRecovery(error.localizedDescription, success: false) }
    }
    private func chooseMeasuredServer() throws {
        guard let sub = recoverySubscription else { throw ControlError.message("Подписка не определена") }
        queue = rankedServers(samples: samples, subscription: sub, preferences: store.preferences)
        guard let best = queue.first else { throw ControlError.message("Нет разрешённых стабильных серверов. Проверьте исключения, закрепление и временные блокировки") }
        if manualOptimization && wasHealthyBeforeRecovery, let originalServer,
           let current = queue.first(where: { $0.name == originalServer }) {
            if keepWorkingServer(current: current, best: best, pinned: store.preferences.pinned[sub]) {
                candidate = current
                finishRecovery("Сохранён работающий сервер: \(originalServer); значимого выигрыша по задержке нет", success: true)
                return
            }
        }
        try selectNextServer()
    }
    private func selectNextServer() throws {
        guard let sub = recoverySubscription else { throw ControlError.message("Подписка не определена") }
        while !queue.isEmpty {
            let server = queue.removeFirst()
            if !serverAllowed(server.name, subscription: sub, preferences: store.preferences) { continue }
            candidate = server; generation += 1; health = nil; healthAt = nil; probeFailures = 0
            phase = .connecting; attemptStarted = Date(); connectedTicks = 0; candidateProbeStarted = false; attemptedConnect = false
            message = "Подключение: \(server.name) · медиана \(server.ping) мс"
            store.log(message)
            try control.select(server); selected = server.name
            return
        }
        throw ControlError.message("Разрешённые серверы проверены, восстановить VPN не удалось")
    }
    private func failCandidate(_ reason: String) {
        generation += 1
        if let server = candidate, let sub = recoverySubscription {
            store.outcome(subscription: sub, server: server.name, success: false)
            store.log("\(server.name): \(reason). Исключён на 10 минут")
        }
        do { try selectNextServer() } catch { finishRecovery(error.localizedDescription, success: false) }
    }
    private func cancelRecovery(_ reason: String) {
        generation += 1; control.endRecovery(); phase = .idle; candidate = nil
        nextRecovery = Date().addingTimeInterval(15); message = reason; store.log(reason)
    }
    private func finishRecovery(_ result: String, success: Bool) {
        if success, let server = candidate, let sub = recoverySubscription { store.outcome(subscription: sub, server: server.name, success: true) }
        control.endRecovery(); phase = .idle; message = result
        nextRecovery = Date().addingTimeInterval(success ? 60 : 120)
        if !success { generation += 1 }
        store.log(result); notifications.send(result, success: success, store: store)
        if CommandLine.arguments.contains("--verify-recovery") { try? result.write(toFile: "/private/tmp/happ-monitor-result-v2.txt", atomically: true, encoding: .utf8) }
    }
    private func preferencesChanged() {
        if recovering { cancelRecovery("Настройки изменены; подбор остановлен") }
        nextRecovery = Date().addingTimeInterval(8)
        store.log("Настройки выбора обновлены"); rebuildMenu()
    }
    private func renderIcon() {
        let healthy = vpn.connected && health?.healthy == true && healthAt.map { Date().timeIntervalSince($0) < 45 } == true
        let color: NSColor = healthy ? .systemGreen : (vpn.connected || vpn.status == "Connecting" ? .systemOrange : .systemRed)
        let appearance = item.button?.effectiveAppearance
        let image = NSImage(size: NSSize(width: 29, height: 20), flipped: false) { _ in
            let dark = appearance?.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            (dark ? NSColor.white : NSColor.black).setStroke()
            let path = NSBezierPath(); path.lineWidth = 3.6; path.lineCapStyle = .round; path.lineJoinStyle = .round
            path.move(to: NSPoint(x: 3, y: 3)); path.line(to: NSPoint(x: 3, y: 17))
            path.move(to: NSPoint(x: 3, y: 10)); path.line(to: NSPoint(x: 12, y: 10))
            path.move(to: NSPoint(x: 12, y: 3)); path.line(to: NSPoint(x: 12, y: 17)); path.line(to: NSPoint(x: 19, y: 9))
            path.line(to: NSPoint(x: 26, y: 17)); path.line(to: NSPoint(x: 26, y: 3)); path.stroke()
            color.setStroke(); let accent = NSBezierPath(); accent.lineWidth = 3.6; accent.lineCapStyle = .round
            accent.move(to: NSPoint(x: 12, y: 5)); accent.line(to: NSPoint(x: 12, y: 15)); accent.stroke(); return true
        }
        image.isTemplate = false
        image.accessibilityDescription = summary()
        item.button?.image = image; item.button?.title = ""; item.button?.contentTintColor = nil
        item.button?.toolTip = summary()
    }
    private func summary() -> String {
        if vpn.connected {
            let fresh = healthAt.map { Date().timeIntervalSince($0) < 45 } == true
            if health?.healthy == true && fresh { return "Happ: трафик через туннель проходит" }
            if health?.verified == true && health?.healthy == false && fresh { return "Happ: контрольные запросы через VPN не проходят" }
            return "Happ: VPN подключён, трафик пока не подтверждён"
        }
        if vpn.status == "Disconnected" { return "Happ: VPN отключён" }
        if vpn.status == "Connecting" { return "Happ: подключение…" }
        if vpn.status == "Disconnecting" { return "Happ: отключение…" }
        return "Happ: статус неизвестен"
    }
    private var menuTracking = false
    func menuWillOpen(_ menu: NSMenu) { readSnapshot(); rebuildMenu(); menuTracking = true }
    func menuDidClose(_ menu: NSMenu) { menuTracking = false }
    private func label(_ text: String) {
        menu.addItem(informationRow(text))
    }
    private func informationRow(_ text: String) -> NSMenuItem {
        let row = NSMenuItem(); let field = NSTextField(labelWithString: text)
        field.font = .menuFont(ofSize: 13); field.textColor = .labelColor
        let size = field.fittingSize
        let view = NSView(frame: NSRect(x: 0, y: 0, width: min(700, max(330, size.width + 40)), height: 25))
        field.frame = NSRect(x: 20, y: 3, width: min(660, size.width), height: 19)
        field.lineBreakMode = .byTruncatingTail; view.addSubview(field); row.view = view
        return row
    }
    @discardableResult private func action(_ title: String, _ selector: Selector, tag: Int = 0, parent: NSMenu? = nil) -> NSMenuItem {
        let row = NSMenuItem(title: title, action: selector, keyEquivalent: ""); row.target = self; row.tag = tag; (parent ?? menu).addItem(row); return row
    }
    private func rebuildMenu() {
        guard !menuTracking else { return }
        menu.removeAllItems()
        label(summary())
        label("Подписка: \(subscription ?? "не определена")\(snapshotFresh || subscription == nil ? "" : " · последние данные")")
        label("Сервер: \(selected ?? "не определён")")
        if let latency = health?.milliseconds { label("HTTPS через туннель: \(latency) мс") }
        if let at = healthAt { label("Последняя проверка трафика: \(time(at))") }
        if store.preferences.paused() {
            label(store.preferences.manualPause ? "Пауза до ручного включения" : "Пауза до \(time(store.preferences.pauseUntil!))")
            if let pauseDisconnectError { label(pauseDisconnectError) }
        } else { label(message) }
        if let connectedSince {
            let seconds = Int(Date().timeIntervalSince(connectedSince)); label(String(format: "Соединение наблюдается: %02d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60))
        }
        menu.addItem(.separator())
        let automatic = action("Автовосстановление · \(subscription ?? "подписка не определена")", #selector(toggleAutomatic))
        automatic.state = store.preferences.automatic ? .on : .off
        let restore = action("Проверить и подобрать сервер", #selector(recoverNow)); restore.isEnabled = !recovering && !store.preferences.paused()
        action("Проверить трафик сейчас", #selector(checkNow)).isEnabled = vpn.connected && !probing
        let pause = NSMenuItem(title: "Отключить VPN на время", action: nil, keyEquivalent: "")
        let sub = NSMenu(); pause.submenu = sub
        action("На 15 минут", #selector(pauseVPN(_:)), tag: 15, parent: sub)
        action("На час", #selector(pauseVPN(_:)), tag: 60, parent: sub)
        action("До ручного включения", #selector(pauseVPN(_:)), tag: -1, parent: sub)
        menu.addItem(pause)
        if store.preferences.paused() { action("Возобновить VPN", #selector(resumeVPN)) }
        menu.addItem(.separator())
        action("Настройки стран и серверов…", #selector(openSettings))
        action("История соединений…", #selector(openHistory))
        let recent = NSMenuItem(title: "Последние события", action: nil, keyEquivalent: "")
        let recentMenu = NSMenu()
        for event in store.history.suffix(6).reversed() { recentMenu.addItem(informationRow("\(time(event.date)) · \(event.message.prefix(110))")) }
        if store.history.isEmpty { recentMenu.addItem(informationRow("Событий пока нет")) }
        recent.submenu = recentMenu; menu.addItem(recent)
        action("Открыть Happ", #selector(openHapp))
        if !AXIsProcessTrusted() { action("Разрешить управление Happ…", #selector(requestAccessibility)) }
        let login = action("Запускать при входе", #selector(toggleLogin)); login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(.separator()); action("Завершить Happ Monitor", #selector(quit))
    }
    private func time(_ date: Date) -> String { let formatter = DateFormatter(); formatter.dateFormat = "HH:mm:ss"; return formatter.string(from: date) }
    @objc private func checkNow() { if !probing && vpn.connected { startProbe(forCandidate: false) } }
    @objc private func recoverNow() { beginRecovery(manual: true) }
    @objc private func toggleAutomatic() { store.preferences.automatic.toggle(); store.save(); if recovering && !store.preferences.automatic { cancelRecovery("Автовосстановление выключено") }; rebuildMenu() }
    @objc private func pauseVPN(_ sender: NSMenuItem) {
        cancelRecovery("VPN отключён вручную")
        pauseDisconnectError = nil
        store.preferences.manualPause = sender.tag == -1
        store.preferences.pauseUntil = sender.tag > 0 ? Date().addingTimeInterval(Double(sender.tag * 60)) : nil
        store.save(); generation += 1; health = nil
        store.log(sender.tag > 0 ? "Пауза VPN на \(sender.tag) минут" : "Пауза VPN до ручного включения")
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let result = runCommand("/usr/sbin/scutil", ["--nc", "stop", "Happ"], timeout: 8)
            if result.code != 0 { DispatchQueue.main.async { [weak self] in
                self?.pauseDisconnectError = "Не удалось отправить команду отключения Happ"
                self?.store.log("Команда ручного отключения Happ не выполнена")
            } }
        }
        rebuildMenu()
    }
    @objc private func resumeVPN() {
        store.preferences.manualPause = false; store.preferences.pauseUntil = nil; store.preferences.automatic = true; store.save()
        pauseDisconnectError = nil
        nextRecovery = .distantPast; store.log("VPN возобновлён пользователем")
        if !vpn.connected { beginRecovery(manual: true) }; rebuildMenu()
    }
    @objc private func openSettings() { readSnapshot(); settings.show(subscription: subscription, servers: serverSnapshot) }
    @objc private func openHistory() { settings.show(subscription: subscription, servers: serverSnapshot, history: true) }
    @objc private func openHapp() { NSWorkspace.shared.openApplication(at: URL(fileURLWithPath: "/Applications/Happ.app"), configuration: NSWorkspace.OpenConfiguration()); try? control.revealMainWindow() }
    @objc private func requestAccessibility() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary); NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!) }
    @objc private func toggleLogin() {
        do { if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() } else { try SMAppService.mainApp.register() } }
        catch { let alert = NSAlert(); alert.messageText = "Не удалось изменить автозапуск"; alert.informativeText = error.localizedDescription; alert.runModal() }
    }
    private func writeState() {
        let state: [String: Any] = ["vpn": vpn.status, "interface": vpn.interface ?? "", "healthy": health?.healthy ?? false,
            "verified": health?.verified ?? false, "subscription": subscription ?? "", "server": selected ?? "", "message": message,
            "paused": store.preferences.paused(), "recovering": recovering, "historyCount": store.history.count]
        if let data = try? JSONSerialization.data(withJSONObject: state, options: [.prettyPrinted, .sortedKeys]) { try? data.write(to: URL(fileURLWithPath: "/private/tmp/happ-monitor-state-v2.json"), options: .atomic) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
