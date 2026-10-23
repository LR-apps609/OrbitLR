import XCTest
import AVFoundation

/// 3.4.6 · Anteprima del montaggio: dopo una modifica il lettore nuovo arriva già pronto sul punto giusto.
@MainActor
final class PreviewTests: XCTestCase {
    func testDopoUnaModificaIlLettoreNuovoÈPronto() async throws {
        let v = try await Fixtures.video(name: "anteprima-\(UUID().uuidString).mp4", width: 320, height: 180, seconds: 3)
        let s = VideoProjectStore(folder: Fixtures.dir.appendingPathComponent("anteprima-\(UUID().uuidString)", isDirectory: true))
        s.newProject(nil)
        s.add([v], undo: nil)
        for _ in 0..<80 where s.player.currentItem == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNotNil(s.player.currentItem, "l'anteprima c'è")
        s.seek(1.5)
        for _ in 0..<20 { try await Task.sleep(nanoseconds: 50_000_000) }
        let first = s.player
        // Una modifica: il lettore si scambia con uno nuovo, già sullo stesso punto
        s.change(nil, "Taglia") { $0.clips[0].outPoint = 2.5 }
        for _ in 0..<80 where s.player === first { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertFalse(s.player === first, "dopo una modifica arriva il lettore nuovo")
        XCTAssertNotNil(s.player.currentItem)
        XCTAssertEqual(s.player.currentTime().seconds, 1.5, accuracy: 0.1, "resta sul punto in cui eri")
        XCTAssertNil(first.currentItem, "quello vecchio si svuota")
        if let t = Perf.last(.previewRebuild) { print("TEMPO: anteprima dopo un taglio \(Int(t * 1000)) ms") }
        s.closeProject(nil)
    }

    func testTrascinareLIndicatoreNonAccumulaRitardo() async throws {
        let v = try await Fixtures.video(name: "scorri-\(UUID().uuidString).mp4", width: 320, height: 180, seconds: 4)
        let s = VideoProjectStore(folder: Fixtures.dir.appendingPathComponent("scorri-\(UUID().uuidString)", isDirectory: true))
        s.newProject(nil)
        s.add([v], undo: nil)
        for _ in 0..<80 where s.player.currentItem == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        // Trenta spostamenti di fila, come un dito che scorre: l'indicatore segue subito, l'immagine arriva all'ultimo
        for i in 0..<30 { s.seek(Double(i) * 0.1) }
        XCTAssertEqual(s.clock.time, 2.9, accuracy: 0.001, "l'indicatore è già all'ultimo punto")
        for _ in 0..<40 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(s.player.currentTime().seconds, 2.9, accuracy: 0.1, "e l'immagine lo ha raggiunto")
        s.closeProject(nil)
    }

    /// 3.4.8 · Frecce e J: passi precisi, mai fuori dal montaggio.
    func testPassiDallaTastiera() async throws {
        let v = try await Fixtures.video(name: "passi-\(UUID().uuidString).mp4", width: 320, height: 180, seconds: 2)
        let s = VideoProjectStore(folder: Fixtures.dir.appendingPathComponent("passi-\(UUID().uuidString)", isDirectory: true))
        s.newProject(nil)
        s.add([v], undo: nil)
        for _ in 0..<80 where s.player.currentItem == nil { try await Task.sleep(nanoseconds: 100_000_000) }
        s.seek(1)
        s.step(1.0 / 30)
        XCTAssertEqual(s.clock.time, 1 + 1.0 / 30, accuracy: 0.0001)
        s.step(-1)
        XCTAssertEqual(s.clock.time, 1.0 / 30, accuracy: 0.0001)
        s.step(-1)
        XCTAssertEqual(s.clock.time, 0, "non va prima dell'inizio")
        s.step(10)
        XCTAssertLessThanOrEqual(s.clock.time, 2.01, "né dopo la fine")
        s.closeProject(nil)
    }
}
