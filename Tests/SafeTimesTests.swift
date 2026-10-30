import XCTest

/// 5.1 · Esportazione col nome del progetto, spazio su disco, tempo rimasto, ritorno dov'eri, ⌘Z nell'Audio.
@MainActor
final class SafeTimesTests: XCTestCase {
    private func folder() -> URL { Fixtures.dir.appendingPathComponent("times-\(UUID().uuidString)", isDirectory: true) }

    func testExportTakesTheProjectName() throws {
        var p = VideoProject()
        p.name = "Gita al lago"
        let snap = try VideoProjectExport.writeSnapshot(p, speech: [:], bytes: 1_000)
        defer { try? FileManager.default.removeItem(at: snap) }
        XCTAssertEqual(VideoProjectExport.outputBase(snapshot: snap, fallback: "clip (montaggio)"), "Gita al lago")

        p.name = "  "
        let empty = try VideoProjectExport.writeSnapshot(p, speech: [:])
        defer { try? FileManager.default.removeItem(at: empty) }
        XCTAssertEqual(VideoProjectExport.outputBase(snapshot: empty, fallback: "clip (montaggio)"), "clip (montaggio)",
                       "senza nome, come prima")

        p.name = "Estate 2026/agosto: mare"
        let slash = try VideoProjectExport.writeSnapshot(p, speech: [:])
        defer { try? FileManager.default.removeItem(at: slash) }
        XCTAssertEqual(VideoProjectExport.outputBase(snapshot: slash, fallback: "x"), "Estate 2026-agosto- mare",
                       "niente barre né due punti nel nome del file")
    }

    func testDiskSpaceIsCheckedBeforeStarting() throws {
        let p = VideoProject()
        let huge = try VideoProjectExport.writeSnapshot(p, speech: [:], bytes: Int64(1) << 60)
        defer { try? FileManager.default.removeItem(at: huge) }
        XCTAssertThrowsError(try VideoProjectExport.checkSpace(snapshot: huge, dir: Fixtures.dir), "un exabyte non c'è")
        let small = try VideoProjectExport.writeSnapshot(p, speech: [:], bytes: 1_000)
        defer { try? FileManager.default.removeItem(at: small) }
        XCTAssertNoThrow(try VideoProjectExport.checkSpace(snapshot: small, dir: Fixtures.dir))
    }

    func testRemainingTime() throws {
        let a = try XCTUnwrap(Catalog.action(id: "to:png", kind: .img))
        let j = Job(files: [URL(fileURLWithPath: "/tmp/a.jpg")], action: a, param: "")
        j.state = .running
        j.native = true
        j.startedAt = Date().addingTimeInterval(-60)
        j.progress = 0.01
        XCTAssertNil(j.remainingText, "troppo presto per dirlo")
        j.progress = 0.5
        XCTAssertEqual(j.remainingText, String(localized: "circa \(1) min"))
        j.progress = 0.99
        XCTAssertEqual(j.remainingText, String(localized: "meno di un minuto"))
        j.state = .done
        XCTAssertNil(j.remainingText)
    }

    /// Riaprendo un progetto tornano l'indicatore, lo zoom e lo strumento; il prossimo progetto parte pulito.
    func testViewStateComesBack() async throws {
        let v = try await Fixtures.video(name: "vista.mp4", width: 320, height: 180, seconds: 8)
        let f = folder()
        let s = VideoProjectStore(folder: f)
        s.newProject(nil)
        let id = try XCTUnwrap(s.currentID)
        s.change(nil, "Aggiungi") { $0.clips = [VPClip(path: v.path, inPoint: 0, outPoint: 8)] }
        s.clock.time = 3
        s.timelineZoom = 4
        s.lastTool = VideoEditTool.texts.rawValue
        s.closeProject(nil)
        XCTAssertEqual(s.timelineZoom, 1)
        XCTAssertEqual(s.lastTool, VideoEditTool.clip.rawValue)
        s.openProject(id, undo: nil)
        XCTAssertEqual(s.timelineZoom, 4)
        XCTAssertEqual(s.lastTool, VideoEditTool.texts.rawValue)
        XCTAssertEqual(s.clock.time, 3, accuracy: 0.01)
        s.closeProject(nil)
    }

    /// «Inizio qui», «Fine qui» e i tempi scritti si annullano con ⌘Z (prima solo le maniglie).
    func testSelectionChangesAreUndoable() async throws {
        let w = try Fixtures.wav(Fixtures.tone(seconds: 4, level: 0.5), name: "annulla-selezione.wav")
        let t = TrimModel(url: w, isVideo: false, defaultLength: nil)
        for _ in 0..<200 where t.loading { try await Task.sleep(nanoseconds: 50_000_000) }
        let um = UndoManager()
        um.groupsByEvent = false
        t.undoTarget = um
        let before = (t.start, t.end)
        t.playhead = 1.5
        um.beginUndoGrouping(); t.markIn(); um.endUndoGrouping()
        XCTAssertEqual(t.start, 1.5, accuracy: 0.001)
        um.beginUndoGrouping(); t.undoable("Fine") { t.setEnd(3.25) }; um.endUndoGrouping()
        XCTAssertEqual(t.end, 3.25, accuracy: 0.001)
        um.undo()
        XCTAssertEqual(t.end, before.1, accuracy: 0.001)
        um.undo()
        XCTAssertEqual(t.start, before.0, accuracy: 0.001)
    }

    func testTypedTimesWithMilliseconds() {
        XCTAssertEqual(parseTime("1:02,345") ?? -1, 62.345, accuracy: 0.0001)
        XCTAssertEqual(formatTimeMs(62.345), "1:02,345")
    }

    /// I testi nuovi della 5.1 hanno l'inglese.
    func testNewTextsAreTranslated() throws {
        let url = Bundle(for: SafeTimesTests.self).url(forResource: "Localizable", withExtension: "xcstrings")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("Localizable.xcstrings non trovato") }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        for k in ["meno di un minuto", "circa %lld min", "Scegli prima una clip nella sequenza.", "Porta l’indicatore sopra una clip.",
                  "Nel Finder non c’è niente di selezionato.", "macOS non ha permesso di aprire OrbitLR all’accesso.",
                  "Il codice è scaduto.", "Rigenera", "Apri…", "Aiuto di OrbitLR", "Segnala un problema…", "Nuovo progetto video",
                  "Un PDF ha modifiche non salvate", "Esci senza salvare",
                  "OrbitLR si è chiusa all’improvviso. «%@» è com’era alle %@."] {
            let e = (strings[k] as? [String: Any])?["localizations"] as? [String: Any]
            XCTAssertNotNil(e?["en"], "manca l’inglese per «\(k)»")
        }
    }
}
