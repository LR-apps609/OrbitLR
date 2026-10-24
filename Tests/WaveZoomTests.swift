import XCTest

/// 3.8 · Onda bassa come prima, con lo zoom in larghezza (fino al millesimo) e in altezza.
final class WaveZoomTests: XCTestCase {
    func testMillesimiAllItaliana() {
        XCTAssertEqual(formatTimeMs(1.2345), "0:01,234")
        XCTAssertEqual(formatTimeMs(62.5), "1:02,500")
        XCTAssertEqual(formatTimeMs(3725.001), "1:02:05,001")
    }

    func testPiramideTieneIPicchi() {
        var base = [Float](repeating: 0, count: 5000)
        base[3333] = 1
        let lv = TrimModel.pyramid(base)
        XCTAssertGreaterThan(lv.count, 2)
        XCTAssertLessThanOrEqual(lv.last!.count, 700)
        for l in lv { XCTAssertEqual(l.max(), 1, "un colpo breve non sparisce a nessun livello") }
    }

    @MainActor
    func testZoomAlMillesimo() async throws {
        // 2 s di silenzio, 0,01 s di suono, poi silenzio fino a 4 s
        let samples = Fixtures.silence(seconds: 2) + Fixtures.tone(seconds: 0.01, level: 0.8) + Fixtures.silence(seconds: 1.99)
        let w = try Fixtures.wav(samples, name: "colpo.wav")
        let t = TrimModel(url: w, isVideo: false, defaultLength: nil)
        for _ in 0..<200 where t.loading { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(t.loading)
        XCTAssertEqual(Double(t.levels.first?.count ?? 0), 4000, accuracy: 20, "un picco ogni millesimo")

        t.setZoom(1000, around: 2.005)
        XCTAssertEqual(t.zoom, t.maxZoom, accuracy: 0.001)
        XCTAssertEqual(t.span, 0.25, accuracy: 0.001, "al massimo un quarto di secondo su tutta la larghezza")
        XCTAssertLessThanOrEqual(t.viewStart, 2.0)
        XCTAssertGreaterThanOrEqual(t.viewStart + t.span, 2.01)
        let p = t.visiblePeaks(count: 250)                        // un millesimo per barra
        let loud = p.indices.filter { p[$0] > 0.5 }
        XCTAssertFalse(loud.isEmpty)
        XCTAssertLessThanOrEqual(loud.count, 14, "il colpo occupa circa 10 barre da un millesimo")

        // Spostare la vista non va oltre la fine
        t.pan(by: 100)
        XCTAssertEqual(t.viewStart + t.span, t.duration, accuracy: 0.002)

        // Inizio al millesimo
        t.setStart(2.003)
        XCTAssertEqual(t.start, 2.003, accuracy: 0.0005)

        t.gain = 4
        t.zoomReset()
        XCTAssertEqual(t.zoom, 1)
        XCTAssertEqual(t.viewStart, 0)
        XCTAssertEqual(t.gain, 1)

        // Selezione: lo zoom la incornicia
        t.setStart(1); t.setEnd(1.5)
        t.zoomToSelection()
        XCTAssertLessThanOrEqual(t.viewStart, 1)
        XCTAssertGreaterThanOrEqual(t.viewStart + t.span, 1.5)
        XCTAssertLessThan(t.span, 1)
    }
}
