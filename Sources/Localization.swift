import Foundation

/// UI localization is independent of the Russian accessibility commands used by HappControl.
enum UIStrings {
    static let languages = [("system", "Как в macOS / System"), ("ru", "Русский"), ("en", "English"), ("zh-Hans", "简体中文"), ("es", "Español"), ("fr", "Français"), ("ar", "العربية")]
    static var overrideLanguage: String?
    static var preference: String {
        get { UserDefaults.standard.string(forKey: "interfaceLanguage.v1") ?? "system" }
        set { UserDefaults.standard.set(newValue, forKey: "interfaceLanguage.v1") }
    }
    static func resolved(_ choice: String, preferred: [String] = Locale.preferredLanguages) -> String {
        if choice != "system", languages.contains(where: { $0.0 == choice }) { return choice }
        for tag in preferred {
            let base = tag.lowercased().split(separator: "-").first.map(String.init) ?? ""
            if base == "zh" { return "zh-Hans" }
            if ["ru", "en", "es", "fr", "ar"].contains(base) { return base }
        }
        return "en"
    }
    static var language: String { overrideLanguage ?? resolved(preference) }
    static var locale: Locale { Locale(identifier: language) }
    static var rtl: Bool { language == "ar" }
    static let catalog: [String: [String: String]] = {
        guard let url = Bundle.main.url(forResource: "Translations", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let result = try? JSONDecoder().decode([String: [String: String]].self, from: data) else { return [:] }
        return result
    }()
    static let templates: [(String, NSRegularExpression)] = catalog.keys.filter { $0.contains("%@") }.sorted { $0.count > $1.count }.compactMap { key in
        let pattern = "^" + key.components(separatedBy: "%@").map(NSRegularExpression.escapedPattern).joined(separator: "(.*?)") + "$"
        return (try? NSRegularExpression(pattern: pattern, options: [.dotMatchesLineSeparators])).map { (key, $0) }
    }
    static func text(_ source: String, language: String? = nil) -> String {
        let code = language ?? self.language
        if code == "ru" { return source }
        if let row = catalog[source] { return row[code] ?? row["en"] ?? source }
        for (key, regex) in templates {
            guard let match = regex.firstMatch(in: source, range: NSRange(source.startIndex..., in: source)), let row = catalog[key] else { continue }
            let translated = row[code] ?? row["en"] ?? key
            var values: [String] = []
            for i in 1..<match.numberOfRanges {
                guard let range = Range(match.range(at: i), in: source) else { values.append(""); continue }
                var value = String(source[range])
                if key == "%@: %@. Исключён на 10 минут", i == 2 { value = text(value, language: code) }
                values.append(code == "ar" ? "\u{2068}\(value)\u{2069}" : value)
            }
            // Substitute from the original template once: braces in server names are opaque data.
            let slots = try! NSRegularExpression(pattern: #"\{([0-9]+)\}"#)
            var result = translated
            for slot in slots.matches(in: translated, range: NSRange(translated.startIndex..., in: translated)).reversed() {
                guard let numberRange = Range(slot.range(at: 1), in: translated), let index = Int(translated[numberRange]), values.indices.contains(index), let range = Range(slot.range, in: result) else { continue }
                result.replaceSubrange(range, with: values[index])
            }
            return result
        }
        return source // Historic free-form messages and server names remain intact.
    }
}
func L(_ value: String) -> String { UIStrings.text(value) }
