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

/// 3.5.2 · La segnalazione di un problema non porta con sé nomi di file né percorsi personali.
final class BugReportPrivacyTests: XCTestCase {
    func testNomiEPercorsiSpariscono() {
        let files = [URL(fileURLWithPath: "/Users/mario/Documenti/Carta d'identità.pdf")]
        let text = "Lavoro: Carta d'identità.pdf fallito in /Users/mario/Documenti/Carta d'identità.pdf e /Users/luca/x"
        let out = BugReport.anonymize(text, names: files, home: "/Users/mario")
        XCTAssertFalse(out.contains("identità"), out)
        XCTAssertFalse(out.contains("mario"), out)
        XCTAssertFalse(out.contains("luca"), out)
        XCTAssertTrue(out.contains("file.pdf"), out)
    }
}
