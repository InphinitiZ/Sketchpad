import Foundation
import Testing
@testable import Sketchpad

/// Checks the string tables against the `localized(…)` calls in the app's sources.
@Suite struct LocalizationTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Every literal key passed to `localized` in Sources/Sketchpad.
    private static func keysInSources() throws -> Set<String> {
        let folder = root.appendingPathComponent("Sources/Sketchpad")
        let pattern = try NSRegularExpression(pattern: #"localized\((?:format: )?"((?:[^"\\]|\\.)*)""#)
        var keys = Set<String>()
        for name in try FileManager.default.contentsOfDirectory(atPath: folder.path) where name.hasSuffix(".swift") {
            let source = try String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8)
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                keys.insert(String(source[Range(match.range(at: 1), in: source)!]))
            }
        }
        return keys
    }

    private static func table(_ language: String) throws -> [String: String] {
        let url = root.appendingPathComponent("Support/\(language).lproj/Localizable.strings")
        return try #require(NSDictionary(contentsOf: url) as? [String: String])
    }

    /// The format specifiers in order, ignoring positions (`%1$ld` counts as `%ld`).
    private static func specifiers(_ format: String) -> [String] {
        let pattern = try! NSRegularExpression(pattern: #"%(?:\d+\$)?(l?d|@)"#)
        return pattern.matches(in: format, range: NSRange(format.startIndex..., in: format)).map {
            String(format[Range($0.range(at: 1), in: format)!])
        }
    }

    @Test func everyKeyHasAChineseTranslation() throws {
        let keys = try Self.keysInSources()
        #expect(keys.count > 100)
        let chinese = try Self.table("zh-Hans")
        #expect(keys.subtracting(chinese.keys).sorted() == [], "untranslated")
        #expect(Set(chinese.keys).subtracting(keys).sorted() == [], "no longer used")
    }

    @Test func translationsKeepTheirFormatSpecifiers() throws {
        for (key, value) in try Self.table("zh-Hans") {
            #expect(Self.specifiers(key).sorted() == Self.specifiers(value).sorted(), "\(key) → \(value)")
        }
    }

    @Test func outsideTheAppTextStaysEnglish() {
        #expect(localized("Pencil") == "Pencil")
        #expect(localized(format: "%ld × %ld px", 800, 600) == "800 × 600 px")
    }
}
