import XCTest

/// 2.7.5 · Novità solo dalla versione che avevi, pulsanti che risolvono gli errori, peso previsto di Comprimi e Social.
final class NewsAndFixTests: XCTestCase {
    private let sample = """
    Novità della 2.7.5 «Errori»:
    • Errori con un pulsante
    • Conversione: statistiche del mese

    Novità della 2.7.4 «Passo dopo passo»:
    • Video: percorso in 4 passi

    Novità della 2.7.3 «Progetti»:
    • Video: schermata Progetti

    Novità della 2.7.2:
    • Cronologia: cestino

    Novità della 2.7 «Wow»:
    • Icona nuova
    """

    func testNewsOnlySinceYourVersion() {
        XCTAssertEqual(News.items(since: "2.7.4", in: sample), ["Errori con un pulsante", "Conversione: statistiche del mese"])
        XCTAssertEqual(News.items(since: "2.7.3", in: sample).count, 3)
        XCTAssertEqual(News.items(since: "2.6.4", in: sample).count, 4, "al massimo le ultime 3 versioni")
        XCTAssertEqual(News.items(since: "", in: sample).count, 2, "senza versione precedente: solo l'ultima")
        XCTAssertTrue(News.items(since: "2.7.5", in: sample).isEmpty)
    }

    func testVersionCompare() {
        XCTAssertTrue(News.newer("2.7.10", than: "2.7.9"))
        XCTAssertTrue(News.newer("2.8", than: "2.7.5"))
        XCTAssertFalse(News.newer("2.7", than: "2.7.0"))
        XCTAssertEqual(News.version(inHeader: "Novità della 2.7.4 «Passo dopo passo»:"), "2.7.4")
        XCTAssertNil(News.version(inHeader: "• Video"))
    }

    func testNewsPlace() {
        XCTAssertEqual(News.place(of: "Video: schermata Progetti"), .video)
        XCTAssertEqual(News.place(of: "Cronologia: cestino"), .history)
        XCTAssertEqual(News.place(of: "Peso previsto sugli spicchi"), .workspace)
        XCTAssertNil(News.place(of: "Icona nuova"))
    }

    func testFixForFullDiskAndLockedFolder() throws {
        let a = try XCTUnwrap(Catalog.action(id: "to:png", kind: .img))
        let disk = Job(files: [URL(fileURLWithPath: "/tmp/a.jpg")], action: a, param: "")
        disk.state = .failed
        disk.failures = ["a.jpg: No space left on device"]
        XCTAssertEqual(Fix.best(for: disk), .storage)
        let folder = Job(files: [URL(fileURLWithPath: "/tmp/b.jpg")], action: a, param: "")
        folder.state = .failed
        folder.failures = ["b.jpg: Operation not permitted"]
        XCTAssertEqual(Fix.best(for: folder), .otherFolder)
    }

    func testSocialAndCompressEstimates() {
        // 9:16 a 1080: circa 8 Mbit/s → 10 s ≈ 10 MB
        let b = SizeEstimate.socialBytes(seconds: 10, aspect: "9x16")
        XCTAssertGreaterThan(b, 8_000_000)
        XCTAssertLessThan(b, 13_000_000)
        XCTAssertGreaterThan(SizeEstimate.socialBytes(seconds: 10, aspect: "16x9"), 0)
        XCTAssertEqual(SizeEstimate.socialBytes(seconds: 10, aspect: "16x9"), SizeEstimate.socialBytes(seconds: 10, aspect: "9x16"),
                       "stessa superficie, girata")
        XCTAssertTrue(SizeEstimate.compressText(current: 80_000_000, targetMB: 25, files: 1).contains("al massimo"))
        XCTAssertTrue(SizeEstimate.compressText(current: 5_000_000, targetMB: 25, files: 1).contains("sotto il limite"))
    }
}

/// 2.7.6 · Il Dock si ridisegna una volta sola per ogni icona nuova.
final class DockIconTests: XCTestCase {
    func testRefreshOnlyForNewIcon() {
        XCTAssertTrue(DockIcon.needsRefresh(stored: 0), "mai fatto: sì")
        XCTAssertTrue(DockIcon.needsRefresh(stored: DockIcon.revision - 1))
        XCTAssertFalse(DockIcon.needsRefresh(stored: DockIcon.revision), "già fatto per questa icona: no")
    }
}
