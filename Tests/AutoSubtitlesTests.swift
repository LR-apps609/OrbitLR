import XCTest

/// 3.3 · Sottotitoli automatici: righe brevi, tempi giusti anche con clip tagliate e accelerate.
final class AutoSubtitlesTests: XCTestCase {
    private func w(_ t: String, _ a: Double, _ b: Double) -> AutoSubtitles.Word { .init(text: t, start: a, end: b) }

    func testRigheBrevi() {
        let words = (0..<20).map { i in w("parola\(i)", Double(i) * 0.3, Double(i) * 0.3 + 0.25) }
        let lines = AutoSubtitles.lines(words)
        XCTAssertGreaterThan(lines.count, 2)
        for l in lines {
            XCTAssertLessThanOrEqual(l.text.split(separator: " ").count, AutoSubtitles.maxWords)
            XCTAssertLessThanOrEqual(l.text.count, AutoSubtitles.maxChars + 10)
        }
        for (a, b) in zip(lines, lines.dropFirst()) { XCTAssertLessThanOrEqual(a.end, b.start + 0.001, "le righe non si accavallano") }
    }

    func testPausaEPuntoChiudonoLaRiga() {
        let lines = AutoSubtitles.lines([w("Ciao", 0, 0.3), w("a", 0.35, 0.4), w("tutti.", 0.45, 0.8), w("Oggi", 2, 2.3), w("si", 3.5, 3.6)])
        XCTAssertEqual(lines.map(\.text), ["Ciao a tutti.", "Oggi", "si"])
    }

    func testLingua() {
        XCTAssertEqual(AutoSubtitles.preferredLocale(setting: "en").identifier, "en-US")
        XCTAssertEqual(AutoSubtitles.preferredLocale(setting: "auto", system: Locale(identifier: "fr_FR")).identifier, "fr-FR")
        XCTAssertEqual(AutoSubtitles.preferredLocale(setting: "auto", system: Locale(identifier: "ja_JP")).identifier, "it-IT")
    }

    func testTempiDelMontaggio() {
        // Clip che usa il file da 10 a 20 s, a velocità 2×, e parte a 5 s nel montaggio
        var c = VPClip(path: "/x.mp4", inPoint: 10, outPoint: 20)
        c.fx = VPEffects(); c.fx?.speed = 2
        let lines = [AutoSubtitles.Line(text: "prima", start: 2, end: 4),
                     AutoSubtitles.Line(text: "dentro", start: 12, end: 14),
                     AutoSubtitles.Line(text: "dopo", start: 25, end: 26)]
        let t = AutoSubtitles.timeline(lines, clip: c, clipStart: 5)
        XCTAssertEqual(t.map(\.text), ["dentro"], "solo quello che sta nel pezzo usato")
        XCTAssertEqual(t[0].start, 6, accuracy: 0.001)
        XCTAssertEqual(t[0].end, 7, accuracy: 0.001)
        let texts = AutoSubtitles.texts(t)
        XCTAssertEqual(texts[0].style, "subtitle")
        XCTAssertGreaterThan(texts[0].y, 0.8, "in basso")
    }
}
