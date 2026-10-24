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

/// 4.0 · Testi e sottotitoli seguono i tagli di «Togli i silenzi».
final class SilencesTextsTests: XCTestCase {
    // Clip del file 0…10 s che parte a 5 s nel montaggio; restano 0…2 e 6…8 (tolti 4 s + 2 s finali)
    let clip = VPClip(path: "/x.mp4", inPoint: 0, outPoint: 10)
    let parts: [ClosedRange<Double>] = [0...2, 6...8]

    func testIstanti() {
        XCTAssertEqual(Silences.remap(3, clipStart: 5, clip: clip, parts: parts), 3, "prima della clip non cambia")
        XCTAssertEqual(Silences.remap(6, clipStart: 5, clip: clip, parts: parts), 6, accuracy: 0.001)
        XCTAssertEqual(Silences.remap(9, clipStart: 5, clip: clip, parts: parts), 7, accuracy: 0.001, "nella pausa: all'inizio del pezzo dopo")
        XCTAssertEqual(Silences.remap(12, clipStart: 5, clip: clip, parts: parts), 8, accuracy: 0.001)
        XCTAssertEqual(Silences.remap(20, clipStart: 5, clip: clip, parts: parts), 14, accuracy: 0.001, "dopo la clip: indietro di 6 s")
    }

    func testTestiSpostatiOTolti() {
        var a = VPText(); a.start = 11.5; a.end = 12.5; a.wordTimes = [0, 0.5]   // nel secondo pezzo
        var b = VPText(); b.start = 8; b.end = 10                               // tutto nella pausa
        var c = VPText(); c.start = 16; c.end = 18                              // dopo la clip
        let out = Silences.remap([a, b, c], clipStart: 5, clip: clip, parts: parts)
        XCTAssertEqual(out.count, 2, "il testo che stava solo nella pausa se ne va")
        XCTAssertEqual(out[0].start, 7.5, accuracy: 0.001)
        assertClose(out[0].wordTimes ?? [], [0, 0.5], accuracy: 0.001)
        XCTAssertEqual(out[1].start, 10, accuracy: 0.001)
    }

    func testCasiLimite() {
        XCTAssertEqual(Silences.ranges(levels: [], step: 0.02, offset: 0, end: 1), [])
        // livelli oltre la fine della clip: niente intervalli rovesciati
        let r = Silences.ranges(levels: Array(repeating: -10.0, count: 100), step: 0.02, offset: 5, end: 5.01)
        XCTAssertTrue(r.allSatisfy { $0.lowerBound < $0.upperBound })
    }
}
