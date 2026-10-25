import XCTest

/// 4.1.1 · Forma d'onda: righello, volume medio, riquadro che cresce.
final class WaveLookTests: XCTestCase {
    func testRighello() {
        // 4:40 su 700 punti: un segno al minuto (uno ogni 80 punti circa)
        XCTAssertEqual(TrimTimeline.tickStep(span: 280, width: 700), 60)
        XCTAssertEqual(TrimTimeline.tickStep(span: 0.25, width: 800), 0.05, "al massimo zoom: ogni 50 millesimi")
        XCTAssertEqual(TrimTimeline.tickLabel(90, step: 30), "1:30")
        XCTAssertEqual(TrimTimeline.tickLabel(2.005, step: 0.005), "0:02,005")
        XCTAssertEqual(TrimTimeline.tickLabel(3725, step: 300), "1:02:05")
    }

    func testVolumeMedioAPiramide() {
        let lv = TrimModel.pyramid([0, 1, 1, 1, 0, 0, 0, 0] + [Float](repeating: 0.5, count: 2000), average: true)
        XCTAssertEqual(lv[1][0], 0.5, accuracy: 0.0001, "la media, non il massimo")
        XCTAssertEqual(lv[1][1], 1, accuracy: 0.0001)
        let pk = TrimModel.pyramid([0, 1, 0.2, 0.4] + [Float](repeating: 0, count: 2000))
        XCTAssertEqual(Array(pk[1].prefix(2)), [1, 0.4], "i picchi restano il massimo")
    }

    @MainActor
    func testVolumeMedioDentroIPicchi() async throws {
        let samples = Fixtures.tone(seconds: 2, level: 0.8) + Fixtures.silence(seconds: 1) + Fixtures.tone(seconds: 2, level: 0.2)
        let w = try Fixtures.wav(samples, name: "due-volumi.wav")
        let t = TrimModel(url: w, isVideo: false, defaultLength: nil)
        for _ in 0..<200 where t.loading { try await Task.sleep(nanoseconds: 50_000_000) }
        let p = t.visiblePeaks(count: 100), r = t.visibleRMS(count: 100)
        XCTAssertEqual(p.count, 100)
        XCTAssertEqual(r.count, 100)
        for i in 0..<100 { XCTAssertLessThanOrEqual(r[i], p[i] + 0.001, "il volume medio sta dentro i picchi (barra \(i))") }
        XCTAssertGreaterThan(r[10], r[90], "la parte forte è più piena di quella piano")
        XCTAssertLessThan(r[50], 0.05, "il silenzio è vuoto")
        // L'altezza cresce fino al massimo, poi si ferma
        t.gain = min(TrimModel.maxGain, 1 * 1.5 * 1.5 * 1.5 * 1.5)
        XCTAssertEqual(t.gain, TrimModel.maxGain)
    }
}
