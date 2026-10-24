import XCTest

/// 3.9 · Cartelle automatiche pronte: solo le estensioni scelte, mai i file già giusti.
final class AutomationTemplatesTests: XCTestCase {
    func testSoloLeEstensioniScelte() throws {
        let dir = Fixtures.dir.appendingPathComponent("download-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        for n in ["a.heic", "b.webp", "c.jpg", "d.png"] { try Data("x".utf8).write(to: dir.appendingPathComponent(n)) }
        let got = WatchStore.candidates(in: dir, kind: .img, exts: ["heic", "webp", "avif"]).map(\.lastPathComponent).sorted()
        XCTAssertEqual(got, ["a.heic", "b.webp"], "i JPG e i PNG non si toccano")
        XCTAssertEqual(WatchStore.candidates(in: dir, kind: .img).count, 4, "senza filtro, tutte le immagini")
    }

    func testModelliPronti() {
        XCTAssertEqual(WatchStore.templates.count, 2)
        let heic = WatchStore.templates[0].rule()
        XCTAssertEqual(heic.actionId, "to:jpg")
        XCTAssertEqual(heic.exts, ["heic", "webp", "avif"])
        XCTAssertTrue(heic.summary.hasPrefix("HEIC, WEBP, AVIF →"), heic.summary)
        XCTAssertEqual(WatchStore.templates[1].rule().param, "best", "i video: stessa qualità, meno peso")
    }
}
