import XCTest
@testable import DiskSweepCore

/// Guards the English translation table that ships in the app bundle.
final class LocalizationTests: XCTestCase {
    private var localizationDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Support/Localization")
    }

    private func placeholders(in text: String) -> [String] {
        let regex = try! NSRegularExpression(pattern: "%(?:\\d+\\$)?(@|lld)")
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, range: range).map { String(text[Range($0.range(at: 1), in: text)!]) }.sorted()
    }

    func testEnglishTableIsValidAndComplete() throws {
        let url = localizationDirectory.appendingPathComponent("en.lproj/Localizable.strings")
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String], "en.lproj must parse as a .strings file")
        XCTAssertGreaterThan(table.count, 200)

        for (key, value) in table {
            XCTAssertFalse(value.trimmingCharacters(in: .whitespaces).isEmpty, "empty translation for \(key)")
            XCTAssertEqual(placeholders(in: key), placeholders(in: value), "placeholder mismatch: \(key)")
        }
    }

    func testTurkishTableExistsSoTurkishIsSelectable() {
        let url = localizationDirectory.appendingPathComponent("tr.lproj/Localizable.strings")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testEverySourceStringIsTranslated() throws {
        // Every L("…") literal in the sources must have an English entry.
        let url = localizationDirectory.appendingPathComponent("en.lproj/Localizable.strings")
        let table = try XCTUnwrap(NSDictionary(contentsOf: url) as? [String: String])
        let sources = localizationDirectory.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        let regex = try NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)"\)"#)

        var missing: [String] = []
        let files = FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil)!
        for case let file as URL in files where file.pathExtension == "swift" {
            let text = try String(contentsOf: file, encoding: .utf8)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                var key = String(text[Range(match.range(at: 1), in: text)!]).replacingOccurrences(of: "\\\"", with: "\"")
                if key.contains("\\(") { continue } // interpolated keys are covered by the placeholder check above
                key = key.replacingOccurrences(of: "\\n", with: "\n")
                if table[key] == nil { missing.append("\(file.lastPathComponent): \(key)") }
            }
        }
        XCTAssertTrue(missing.isEmpty, "untranslated strings:\n" + missing.joined(separator: "\n"))
    }
}
