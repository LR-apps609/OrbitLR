import XCTest

/// 2.7.3 · Progetti video: salvataggio, elenco, rinomina, duplica, elimina, passaggio dalla 2.7.2.
final class VideoProjectsLibraryTests: XCTestCase {
    private func folder() -> URL {
        let f = Fixtures.dir.appendingPathComponent("lib-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        return f
    }

    private func project(_ name: String, clips: Int = 1) -> VideoProject {
        var p = VideoProject()
        p.name = name
        p.clips = (0..<clips).map { _ in VPClip(path: "/tmp/non-esiste.mp4", inPoint: 0, outPoint: 3) }
        return p
    }

    func testSaveListAndEmptyNotKept() {
        let f = folder()
        let a = UUID(), b = UUID(), empty = UUID()
        VideoProjectLibrary.save(project("Gita", clips: 2), to: VideoProjectLibrary.url(for: a, in: f))
        Thread.sleep(forTimeInterval: 1.1)                       // date di modifica diverse
        VideoProjectLibrary.save(project("Compleanno"), to: VideoProjectLibrary.url(for: b, in: f))
        VideoProjectLibrary.save(VideoProject(), to: VideoProjectLibrary.url(for: empty, in: f))
        let list = VideoProjectLibrary.list(in: f)
        XCTAssertEqual(list.map { $0.name }, ["Compleanno", "Gita"], "dal più recente, il vuoto non c'è")
        XCTAssertEqual(list.last?.clipCount, 2)
        XCTAssertEqual(list.last?.duration ?? 0, 6, accuracy: 0.01)
        XCTAssertNil(list.first?.coverPath, "file mancante: nessuna copertina, nessun errore")
    }

    func testRenameDuplicateTrash() {
        let f = folder()
        let id = UUID()
        VideoProjectLibrary.save(project("Mare"), to: VideoProjectLibrary.url(for: id, in: f))
        VideoProjectLibrary.rename(id, to: "Mare 2026", in: f)
        XCTAssertEqual(VideoProjectLibrary.list(in: f).map { $0.name }, ["Mare 2026"])
        let copy = VideoProjectLibrary.duplicate(id, in: f, existing: ["Mare 2026"])
        XCTAssertNotNil(copy)
        XCTAssertEqual(Set(VideoProjectLibrary.list(in: f).map { $0.name }), ["Mare 2026", "Mare 2026 copia"])
        let copy2 = VideoProjectLibrary.duplicate(id, in: f, existing: VideoProjectLibrary.list(in: f).map { $0.name })
        XCTAssertNotNil(copy2)
        XCTAssertTrue(VideoProjectLibrary.list(in: f).map { $0.name }.contains("Mare 2026 copia 1"), "nomi mai doppi")
        VideoProjectLibrary.trash(id, in: f)
        XCTAssertFalse(VideoProjectLibrary.list(in: f).contains { $0.id == id })
        XCTAssertEqual(VideoProjectLibrary.list(in: f).count, 2)
    }

    func testUniqueName() {
        XCTAssertEqual(VideoProjectLibrary.uniqueName(existing: []), "Progetto 1")
        XCTAssertEqual(VideoProjectLibrary.uniqueName(existing: ["Progetto 1", "Progetto 3"]), "Progetto 2")
    }

    func testMigrateLegacySingleProject() throws {
        let f = folder()
        let old = f.deletingLastPathComponent().appendingPathComponent("vecchio-\(UUID().uuidString).json")
        var p = project("x")
        p.name = nil
        try JSONEncoder().encode(p).write(to: old)
        let id = VideoProjectLibrary.migrateLegacy(from: old, to: f)
        XCTAssertNotNil(id)
        XCTAssertEqual(VideoProjectLibrary.list(in: f).map { $0.name }, ["Progetto 1"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: old.path), "il vecchio file non resta al suo posto")
        XCTAssertNil(VideoProjectLibrary.migrateLegacy(from: old, to: f), "una volta sola")
    }

    func testOldProjectFileStillDecodes() throws {
        // Un progetto salvato dalla 2.7.2 non ha «name»: deve aprirsi lo stesso
        let json = #"{"clips":[],"originalVolume":1,"originalMuted":false,"aspect":"orig","follow":true,"resolution":1080,"fps":30}"#
        let p = try JSONDecoder().decode(VideoProject.self, from: Data(json.utf8))
        XCTAssertNil(p.name)
        XCTAssertEqual(VideoProjectLibrary.displayName(p), "Progetto senza nome")
    }

    @MainActor
    func testOpenCloseKeepsWorkAndClearsUndo() async throws {
        let v = try await Fixtures.video(name: "progetti.mp4", width: 320, height: 180, seconds: 3)
        let f = folder()
        let s = VideoProjectStore(folder: f)
        let um = UndoManager()
        um.groupsByEvent = false
        XCTAssertNil(s.currentID, "all'avvio si vede la schermata Progetti")

        s.newProject(um)
        let id = try XCTUnwrap(s.currentID)
        um.beginUndoGrouping()
        s.change(um, "Aggiungi") { $0.clips = [VPClip(path: v.path, inPoint: 0, outPoint: 2)] }
        um.endUndoGrouping()
        XCTAssertTrue(um.canUndo)

        s.closeProject(um)
        XCTAssertNil(s.currentID)
        XCTAssertFalse(um.canUndo, "⌘Z non deve toccare un progetto chiuso")
        XCTAssertEqual(s.library.map { $0.id }, [id], "chiuso ma salvato")

        s.openProject(id, undo: um)
        XCTAssertEqual(s.currentID, id)
        XCTAssertEqual(s.project.clips.count, 1)
        XCTAssertEqual(s.project.duration, 2, accuracy: 0.01)

        // Un progetto nuovo lasciato vuoto non finisce tra i Progetti
        s.newProject(um)
        s.closeProject(um)
        XCTAssertEqual(s.library.count, 1)

        s.duplicateProject(id)
        XCTAssertEqual(s.library.count, 2)
        s.deleteProject(id, undo: um)
        XCTAssertEqual(s.library.count, 1)
        XCTAssertNotEqual(s.library.first?.id, id)
    }
}
