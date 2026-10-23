import XCTest

/// 2.8.4 · Audio: recenti e ⌘Z sulla selezione.
final class AudioProjectTests: XCTestCase {
    func testRecentsOrderAndLimit() {
        let a = URL(fileURLWithPath: "/tmp/a.mp3"), b = URL(fileURLWithPath: "/tmp/b.mp3")
        var list: [URL] = []
        list = MediaTabModel.pushRecent(a, into: list, max: 3)
        list = MediaTabModel.pushRecent(b, into: list, max: 3)
        list = MediaTabModel.pushRecent(a, into: list, max: 3)
        XCTAssertEqual(list, [a, b], "l'ultimo aperto in cima, niente doppioni")
        for i in 0..<5 { list = MediaTabModel.pushRecent(URL(fileURLWithPath: "/tmp/\(i).mp3"), into: list, max: 3) }
        XCTAssertEqual(list.count, 3)
    }

    @MainActor
    func testSelectionUndo() async throws {
        let w = try Fixtures.wav(Fixtures.tone(seconds: 6), name: "selezione.wav")
        let t = TrimModel(url: w, isVideo: false, defaultLength: nil)
        for _ in 0..<100 where t.duration == 0 { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertGreaterThan(t.duration, 5)
        let um = UndoManager()
        um.groupsByEvent = false
        let before = (t.start, t.end)
        um.beginUndoGrouping()
        t.setStart(2)
        t.setEnd(4)
        t.commitSelection(from: before, undo: um)
        um.endUndoGrouping()
        XCTAssertEqual(t.start, 2, accuracy: 0.01)
        um.undo()
        XCTAssertEqual(t.start, before.0, accuracy: 0.01)
        XCTAssertEqual(t.end, before.1, accuracy: 0.01)
        um.redo()
        XCTAssertEqual(t.end, 4, accuracy: 0.01)
    }
}
