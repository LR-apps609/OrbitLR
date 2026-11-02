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
}
