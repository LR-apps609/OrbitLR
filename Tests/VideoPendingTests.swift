import XCTest

/// 5.1 · Salvataggio unico: il progetto si salva da solo; «Ripristina…» torna a com'era all'apertura, con ⌘Z.
@MainActor
final class VideoPendingTests: XCTestCase {
    private func folder() -> URL { Fixtures.dir.appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true) }

    /// Ogni modifica finisce sul disco da sola (entro un secondo): un crash non perde il lavoro.
    func testEveryChangeIsSavedByItself() async throws {
        let f = folder()
        let s = VideoProjectStore(folder: f)
        s.newProject(nil)
        let id = try XCTUnwrap(s.currentID)
        s.change(nil, "Aggiungi") { $0.clips = [VPClip(path: "/x/a.mp4", inPoint: 0, outPoint: 4)] }
        s.change(nil, "Testo") { var t = VPText(); t.text = "Ciao"; $0.texts = [t] }
        try await Task.sleep(nanoseconds: 1_500_000_000)
        let onDisk = try XCTUnwrap(VideoProjectLibrary.read(VideoProjectLibrary.url(for: id, in: f)))
        XCTAssertEqual(onDisk.texts?.first?.text, "Ciao", "senza Applica, il testo è già sul disco")
        XCTAssertNotNil(s.savedAt)
        s.closeProject(nil)
    }

    func testRevertToOpenedIsUndoable() async throws {
        let v = try await Fixtures.video(name: "pending.mp4", width: 320, height: 180, seconds: 4)
        let f = folder()
        let s = VideoProjectStore(folder: f)
        let um = UndoManager()
        um.groupsByEvent = false
        func step(_ f: () -> Void) { um.beginUndoGrouping(); f(); um.endUndoGrouping() }
        s.newProject(um)
        let id = try XCTUnwrap(s.currentID)
        step { s.change(um, "Aggiungi") { $0.clips = [VPClip(path: v.path, inPoint: 0, outPoint: 4)] } }
        s.closeProject(um)
        s.openProject(id, undo: um)
        XCTAssertFalse(s.changedSinceOpen)
        step { s.change(um, "Filtro") { var l = VPLook(); l.preset = "mono"; $0.look = l } }
        XCTAssertTrue(s.changedSinceOpen)
        step { s.revertToOpened(um) }
        XCTAssertNil(s.project.look, "Ripristina torna a com'era all'apertura")
        um.undo()
        XCTAssertEqual(s.project.look?.preset, "mono", "e ⌘Z riporta le modifiche")
        s.closeProject(um)
        s.openProject(id, undo: um)
        XCTAssertEqual(s.project.look?.preset, "mono", "chiudere tiene tutto")
        s.closeProject(um)
    }

    /// Clip con il file sparito: restano nel progetto anche dopo una modifica, e «Trova…» le rimette al loro posto.
    func testMissingClipsAreKeptAndFound() async throws {
        let a = try await Fixtures.video(name: "resta.mp4", width: 320, height: 180, seconds: 2)
        let gone = try await Fixtures.video(name: "sparita.mp4", width: 320, height: 180, seconds: 3)
        let f = folder()
        let s = VideoProjectStore(folder: f)
        s.newProject(nil)
        let id = try XCTUnwrap(s.currentID)
        s.change(nil, "Aggiungi") { $0.clips = [VPClip(path: a.path, inPoint: 0, outPoint: 2), VPClip(path: gone.path, inPoint: 0, outPoint: 3)] }
        s.closeProject(nil)
        let moved = Fixtures.dir.appendingPathComponent("altrove-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: moved, withIntermediateDirectories: true)
        let newPlace = moved.appendingPathComponent("sparita.mp4")
        try FileManager.default.moveItem(at: gone, to: newPlace)
        // Il segnalibro la ritroverebbe: lo si toglie, come un file su un disco scollegato
        var p = try XCTUnwrap(VideoProjectLibrary.read(VideoProjectLibrary.url(for: id, in: f)))
        p.clips[1].bookmark = nil
        p.clips[1].path = "/Volumes/Scollegato/sparita.mp4"
        VideoProjectLibrary.save(p, to: VideoProjectLibrary.url(for: id, in: f))

        s.openProject(id, undo: nil)
        XCTAssertEqual(s.project.clips.count, 1)
        XCTAssertEqual(s.project.missing?.count, 1)
        XCTAssertNotNil(s.notice)
        s.change(nil, "Velocità") { var e = VPEffects(); e.speed = 2; $0.clips[0].fx = e }
        s.closeProject(nil)
        let saved = try XCTUnwrap(VideoProjectLibrary.read(VideoProjectLibrary.url(for: id, in: f)))
        XCTAssertEqual(saved.missing?.count, 1, "dopo una modifica la clip mancante è ancora nel progetto")

        s.openProject(id, undo: nil)
        s.findMissing(in: [moved], undo: nil)
        XCTAssertEqual(s.project.clips.count, 2)
        XCTAssertNil(s.project.missing)
        XCTAssertEqual(s.project.clips[1].path, newPlace.path, "torna al suo posto, secondo")
        s.closeProject(nil)
    }

    /// Un progetto svuotato e chiuso va nel Cestino, non viene cancellato.
    func testEmptiedProjectGoesToTrash() throws {
        let f = folder()
        let s = VideoProjectStore(folder: f)
        s.newProject(nil)
        let id = try XCTUnwrap(s.currentID)
        s.change(nil, "Aggiungi") { $0.clips = [VPClip(path: "/x/a.mp4", inPoint: 0, outPoint: 4)] }
        s.saveNow()
        let url = VideoProjectLibrary.url(for: id, in: f)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        s.change(nil, "Togli") { $0.clips = [] }
        s.closeProject(nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "non resta tra i Progetti")
    }
}
