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

/// 2.8.5 · Progetti audio: si salvano da soli e si riprendono con strumento e selezione.
final class AudioProjectsLibraryTests: XCTestCase {
    private func folder() -> URL { Fixtures.dir.appendingPathComponent("audio-progetti-\(UUID().uuidString)", isDirectory: true) }

    func testSaveListRenameDuplicateTrash() {
        let f = folder()
        let p = AudioProject(name: "Vocale", paths: ["/tmp/non-esiste.m4a"], tool: "cut", start: 1, end: 4)
        AudioProjectLibrary.save(p, in: f)
        XCTAssertEqual(AudioProjectLibrary.list(in: f).map { $0.name }, ["Vocale"])
        AudioProjectLibrary.rename(p.id, to: "Lezione", in: f)
        XCTAssertEqual(AudioProjectLibrary.list(in: f).first?.name, "Lezione")
        let copy = AudioProjectLibrary.duplicate(p.id, in: f)
        XCTAssertNotNil(copy)
        XCTAssertEqual(AudioProjectLibrary.list(in: f).count, 2)
        AudioProjectLibrary.trash(p.id, in: f)
        XCTAssertEqual(AudioProjectLibrary.list(in: f).map { $0.name }, ["Lezione copia"])
    }

    func testRelinkMissingFile() throws {
        var gone = AudioProject(name: "x", paths: ["/tmp/non-esiste-\(UUID().uuidString).m4a"], tool: "cut", start: 0, end: 1)
        XCTAssertFalse(AudioProjectLibrary.relink(&gone))
        let w = try Fixtures.wav(Fixtures.tone(seconds: 1), name: "relink-audio.wav")
        var here = AudioProject(name: "y", paths: [w.path], tool: "cut", start: 0, end: 1)
        XCTAssertTrue(AudioProjectLibrary.relink(&here))
    }

    @MainActor
    func testOpenSaveAndResume() async throws {
        let w = try Fixtures.wav(Fixtures.tone(seconds: 6), name: "progetto-audio.wav")
        let f = folder()
        let m = MediaTabModel(videoTab: false, projectsFolder: f)
        XCTAssertTrue(m.audioProjects.isEmpty)
        m.currentTool = "cut"
        m.load([w])
        XCTAssertEqual(m.audioProjects.count, 1, "aprire un file crea il progetto")
        let t = try XCTUnwrap(m.trim)
        for _ in 0..<100 where t.loading { try await Task.sleep(nanoseconds: 50_000_000) }
        t.setStart(1.5)
        t.setEnd(3.5)
        try await Task.sleep(nanoseconds: 1_500_000_000)          // pausa + salvataggio
        m.close()
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let p = try XCTUnwrap(m.audioProjects.first)
        XCTAssertEqual(p.start, 1.5, accuracy: 0.05)
        XCTAssertEqual(p.end, 3.5, accuracy: 0.05)
        XCTAssertEqual(p.tool, "cut")

        m.currentTool = "ringtone"
        m.openProject(p)
        XCTAssertEqual(m.restoredTool, "cut", "torna lo strumento che usavi")
        XCTAssertEqual(m.file?.path, w.path)
        let t2 = try XCTUnwrap(m.trim)
        for _ in 0..<100 where t2.loading { try await Task.sleep(nanoseconds: 50_000_000) }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(t2.start, 1.5, accuracy: 0.05, "torna la selezione")
        XCTAssertEqual(t2.end, 3.5, accuracy: 0.05)
        XCTAssertEqual(m.audioProjects.count, 1, "riprendere non crea un doppione")
    }
}
