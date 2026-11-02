import Foundation

/// Translates a source string for the device language.
///
/// The source language is Turkish and the Turkish text is the lookup key. English lives in
/// `Support/Localization/en.lproj/Localizable.strings`, which `build.sh` copies into the app
/// bundle; macOS then picks English or Turkish from the user's language list (English for
/// every language that has no translation). Without a bundle table (unit tests) the key
/// itself is returned, so tests see the Turkish text.
public func L(_ value: String.LocalizationValue) -> String {
    String(localized: value)
}
