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

@MainActor
public final class AppLocalizer: ObservableObject {
    public nonisolated static let bundleLanguageKey = "io.github.zxu756.ChronoMac.language"
    public static let shared = AppLocalizer()

    @Published public private(set) var language: AppLanguage

    private let userDefaults: UserDefaults?
    private let defaultsKey: String

    public init(
        arguments: [String] = CommandLine.arguments,
        userDefaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages,
        defaultsKey: String = AppLocalizer.bundleLanguageKey
    ) {
        self.userDefaults = userDefaults
        self.defaultsKey = defaultsKey
        self.language = Self.resolveLanguage(
            arguments: arguments,
            userDefaults: userDefaults,
            preferredLanguages: preferredLanguages,
            defaultsKey: defaultsKey
        )
    }

    public init(
        language: AppLanguage,
        userDefaults: UserDefaults? = nil,
        defaultsKey: String = AppLocalizer.bundleLanguageKey
    ) {
        self.userDefaults = userDefaults
        self.defaultsKey = defaultsKey
        self.language = language
    }

    public nonisolated static func resolveLanguage(
        arguments: [String] = CommandLine.arguments,
        userDefaults: UserDefaults = .standard,
        preferredLanguages: [String] = Locale.preferredLanguages,
        defaultsKey: String = AppLocalizer.bundleLanguageKey
    ) -> AppLanguage {
        if let cliLang = AppLanguage.parseCLIArguments(arguments) {
            return cliLang
        }
        if let stored = userDefaults.string(forKey: defaultsKey),
           let parsed = AppLanguage.parse(stored) {
            return parsed
        }
        if let firstLocale = preferredLanguages.first,
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
        userDefaults?.set(newLanguage.rawValue, forKey: defaultsKey)
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
