import XCTest

/// 4.0 · «Togli i silenzi»: restano solo i pezzi in cui si parla.
final class SilencesTests: XCTestCase {
    func testDaiLivelliAiPezzi() {
        // 1 s di voce, 1,5 s di silenzio, 1 s di voce (passi da 20 ms)
        let levels = Array(repeating: -12.0, count: 50) + Array(repeating: -90.0, count: 75) + Array(repeating: -12.0, count: 50)
        let r = Silences.ranges(levels: levels, step: 0.02, offset: 10, end: 13.5)
        XCTAssertEqual(r.count, 2)
        XCTAssertEqual(r[0].lowerBound, 10, accuracy: 0.001, "non prima dell'inizio della clip")
        XCTAssertEqual(r[0].upperBound, 11.12, accuracy: 0.03)
        XCTAssertEqual(r[1].lowerBound, 12.38, accuracy: 0.03)
    }

    func testLePauseBreviRestano() {
        let levels = Array(repeating: -12.0, count: 50) + Array(repeating: -90.0, count: 15) + Array(repeating: -12.0, count: 50)
        XCTAssertEqual(Silences.ranges(levels: levels, step: 0.02, offset: 0, end: 2.3).count, 1, "0,3 s di pausa: è un respiro")
    }

    func testSuUnVideoVero() async throws {
        let rate = 44_100
        func tone(_ s: Double) -> [Float] { (0..<Int(s * Double(rate))).map { Float(sin(Double($0) * 2 * .pi * 440 / Double(rate)) * 0.5) } }
        func quiet(_ s: Double) -> [Float] { Array(repeating: 0, count: Int(s * Double(rate))) }
        let audio = tone(1) + quiet(1.5) + tone(1) + quiet(1.5)
        let v = try await Fixtures.video(name: "parlato-\(UUID().uuidString).mp4", width: 320, height: 180, seconds: 5, audio: audio)
        let r = try await Silences.voiced(in: v, start: 0, end: 5)
        XCTAssertEqual(r.count, 2, "\(r)")
        let kept = r.reduce(0) { $0 + ($1.upperBound - $1.lowerBound) }
        XCTAssertLessThan(kept, 3, "le pause se ne vanno")
        XCTAssertGreaterThan(kept, 1.9, "la voce resta tutta")
    }
}
