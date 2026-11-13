import AppKit
import ApplicationServices

struct ServerCandidate {
    let name: String
    let ping: Int
}
func isRussianServer(_ name: String) -> Bool {
    if name.contains("🇷🇺") { return true }
    let pattern = #"(?i)(?<![\p{L}\p{N}])(россия|российск[\p{L}]*|russia|russian|рф|ru|rus|москва|moscow|moskva|санкт[ -]?петербург|saint[ -]?petersburg|st[ .-]+petersburg|спб)(?![\p{L}\p{N}])"#
    return name.range(of: pattern, options: .regularExpression) != nil
}
func eligibleCandidates(_ servers: [ServerCandidate]) -> [ServerCandidate] {
    servers.sorted { $0.ping < $1.ping }
}
func subscriptionDisplayName(_ description: String) -> String {
    String(description.dropFirst("subscription:".count)).trimmingCharacters(in: .whitespacesAndNewlines)
}
func selectedServerDescription(_ description: String) -> Bool {
    description.components(separatedBy: ",").contains { $0.trimmingCharacters(in: .whitespaces) == "selected" }
}
func parseCandidate(_ description: String) -> ServerCandidate? {
    let parts = description.components(separatedBy: ",")
    guard parts.count >= 3,
          let part = parts.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("ping ") }),
          let ping = Int(part.trimmingCharacters(in: .whitespaces).dropFirst(5)), ping > 0 else { return nil }
    return ServerCandidate(name: parts[0].trimmingCharacters(in: .whitespaces), ping: ping)
}
enum ControlError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
final class HappControl {
    private var lastSubscriptionName: String?
    private var pinnedSubscriptionName: String?
    private var cachedSubscriptions: [AXUIElement] = []

    func name(_ element: AXUIElement) -> String {
        subscriptionDisplayName(text(element))
    }
    func isSelectedServer(_ element: AXUIElement) -> Bool {
        selectedServerDescription(text(element))
    }
    func value(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
        var value: CFTypeRef?
        AXUIElementCopyAttributeValue(element, key as CFString, &value)
        return value
    }
    func text(_ element: AXUIElement) -> String {
        (value(element, kAXDescriptionAttribute) as? String) ?? (value(element, kAXTitleAttribute) as? String) ?? ""
    }
    func children(_ element: AXUIElement) -> [AXUIElement] { value(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] }
    func all(_ element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 20 else { return [] }
        return [element] + children(element).flatMap { all($0, depth: depth + 1) }
    }
    func root() throws -> AXUIElement {
        guard AXIsProcessTrusted() else { throw ControlError.message("Нужен Универсальный доступ для Happ Monitor") }
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: "su.ffg.happ").first else { throw ControlError.message("Откройте Happ для автоматического выбора") }
        let root = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(root, 3)
        AXUIElementSetAttributeValue(root, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(root, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return root
    }
    func subscription() throws -> AXUIElement {
        let visible = all(try root()).filter { text($0).hasPrefix("subscription:") }
        if !visible.isEmpty { cachedSubscriptions = visible }
        let subscriptions = cachedSubscriptions.filter { text($0).hasPrefix("subscription:") }
        let selected = subscriptions.filter { all($0).contains(where: isSelectedServer) }
        if let pinnedName = pinnedSubscriptionName {
            let matches = subscriptions.filter { name($0) == pinnedName }
            guard matches.count == 1 else { throw ControlError.message("Подписка больше недоступна в Happ") }
            if selected.count == 1 && name(selected[0]) != pinnedName { throw ControlError.message("Подписка изменена в Happ; автовыбор остановлен") }
            return matches[0]
        }
        let target: AXUIElement
        if selected.count == 1 { target = selected[0] }
        else if selected.isEmpty, let cached = lastSubscriptionName,
                subscriptions.filter({ name($0) == cached }).count == 1 {
            target = subscriptions.first { name($0) == cached }!
        } else if selected.isEmpty && subscriptions.count == 1 { target = subscriptions[0] }
        else { throw ControlError.message("Выберите сервер нужной подписки в Happ") }
        lastSubscriptionName = name(target)
        return target
    }
    func subscriptionName() throws -> String { name(try subscription()) }
    func revealMainWindow() throws {
        let app = try root()
        if let windowMenu = all(app).first(where: { (value($0, kAXIdentifierAttribute) as? String) == "com.apple.menu.window" }) {
            try perform(windowMenu, named: kAXPressAction)
        }
        guard let windowItem = all(app).first(where: { (value($0, kAXIdentifierAttribute) as? String) == "makeKeyAndOrderFront:" && (value($0, kAXTitleAttribute) as? String) == "Happ" }) else {
            throw ControlError.message("Откройте главное окно Happ для определения подписки")
        }
        try perform(windowItem, named: kAXPressAction)
    }
    func beginRecovery() throws { pinnedSubscriptionName = name(try subscription()) }
    func endRecovery() { pinnedSubscriptionName = nil }
    func perform(_ element: AXUIElement, named title: String) throws {
        var names: CFArray?
        guard AXUIElementCopyActionNames(element, &names) == .success else { throw ControlError.message("Команды Happ недоступны") }
        for name in names as? [String] ?? [] {
            var description: CFString?
            AXUIElementCopyActionDescription(element, name as CFString, &description)
            if name == title || (description as String?) == title {
                guard AXUIElementPerformAction(element, name as CFString) == .success else { throw ControlError.message("Happ не выполнил: \(title)") }
                return
            }
        }
        throw ControlError.message("В Happ нет команды: \(title)")
    }
    func measure() throws { try perform(try subscription(), named: "Измерить пинг всех серверов") }
    func candidates() throws -> [ServerCandidate] {
        eligibleCandidates(all(try subscription()).compactMap { parseCandidate(text($0)) })
    }
    func selectedServerName() throws -> String? {
        all(try subscription()).first(where: isSelectedServer).map { text($0).components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces) }
    }
    func servers() throws -> [ServerCandidate] {
        var names = Set<String>()
        return all(try subscription()).compactMap { element in
            var actions: CFArray?
            guard AXUIElementCopyActionNames(element, &actions) == .success else { return nil }
            let selectable = (actions as? [String] ?? []).contains { action in
                var description: CFString?
                AXUIElementCopyActionDescription(element, action as CFString, &description)
                return description as String? == "Выбрать сервер"
            }
            guard selectable else { return nil }
            let description = text(element)
            let name = description.components(separatedBy: ",")[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, names.insert(name).inserted else { return nil }
            return parseCandidate(description) ?? ServerCandidate(name: name, ping: -1)
        }
    }
    func testing() throws -> Bool { all(try root()).contains { text($0) == "Тест пинга" } }
    func select(_ candidate: ServerCandidate) throws {
        guard serverAllowed(candidate.name, subscription: try subscriptionName(), preferences: MonitorStore.shared.preferences) else { throw ControlError.message("Сервер исключён настройками выбора") }
        let matches = all(try subscription()).filter { parseCandidate(text($0))?.name == candidate.name }
        guard matches.count == 1 else { throw ControlError.message("Сервер изменился, требуется новый замер") }
        try perform(matches[0], named: "Выбрать сервер")
    }
    func connect() throws {
        if happStatus().connected { return }
        let matches = all(try root()).filter { text($0) == "Подключить VPN" }
        guard let button = matches.first else { throw ControlError.message("Не найдена кнопка подключения Happ") }
        try perform(children(button).first ?? button, named: kAXPressAction)
    }
}
