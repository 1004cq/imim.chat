import Foundation
import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    static let preferenceKey = "app_language"
    case system
    case simplifiedChinese = "zh-Hans"
    case english = "en"

    var id: String { rawValue }

    static var current: AppLanguage {
        AppLanguage(rawValue: UserDefaults.standard.string(forKey: preferenceKey) ?? "system") ?? .system
    }

    var resolvedIdentifier: String {
        if self != .system { return rawValue }
        return Self.resolve(preferredLanguages: Locale.preferredLanguages)
    }

    static func resolve(preferredLanguages: [String]) -> String {
        preferredLanguages.first?.lowercased().hasPrefix("zh") == true ? "zh-Hans" : "en"
    }

    var locale: Locale { Locale(identifier: resolvedIdentifier) }

    var displayName: String {
        switch self {
        case .system: return AppLocalization.string("跟随系统")
        case .simplifiedChinese: return "简体中文"
        case .english: return "English"
        }
    }
}

/// Only use these lookups for app-owned interface text, never user messages,
/// nicknames, server IDs, protocol markers, or data saved in SwiftData.
enum AppLocalization {
    static func bundle(for language: AppLanguage = .current, in container: Bundle = .main) -> Bundle {
        guard let path = container.path(forResource: language.resolvedIdentifier, ofType: "lproj"),
              let bundle = Bundle(path: path) else { return .main }
        return bundle
    }

    static func string(_ key: String, language: AppLanguage = .current) -> String {
        bundle(for: language).localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func text(_ value: String.LocalizationValue) -> String {
        String(localized: value, bundle: bundle(), locale: AppLanguage.current.locale)
    }
}

/// A locale dependency makes reusable String-based controls update in place.
/// Changing language must not recreate the app root or reset chat/navigation state.
struct AppLocalizedText: View {
    @Environment(\.locale) private var locale
    let key: String

    init(_ key: String) { self.key = key }

    var body: some View {
        let language: AppLanguage = locale.identifier.hasPrefix("zh") ? .simplifiedChinese : .english
        Text(verbatim: AppLocalization.string(key, language: language))
    }
}
