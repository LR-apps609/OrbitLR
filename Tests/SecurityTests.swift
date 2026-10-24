import XCTest

/// 3.5.2 · Sicurezza dei link orbitlr://
final class SecurityTests: XCTestCase {
    /// Un link (anche da una pagina web) non deve mai spostare o copiare file dai dati di un'altra app.
    func testUnLinkNonToccaIDatiDiAltreApp() throws {
        let fm = FileManager.default
        let fake = Fixtures.dir.appendingPathComponent("Library/Containers/com.altra.app/Data/segreto-\(UUID().uuidString).txt")
        try fm.createDirectory(at: fake.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "segreto".write(to: fake, atomically: true, encoding: .utf8)
        var c = URLComponents(string: "orbitlr://open")!
        c.queryItems = [URLQueryItem(name: "f", value: fake.path)]
        let got = SharedFiles.receive(c.url!)
        XCTAssertTrue(got.isEmpty, "il file di un'altra app viene ignorato")
        XCTAssertTrue(fm.fileExists(atPath: fake.path), "e resta dov'è")
    }

    func testUnFileNormaleArrivaComE() throws {
        let f = Fixtures.dir.appendingPathComponent("normale-\(UUID().uuidString).txt")
        try FileManager.default.createDirectory(at: Fixtures.dir, withIntermediateDirectories: true)
        try "ciao".write(to: f, atomically: true, encoding: .utf8)
        var c = URLComponents(string: "orbitlr://open")!
        c.queryItems = [URLQueryItem(name: "f", value: f.path)]
        XCTAssertEqual(SharedFiles.receive(c.url!).map(\.path), [f.path])
    }
}
