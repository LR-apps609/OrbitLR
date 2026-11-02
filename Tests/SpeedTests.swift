import XCTest
import Combine

/// 6.0.1 · Passata sulle prestazioni: meno ridisegni e niente lavori doppi, con gli stessi risultati.
@MainActor
final class SpeedTests: XCTestCase {
    /// La testina di Audio e Taglia cambia 33 volte al secondo: non deve ridisegnare onda e pulsanti.
    func testLaTestinaNonRidisegnaLOnda() async throws {
        let w = try Fixtures.wav(Fixtures.tone(seconds: 2, level: 0.5), name: "testina-\(UUID().uuidString).wav")
        let t = TrimModel(url: w, isVideo: false, defaultLength: nil)
        for _ in 0..<200 where t.loading { try await Task.sleep(nanoseconds: 50_000_000) }
        var modelChanges = 0, clockChanges = 0
        let a = t.objectWillChange.sink { _ in modelChanges += 1 }
        let b = t.clock.objectWillChange.sink { _ in clockChanges += 1 }
        for i in 0..<30 { t.playhead = Double(i) * 0.03 }
        XCTAssertEqual(modelChanges, 0, "la posizione non tocca il modello dell'onda")
        XCTAssertEqual(clockChanges, 30)
        XCTAssertEqual(t.playhead, 0.87, accuracy: 0.0001)
        a.cancel(); b.cancel()
    }

    /// Doppio clic sulla torta: la stessa scelta entro mezzo secondo conta una volta.
    func testDoppioClicSullaTorta() {
        let ws = Workspace()
        let g = UUID(), t0 = Date()
        XCTAssertFalse(ws.isRepeatPick("to:png", group: g, now: t0))
        XCTAssertTrue(ws.isRepeatPick("to:png", group: g, now: t0.addingTimeInterval(0.2)), "doppio clic")
        XCTAssertFalse(ws.isRepeatPick("to:jpg", group: g, now: t0.addingTimeInterval(0.3)), "un'altra scelta passa")
        XCTAssertFalse(ws.isRepeatPick("to:jpg", group: g, now: t0.addingTimeInterval(1.0)), "dopo mezzo secondo è una scelta nuova")
        XCTAssertFalse(ws.isRepeatPick("to:jpg", group: UUID(), now: t0.addingTimeInterval(1.1)), "altro gruppo")
    }

    /// Togliendo un gruppo, quello che resta tiene peso e miniatura già calcolati (nessuna lettura in più).
    func testTogliereUnGruppoNonRifaGliAltri() throws {
        let photo = try Fixtures.photo(name: "resta-\(UUID().uuidString).jpg")
        let pdf = try Fixtures.wav(Fixtures.tone(seconds: 1), name: "via-\(UUID().uuidString).wav")
        let ws = Workspace()
        ws.load([photo, pdf])
        let img = try XCTUnwrap(ws.groups.first { $0.kind == .img })
        let other = try XCTUnwrap(ws.groups.first { $0.kind != .img })
        XCTAssertEqual(img.builtFiles, [photo])
        let subtitle = img.pie.subtitle
        img.pie.subtitle = "segno"
        ws.removeGroup(other)
        XCTAssertEqual(img.pie.subtitle, "segno", "il gruppo rimasto non è stato ricalcolato")
        img.pie.subtitle = subtitle
        img.files.append(photo)
        ws.remove(photo, from: img)
        XCTAssertEqual(img.builtFiles, img.files)
    }
}
