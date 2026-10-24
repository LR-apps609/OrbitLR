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

/// 4.0 · Sottotitoli «Parola per parola»: si accende la parola detta in quel momento.
final class WordHighlightTests: XCTestCase {
    func testConITempiDelleParole() {
        var t = VPText()
        t.text = "Ciao a tutti."; t.start = 10; t.end = 12; t.anim = "word"
        t.wordTimes = [0, 0.5, 0.7]
        XCTAssertEqual(t.wordIndex(at: 10.1), 0)
        XCTAssertEqual(t.wordIndex(at: 10.55), 1)
        XCTAssertEqual(t.wordIndex(at: 11.9), 2)
    }

    func testSenzaTempiAIntervalliUguali() {
        var t = VPText()
        t.text = "uno due tre quattro"; t.start = 0; t.end = 4; t.anim = "word"
        XCTAssertEqual(t.wordIndex(at: 0.5), 0)
        XCTAssertEqual(t.wordIndex(at: 2.5), 2)
        XCTAssertEqual(t.wordIndex(at: 3.99), 3)
    }

    func testISottotitoliAutomaticiLiUsano() {
        let ws = [AutoSubtitles.Word(text: "Ciao", start: 1, end: 1.3), AutoSubtitles.Word(text: "mondo.", start: 1.4, end: 1.8)]
        let texts = AutoSubtitles.texts(AutoSubtitles.lines(ws))
        XCTAssertEqual(texts.first?.anim, "word")
        assertClose(texts.first?.wordTimes ?? [], [0, 0.4], accuracy: 0.001)
    }

    func testLaParolaAccesaCambiaIlDisegno() {
        let a = TextRender.bitmap("Ciao mondo", style: "subtitle", color: "white", canvas: CGSize(width: 1280, height: 720), highlight: 0)
        let b = TextRender.bitmap("Ciao mondo", style: "subtitle", color: "white", canvas: CGSize(width: 1280, height: 720), highlight: 1)
        XCTAssertNotNil(a); XCTAssertNotNil(b)
        XCTAssertFalse(a === b, "due disegni diversi")
    }
}

func assertClose(_ a: [Double], _ b: [Double], accuracy: Double, file: StaticString = #filePath, line: UInt = #line) {
    XCTAssertEqual(a.count, b.count, file: file, line: line)
    for (x, y) in zip(a, b) { XCTAssertEqual(x, y, accuracy: accuracy, file: file, line: line) }
}

/// 4.0 · Dopo «Togli i silenzi» una riga a cavallo di due pezzi non si ripete: ogni pezzo ha le sue parole.
final class SubtitlesAcrossCutsTests: XCTestCase {
    func testOgniPezzoHaLeSueParole() {
        let ws = [AutoSubtitles.Word(text: "uno", start: 1.0, end: 1.3), AutoSubtitles.Word(text: "due", start: 1.4, end: 1.7),
                  AutoSubtitles.Word(text: "tre", start: 2.1, end: 2.4), AutoSubtitles.Word(text: "quattro", start: 2.5, end: 2.9)]
        let lines = AutoSubtitles.lines(ws)
        XCTAssertEqual(lines.count, 1, "una riga sola: le pause sono brevi")
        let a = AutoSubtitles.timeline(lines, clip: VPClip(path: "/x.mp4", inPoint: 0.9, outPoint: 1.82), clipStart: 0)
        let b = AutoSubtitles.timeline(lines, clip: VPClip(path: "/x.mp4", inPoint: 1.98, outPoint: 3.0), clipStart: 0.92)
        XCTAssertEqual(a.map(\.text), ["uno due"])
        XCTAssertEqual(b.map(\.text), ["tre quattro"])
        XCTAssertEqual(b[0].start, 0.92 + (2.1 - 1.98), accuracy: 0.001)
        assertClose(AutoSubtitles.texts(b)[0].wordTimes ?? [], [0, 0.4], accuracy: 0.001)
    }

    func testParoleContateSempreAlloStessoModo() {
        XCTAssertEqual(VPText.wordCount("  l’acqua,  è\tfredda!\n"), 3)
        XCTAssertEqual(VPText.wordCount(""), 0)
        let t = "Ciao  👋 mondo"
        XCTAssertEqual(VPText.wordRanges(t).map { String(t[$0]) }, ["Ciao", "👋", "mondo"])
    }
}
