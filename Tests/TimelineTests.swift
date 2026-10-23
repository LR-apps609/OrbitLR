import XCTest

/// 3.4.5 · Sequenza del montaggio: aggancio morbido ai bordi delle clip e all'indicatore.
final class TimelineTests: XCTestCase {
    func testAggancio() {
        var p = VideoProject()
        p.clips = [VPClip(path: "/a.mp4", inPoint: 0, outPoint: 4), VPClip(path: "/b.mp4", inPoint: 0, outPoint: 3)]
        let marks = Snap.marks(p, playhead: 5.5)
        XCTAssertTrue(marks.contains(4), "fine della prima clip")
        XCTAssertTrue(marks.contains(5.5), "indicatore")
        Snap.reset()
        // 100 punti al secondo: 4,04 s è a 4 punti dal bordo → si aggancia
        XCTAssertEqual(Snap.to(4.04, marks, pps: 100, id: "x"), 4)
        // 4,2 s è a 20 punti: resta dov'è
        XCTAssertEqual(Snap.to(4.2, marks, pps: 100, id: "x"), 4.2)
        // Con poco zoom (10 punti al secondo) aggancia anche da più lontano in secondi
        XCTAssertEqual(Snap.to(4.5, marks, pps: 10, id: "y"), 4)
        Snap.reset()
    }
}
