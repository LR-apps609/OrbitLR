import XCTest

/// 2.9.10 · Le modifiche del Video si vedono subito e diventano definitive solo con «Applica».
@MainActor
final class VideoPendingTests: XCTestCase {
    private func folder() -> URL { Fixtures.dir.appendingPathComponent("pending-\(UUID().uuidString)", isDirectory: true) }

    func testApplyDiscardAndClose() async throws {
        let v = try await Fixtures.video(name: "pending.mp4", width: 320, height: 180, seconds: 4)
        let f = folder()
        let s = VideoProjectStore(folder: f)
        let um = UndoManager()
        um.groupsByEvent = false
        s.newProject(um)
        let id = try XCTUnwrap(s.currentID)
        XCTAssertFalse(s.hasPending)

        s.change(um, "Aggiungi") { $0.clips = [VPClip(path: v.path, inPoint: 0, outPoint: 4)] }
        XCTAssertTrue(s.hasPending, "si vede ma non è ancora confermata")
        s.applyChanges()
        XCTAssertFalse(s.hasPending)
        XCTAssertEqual(s.saved.clips.count, 1)

        s.change(um, "Filtro") { var l = VPLook(); l.preset = "mono"; $0.look = l }
        XCTAssertTrue(s.hasPending)
        s.discardChanges(um)
        XCTAssertFalse(s.hasPending)
        XCTAssertNil(s.project.look, "Annulla torna all'ultima versione applicata")
        XCTAssertFalse(um.canUndo, "dopo Annulla non resta niente da annullare")

        // Chiudere tiene quello che si vede (la finestra chiede prima)
        s.change(um, "Velocità") { var e = VPEffects(); e.speed = 2; $0.clips[0].fx = e }
        s.closeProject(um)
        s.openProject(id, undo: um)
        XCTAssertEqual(s.project.clips.first?.speed ?? 0, 2, accuracy: 0.001)
        s.closeProject(um)
    }

    func testNothingIsSavedUntilApplied() throws {
        let f = folder()
        let s = VideoProjectStore(folder: f)
        s.newProject(nil)
        s.change(nil, "Aggiungi") { $0.clips = [VPClip(path: "/x/a.mp4", inPoint: 0, outPoint: 4)] }
        s.applyChanges()
        s.saveNow()
        s.change(nil, "Testo") { var t = VPText(); t.text = "Ciao"; $0.texts = [t] }
        s.saveNow()                                  // salva solo la versione confermata
        let id = try XCTUnwrap(s.currentID)
        let onDisk = try XCTUnwrap(VideoProjectLibrary.read(VideoProjectLibrary.url(for: id, in: f)))
        XCTAssertNil(onDisk.texts, "il testo non applicato non è sul disco")
        s.discardChanges(nil)
        s.closeProject(nil)
    }
}
