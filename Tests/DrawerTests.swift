import XCTest

/// 3.0 · Il Cassetto.
final class DrawerTests: XCTestCase {
    private func entry(_ outputs: [String], undone: Bool = false, minutesAgo: Double = 0) -> HistoryEntry {
        var e = HistoryEntry(date: Date().addingTimeInterval(-minutesAgo * 60), title: "t", action: "to:mp3", outputs: outputs)
        e.undone = undone
        return e
    }

    func testItemsNewestFirstUniqueExistingNotHidden() {
        let history = [
            entry(["/a/nuova.mp3", "/a/doppia.mp4"]),
            entry(["/a/annullata.png"], undone: true),
            entry(["/a/doppia.mp4", "/a/sparita.pdf", "/a/nascosta.jpg", "/a/vecchia.m4a"], minutesAgo: 5),
        ]
        let gone: Set<String> = ["/a/sparita.pdf"]
        let items = Drawer.items(from: history, hidden: ["/a/nascosta.jpg"], exists: { !gone.contains($0) })
        XCTAssertEqual(items.map(\.path), ["/a/nuova.mp3", "/a/doppia.mp4", "/a/vecchia.m4a"])
        XCTAssertEqual(Drawer.items(from: history, limit: 2, exists: { _ in true }).count, 2)
    }

    func testTargetsMakeSenseForEachKind() {
        XCTAssertEqual(Drawer.targets(for: URL(fileURLWithPath: "/x/canzone.mp3")).first, .music)
        XCTAssertTrue(Drawer.targets(for: URL(fileURLWithPath: "/x/canzone.mp3")).contains(.audio))
        XCTAssertEqual(Drawer.targets(for: URL(fileURLWithPath: "/x/clip.mp4")).first, .video)
        XCTAssertTrue(Drawer.targets(for: URL(fileURLWithPath: "/x/clip.mp4")).contains(.music), "un video può fare da musica")
        XCTAssertEqual(Drawer.targets(for: URL(fileURLWithPath: "/x/foto.heic")).first, .images)
        XCTAssertEqual(Drawer.targets(for: URL(fileURLWithPath: "/x/doc.pdf")).first, .files)
        for u in ["/x/a.mp3", "/x/b.png", "/x/c.docx", "/x/d.zzz"] {
            XCTAssertTrue(Drawer.targets(for: URL(fileURLWithPath: u)).contains(.finder))
        }
        XCTAssertEqual(DrawerTarget.forSidebar(.video), .video)
        XCTAssertEqual(DrawerTarget.forSidebar(.workspace), .convert)
        XCTAssertNil(DrawerTarget.forSidebar(.activity))
    }

    /// Mandare un file a una scheda lo carica lì e apre quella scheda.
    @MainActor
    func testSendOpensTheRightTab() async throws {
        let photo = try Fixtures.photo(name: "cassetto.png", width: 200, height: 150)
        let song = try Fixtures.wav(Fixtures.tone(seconds: 2), name: "cassetto.wav")
        let app = AppState.shared
        Drawer.send([photo], to: .images)
        XCTAssertEqual(app.selection, .images)
        XCTAssertTrue(app.imagesTab.files.contains(photo))
        Drawer.send([song], to: .audio)
        XCTAssertEqual(app.selection, .audio)
        XCTAssertEqual(app.audioTab.file?.path, song.path)
        Drawer.send([photo], to: .convert)
        XCTAssertEqual(app.selection, .workspace)
        XCTAssertTrue(app.workspace.allFiles.contains(photo))
        Drawer.send([URL(fileURLWithPath: "/non/esiste.png")], to: .images)       // file sparito: non succede niente
        XCTAssertEqual(app.selection, .workspace)
        app.imagesTab.clear(); app.workspace.load([])
    }
}
