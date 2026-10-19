import Foundation

/// The user-visible text for `key`, which is the English text itself. Translations live in
/// Support/<language>.lproj/Localizable.strings and are copied into the app bundle, so outside
/// the app (in tests) every string stays English.
func localized(_ key: String) -> String {
    Bundle.main.localizedString(forKey: key, value: nil, table: nil)
}

/// `localized(format)` with the arguments filled in, for text that embeds numbers or names.
func localized(format: String, _ arguments: CVarArg...) -> String {
    String(format: localized(format), locale: .current, arguments: arguments)
}
