import Foundation

/// The language the app shows. `system` follows the device language list.
public enum AppLanguage: String, CaseIterable, Sendable, Identifiable {
    case system, tr, en

    public var id: String { rawValue }

    public static let defaultsKey = "app.language"

    private static let lock = NSLock()
    nonisolated(unsafe) private static var cachedBundle: Bundle?

    public static var current: AppLanguage {
        get { AppLanguage(rawValue: UserDefaults.standard.string(forKey: defaultsKey) ?? "") ?? .system }
        set {
            UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey)
            lock.lock(); cachedBundle = nil; lock.unlock()
        }
    }

    /// Bundle holding the chosen translation table. Without a matching `.lproj` (unit tests,
    /// "system") it is the main bundle, which then picks the device language by itself.
    static var bundle: Bundle {
        lock.lock(); defer { lock.unlock() }
        if let cachedBundle { return cachedBundle }
        let resolved: Bundle
        if current != .system,
           let path = Bundle.main.path(forResource: current.rawValue, ofType: "lproj"),
           let languageBundle = Bundle(path: path) {
            resolved = languageBundle
        } else {
            resolved = .main
        }
        cachedBundle = resolved
        return resolved
    }
}

/// Translates a source string for the chosen app language.
///
/// The source language is Turkish and the Turkish text is the lookup key. English lives in
/// `Support/Localization/en.lproj/Localizable.strings`, which `build.sh` copies into the app
/// bundle. With "system" macOS picks English or Turkish from the user's language list (English
/// for every language that has no translation). Without a bundle table (unit tests) the key
/// itself is returned, so tests see the Turkish text.
public func L(_ value: String.LocalizationValue) -> String {
    String(localized: value, bundle: AppLanguage.bundle)
}
