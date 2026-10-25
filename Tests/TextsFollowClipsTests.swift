import XCTest

/// 4.1.5 · Testi e sottotitoli che seguono tagli, velocità, spostamenti ed eliminazioni.
final class TextsFollowClipsTests: XCTestCase {
    private func clip(_ path: String, _ a: Double, _ b: Double) -> VPClip { VPClip(path: path, inPoint: a, outPoint: b) }
    private func text(_ s: Double, _ e: Double) -> VPText { var t = VPText(); t.text = "Ciao"; t.start = s; t.end = e; return t }

    func testTaglioAllInizio() {
        var old = VideoProject()
        old.clips = [clip("/a.mov", 0, 10), clip("/b.mov", 0, 10)]
        old.texts = [text(12, 14)]                     // sulla clip 2, a 2 s dal suo inizio
        var new = old
        new.clips[0].inPoint = 3                       // la clip 1 perde 3 secondi
        let t = VideoProject.retimeTexts(old.texts!, from: old, to: new)
        XCTAssertEqual(t.first?.start ?? -1, 9, accuracy: 0.01, "il sottotitolo arriva 3 secondi prima, insieme alla clip")
        XCTAssertEqual(t.first?.end ?? -1, 11, accuracy: 0.01)
    }

    func testVelocitaEliminazioneSpostamento() {
        var old = VideoProject()
        old.clips = [clip("/a.mov", 0, 10), clip("/b.mov", 0, 10)]
        old.texts = [text(2, 4), text(13, 15)]
        // Clip 1 a 2×: il testo dentro si stringe, quello dopo arriva prima
        var fast = old
        fast.clips[0].fx = VPEffects(speed: 2)
        let f = VideoProject.retimeTexts(old.texts!, from: old, to: fast)
        XCTAssertEqual(f[0].start, 1, accuracy: 0.01)
        XCTAssertEqual(f[1].start, 8, accuracy: 0.01)
        // Clip 1 eliminata: il suo testo se ne va, l'altro si sposta all'inizio
        var del = old
        del.clips.removeFirst()
        let d = VideoProject.retimeTexts(old.texts!, from: old, to: del)
        XCTAssertEqual(d.count, 1)
        XCTAssertEqual(d[0].start, 3, accuracy: 0.01)
        // Clip scambiate: ogni testo resta sulla sua clip
        var sw = old
        sw.clips.swapAt(0, 1)
        let s = VideoProject.retimeTexts(old.texts!, from: old, to: sw)
        XCTAssertEqual(s[0].start, 12, accuracy: 0.01)
        XCTAssertEqual(s[1].start, 3, accuracy: 0.01)
    }

    func testDivisioneNonSpostaNiente() {
        var old = VideoProject()
        old.clips = [clip("/a.mov", 0, 10)]
        old.texts = [text(6, 8)]
        var split = old
        split.clips = [clip("/a.mov", 0, 5), clip("/a.mov", 5, 10)]
        let t = VideoProject.retimeTexts(old.texts!, from: old, to: split)
        XCTAssertEqual(t[0].start, 6, accuracy: 0.01, "dividere una clip non sposta i testi")
    }

    @MainActor
    func testFollowClipsSoloSeITestiNonCambiano() {
        var before = VideoProject()
        before.clips = [clip("/a.mov", 0, 10), clip("/b.mov", 0, 10)]
        before.texts = [text(12, 14)]
        var p = before
        p.clips[0].outPoint = 8
        VideoProjectStore.followClips(&p, from: before)
        XCTAssertEqual(p.texts?.first?.start ?? -1, 10, accuracy: 0.01)
        // Se la modifica ha già toccato i testi (es. «Togli i silenzi»), non si rifà
        var q = before
        q.clips[0].outPoint = 8
        q.texts = [text(1, 2)]
        VideoProjectStore.followClips(&q, from: before)
        XCTAssertEqual(q.texts?.first?.start ?? -1, 1, accuracy: 0.01)
    }
}
