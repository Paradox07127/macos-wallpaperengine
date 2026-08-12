import Foundation
import SwiftUI

public enum AppLanguagePreference: String, CaseIterable, Identifiable, Sendable {
    case system
    case english = "en"
    case simplifiedChinese = "zh-Hans"
    case traditionalChinese = "zh-Hant"
    case japanese = "ja"

    public static let storageKey = "AppLanguage.Preference"

    public var id: String { rawValue }

    public var localeIdentifier: String? {
        switch self {
        case .system:
            return nil
        case .english, .simplifiedChinese, .traditionalChinese, .japanese:
            return rawValue
        }
    }

    public var locale: Locale {
        localeIdentifier.map(Locale.init(identifier:)) ?? .autoupdatingCurrent
    }

    public func localizationBundle(in bundle: Bundle = .main) -> Bundle {
        guard let localeIdentifier,
              let path = bundle.path(forResource: localeIdentifier, ofType: "lproj"),
              let localizedBundle = Bundle(path: path) else {
            return bundle
        }
        return localizedBundle
    }

    public var titleKey: LocalizedStringKey {
        switch self {
        case .system:
            return "Follow System"
        case .english:
            return "English"
        case .simplifiedChinese:
            return "Simplified Chinese"
        case .traditionalChinese:
            return "Traditional Chinese"
        case .japanese:
            return "Japanese"
        }
    }

    public static var current: AppLanguagePreference {
        current(in: .standard)
    }

    public static func current(in defaults: UserDefaults) -> AppLanguagePreference {
        guard let rawValue = defaults.string(forKey: storageKey) else {
            return .system
        }
        return AppLanguagePreference(rawValue: rawValue) ?? .system
    }

    public static func save(
        _ preference: AppLanguagePreference,
        to defaults: UserDefaults = .standard
    ) {
        if preference == .system {
            defaults.removeObject(forKey: storageKey)
        } else {
            defaults.set(preference.rawValue, forKey: storageKey)
        }
    }

    public static func localizedString(
        _ key: String,
        defaultValue: String? = nil,
        tableName: String? = nil,
        bundle: Bundle = .main
    ) -> String {
        current.localizationBundle(in: bundle).localizedString(
            forKey: key,
            value: defaultValue ?? key,
            table: tableName
        )
    }

    public static func localizedFormat(
        _ key: String,
        defaultValue: String? = nil,
        tableName: String? = nil,
        bundle: Bundle = .main,
        _ arguments: CVarArg...
    ) -> String {
        let format = localizedString(
            key,
            defaultValue: defaultValue,
            tableName: tableName,
            bundle: bundle
        )
        return String(format: format, locale: current.locale, arguments: arguments)
    }
}

public struct AppLanguageScope<Content: View>: View {
    @AppStorage(AppLanguagePreference.storageKey) private var rawPreference = AppLanguagePreference.system.rawValue

    private let content: Content

    public init(defaults: UserDefaults = .standard, @ViewBuilder content: () -> Content) {
        _rawPreference = AppStorage(
            wrappedValue: AppLanguagePreference.system.rawValue,
            AppLanguagePreference.storageKey,
            store: defaults
        )
        self.content = content()
    }

    public var body: some View {
        content.environment(\.locale, preference.locale)
    }

    private var preference: AppLanguagePreference {
        AppLanguagePreference(rawValue: rawPreference) ?? .system
    }
}

extension View {
    public func appLanguageScoped(defaults: UserDefaults = .standard) -> some View {
        AppLanguageScope(defaults: defaults) {
            self
        }
    }
}
