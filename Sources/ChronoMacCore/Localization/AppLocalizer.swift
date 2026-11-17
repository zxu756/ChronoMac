import Combine
import Foundation
import SwiftUI

public enum AppLanguage: String, CaseIterable, Identifiable, Codable, Sendable {
    case zhHans = "zh-Hans"
    case en = "en"

    public var id: String { rawValue }

    public var badge: String {
        switch self {
        case .zhHans: return "中文"
        case .en: return "EN"
        }
    }

    public var displayName: String {
        switch self {
        case .zhHans: return "简体中文"
        case .en: return "English"
        }
    }

    public static func parse(_ raw: String?) -> AppLanguage? {
        guard let raw else { return nil }
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !token.isEmpty else { return nil }
        if token == "中文" || token == "cn" || token.hasPrefix("zh") {
            return .zhHans
        }
        if token.hasPrefix("en") {
            return .en
        }
        return nil
    }

    public static func parseCLIArguments(_ arguments: [String]) -> AppLanguage? {
        for (idx, arg) in arguments.enumerated() {
            if arg == "--lang", idx + 1 < arguments.count {
                if let parsed = parse(arguments[idx + 1]) {
                    return parsed
                }
            } else if arg.hasPrefix("--lang=") {
                let value = String(arg.dropFirst("--lang=".count))
                if let parsed = parse(value) {
                    return parsed
                }
            }
        }
        return nil
    }
}

public protocol PreferenceStore: AnyObject {
    func string(forKey defaultName: String) -> String?
    func set(_ value: Any?, forKey defaultName: String)
}

extension UserDefaults: PreferenceStore {}

public final class UserDefaultsPreferenceStore: PreferenceStore, @unchecked Sendable {
    public let userDefaults: UserDefaults

    public init(_ userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    public func string(forKey defaultName: String) -> String? {
        userDefaults.string(forKey: defaultName)
    }

    public func set(_ value: Any?, forKey defaultName: String) {
        userDefaults.set(value, forKey: defaultName)
    }
}

public final class InMemoryPreferenceStore: PreferenceStore, @unchecked Sendable {
    private var storage: [String: String]
    private let lock = NSLock()

    public init(initial: [String: String] = [:]) {
        self.storage = initial
    }

    public func string(forKey defaultName: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return storage[defaultName]
    }

    public func set(_ value: Any?, forKey defaultName: String) {
        lock.lock()
        defer { lock.unlock() }
        if let str = value as? String {
            storage[defaultName] = str
        } else if value == nil {
            storage.removeValue(forKey: defaultName)
        }
    }
}

@MainActor
public final class AppLocalizer: ObservableObject {
    public nonisolated static let bundleLanguageKey = "io.github.zxu756.ChronoMac.language"
    public static let shared = AppLocalizer()

    @Published public private(set) var language: AppLanguage
    public private(set) var preferenceStore: any PreferenceStore
    private var defaultsKey: String

    public init(
        arguments: [String] = CommandLine.arguments,
        preferenceStore: any PreferenceStore = InMemoryPreferenceStore(),
        preferredLanguages: [String]? = nil,
        environment: [String: String]? = nil,
        defaultsKey: String = AppLocalizer.bundleLanguageKey
    ) {
        self.preferenceStore = preferenceStore
        self.defaultsKey = defaultsKey
        self.language = Self.resolveLanguage(
            arguments: arguments,
            preferenceStore: preferenceStore,
            preferredLanguages: preferredLanguages,
            environment: environment,
            defaultsKey: defaultsKey
        )
    }

    public init(
        language: AppLanguage,
        preferenceStore: any PreferenceStore = InMemoryPreferenceStore(),
        defaultsKey: String = AppLocalizer.bundleLanguageKey
    ) {
        self.preferenceStore = preferenceStore
        self.defaultsKey = defaultsKey
        self.language = language
    }

    @discardableResult
    public static func configureShared(
        arguments: [String] = CommandLine.arguments,
        preferenceStore: any PreferenceStore,
        preferredLanguages: [String]? = nil,
        environment: [String: String]? = nil,
        defaultsKey: String = AppLocalizer.bundleLanguageKey
    ) -> AppLocalizer {
        shared.configure(
            arguments: arguments,
            preferenceStore: preferenceStore,
            preferredLanguages: preferredLanguages,
            environment: environment,
            defaultsKey: defaultsKey
        )
        return shared
    }

    public func configure(
        arguments: [String] = CommandLine.arguments,
        preferenceStore: any PreferenceStore,
        preferredLanguages: [String]? = nil,
        environment: [String: String]? = nil,
        defaultsKey: String = AppLocalizer.bundleLanguageKey
    ) {
        self.preferenceStore = preferenceStore
        self.defaultsKey = defaultsKey
        self.language = Self.resolveLanguage(
            arguments: arguments,
            preferenceStore: preferenceStore,
            preferredLanguages: preferredLanguages,
            environment: environment,
            defaultsKey: defaultsKey
        )
    }

    public nonisolated static func resolveLanguage(
        arguments: [String] = CommandLine.arguments,
        preferenceStore: (any PreferenceStore)? = nil,
        preferredLanguages: [String]? = nil,
        environment: [String: String]? = nil,
        defaultsKey: String = AppLocalizer.bundleLanguageKey
    ) -> AppLanguage {
        if let cliLang = AppLanguage.parseCLIArguments(arguments) {
            return cliLang
        }
        if let stored = preferenceStore?.string(forKey: defaultsKey),
           let parsed = AppLanguage.parse(stored) {
            return parsed
        }
        let effectiveEnv = environment ?? (preferredLanguages == nil ? ProcessInfo.processInfo.environment : [:])
        for envKey in ["CHRONOMAC_LANG", "LC_ALL", "LANG"] {
            if let rawEnv = effectiveEnv[envKey],
               let parsedEnv = AppLanguage.parse(rawEnv) {
                return parsedEnv
            }
        }
        let effectiveLocales = preferredLanguages ?? Locale.preferredLanguages
        if let firstLocale = effectiveLocales.first,
           firstLocale.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().hasPrefix("zh") {
            return .zhHans
        }
        return .en
    }

    public var isChinese: Bool {
        language == .zhHans
    }

    public func L(_ en: String, _ zh: String) -> String {
        language == .zhHans ? zh : en
    }

    public func setLanguage(_ newLanguage: AppLanguage) {
        language = newLanguage
        preferenceStore.set(newLanguage.rawValue, forKey: defaultsKey)
    }

    public func toggle() {
        setLanguage(language == .zhHans ? .en : .zhHans)
    }
}

public struct ChronoLanguageTogglePill: View {
    @ObservedObject var localizer: AppLocalizer
    public var compact: Bool = false

    public init(localizer: AppLocalizer, compact: Bool = false) {
        self.localizer = localizer
        self.compact = compact
    }

    public var body: some View {
        HStack(spacing: 2) {
            ForEach(AppLanguage.allCases) { item in
                let active = localizer.language == item
                Button(action: { localizer.setLanguage(item) }) {
                    Text(item.badge)
                        .font(.system(size: compact ? 10.5 : 11, weight: active ? .semibold : .medium))
                        .tracking(0)
                        .foregroundStyle(active ? ChronoTheme.ink : ChronoTheme.muted)
                        .padding(.horizontal, compact ? 7.5 : 9)
                        .padding(.vertical, compact ? 3 : 4)
                        .fixedSize(horizontal: true, vertical: false)
                        .background(
                            RoundedRectangle(cornerRadius: compact ? 5 : 6, style: .continuous)
                                .fill(active ? ChronoTheme.viewport : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: compact ? 5 : 6, style: .continuous)
                                .strokeBorder(active ? ChronoTheme.hairline : Color.clear, lineWidth: 1)
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(compact ? 2 : 2.5)
        .background(
            RoundedRectangle(cornerRadius: compact ? 6.5 : 8, style: .continuous)
                .fill(ChronoTheme.well)
        )
        .overlay(
            RoundedRectangle(cornerRadius: compact ? 6.5 : 8, style: .continuous)
                .strokeBorder(ChronoTheme.hairline.opacity(0.65), lineWidth: 0.5)
        )
        .fixedSize(horizontal: true, vertical: false)
        .help("切换语言 / Toggle Language (⇧⌘L)")
    }
}
