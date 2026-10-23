import XCTest

/// Il numero di versione è lo stesso dappertutto: pacchetto, app e impostazioni del progetto.
/// (Nella 3.0 e nella prima 3.3 l'app diceva ancora 2.9.11: l'aggiornamento sembrava non installarsi.)
final class VersionTests: XCTestCase {
    func testStessaVersioneOvunque() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let version = try String(contentsOf: root.appendingPathComponent("version.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        func values(_ key: String) -> [String] {
            yml.split(separator: "\n").compactMap { line -> String? in
                let t = line.trimmingCharacters(in: .whitespaces)
                guard t.hasPrefix(key + ":") else { return nil }
                return t.dropFirst(key.count + 1).trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: "")
            }
        }
        let shown = values("CFBundleShortVersionString") + values("MARKETING_VERSION")
        XCTAssertFalse(shown.isEmpty)
        for v in shown { XCTAssertEqual(v, version, "project.yml dice \(v), version.txt dice \(version)") }
        let builds = Set(values("CFBundleVersion") + values("CURRENT_PROJECT_VERSION"))
        XCTAssertEqual(builds.count, 1, "numeri di build diversi: \(builds)")
        let news = try String(contentsOf: root.appendingPathComponent("NOVITA.txt"), encoding: .utf8)
        XCTAssertTrue(news.hasPrefix("Novità della \(version) "), "NOVITA.txt deve iniziare dalla \(version)")
    }
}
