import XCTest

/// 5.1 · Al sicuro: le eliminazioni si annullano, i progetti audio tengono le opzioni e non spariscono da soli.
final class SafeDeleteTests: XCTestCase {
    private func folder(_ name: String) -> URL {
        Fixtures.dir.appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    }

    // MARK: Riga «Annulla» e ⌘Z

    func testCmdZRimetteUnaVoltaSola() {
        let toast = UndoToast()
        let um = UndoManager()
        um.groupsByEvent = false
        var restored = 0
        um.beginUndoGrouping()
        toast.post("Eliminata «Prova».", at: .shortcuts, undoManager: um) { restored += 1 }
        um.endUndoGrouping()
        XCTAssertEqual(toast.item?.place, .shortcuts, "la riga compare dove hai eliminato")
        XCTAssertTrue(um.canUndo)
        um.undo()
        XCTAssertEqual(restored, 1)
        XCTAssertNil(toast.item, "dopo ⌘Z la riga sparisce")
        if let id = toast.item?.id { toast.undo(id) }
        XCTAssertEqual(restored, 1, "mai due volte")
    }

    func testAnnullaNellaRigaTogliAncheCmdZ() {
        let toast = UndoToast()
        let um = UndoManager()
        um.groupsByEvent = false
        var restored = 0
        um.beginUndoGrouping()
        toast.post("Eliminata «Prova».", at: .drawer, undoManager: um) { restored += 1 }
        um.endUndoGrouping()
        let id = toast.item?.id
        XCTAssertNotNil(id)
        if let id {
            XCTAssertTrue(toast.canRestore(id))
            toast.undo(id)
            XCTAssertFalse(toast.canRestore(id))
            toast.undo(id)
        }
        if um.canUndo { um.undo() }
        XCTAssertEqual(restored, 1, "il ⌘Z di un elemento già rimesso non lo rimette di nuovo")
    }

    // MARK: Ripristino degli elementi

    func testRicettaEliminataTornaAlSuoPosto() {
        let file = Fixtures.dir.appendingPathComponent("ricette-\(UUID().uuidString).json")
        let store = RecipeStore(url: file)
        func recipe(_ n: String, _ id: String) -> Recipe {
            Recipe(name: n, kind: "audio", steps: [RecipeStep(actionId: "to:m4a", param: "", title: "M4A"),
                                                   RecipeStep(actionId: id, param: "", title: n)])
        }
        let a = recipe("A", "normalize"), b = recipe("B", "voiceclean"), c = recipe("C", "silence")
        store.add(a); store.add(b); store.add(c)              // in cima l'ultima: C, B, A
        XCTAssertEqual(store.recipes.map(\.name), ["C", "B", "A"])
        store.delete(b)
        store.restore(b, at: 1)
        store.restore(b, at: 1)
        XCTAssertEqual(store.recipes.map(\.name), ["C", "B", "A"], "torna al suo posto, una volta sola")
        XCTAssertEqual(RecipeStore(url: file).recipes.map(\.name), ["C", "B", "A"], "ed è salvata")
    }

    func testVoceDellaCronologiaTorna() {
        let store = QueueStore.shared
        let e = HistoryEntry(date: Date(), title: "prova-5.1.jpg", action: "Converti in JPG", outputs: ["/tmp/prova-5.1.jpg"])
        store.history.insert(e, at: 0)
        store.forget(e)
        XCTAssertFalse(store.history.contains { $0.id == e.id })
        store.restore(e, at: 0)
        store.restore(e, at: 0)
        XCTAssertEqual(store.history.filter { $0.id == e.id }.count, 1)
        XCTAssertEqual(store.history.first?.id, e.id)
        store.forget(e)
    }

    func testFileRimessoNelCassetto() {
        let u = URL(fileURLWithPath: "/tmp/cassetto-\(UUID().uuidString).jpg")
        Drawer.shared.hide(u)
        XCTAssertTrue(Drawer.shared.hidden.contains(u.path))
        Drawer.shared.unhide(u)
        XCTAssertFalse(Drawer.shared.hidden.contains(u.path))
    }

    func testRegolaCheUsaLAzione() {
        let p = Preset(name: "Instagram", kind: Kind.img.rawValue, actionId: "resize", param: "1080")
        let uses = WatchRule(folder: "/tmp/Download", kind: Kind.img.rawValue, actionId: "preset:" + p.id.uuidString, param: "")
        let other = WatchRule(folder: "/tmp/Altro", kind: Kind.img.rawValue, actionId: "to:jpg", param: "")
        XCTAssertEqual(PresetStore.rules(using: p, in: [uses, other]).map(\.folder), ["/tmp/Download"])
    }

    // MARK: Originali nel Cestino

    func testOriginaliDaCestinare() throws {
        let dir = folder("originali")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        func make(_ n: String) throws -> URL {
            let u = dir.appendingPathComponent(n)
            try Data([1, 2, 3]).write(to: u)
            return u
        }
        let a = try make("a.png"), b = try make("b.png"), aOut = try make("a.jpg")
        let job = Job(files: [a, b], action: Catalog.conv("jpg", kind: .img), param: "")
        job.outputs = [aOut]
        XCTAssertEqual(QueueStore.originalsToTrash(job), [a], "solo l'originale che ha davvero il suo risultato")
        let v = try make("film.mp4"), vOut = try make("film.mp3")
        let audio = Job(files: [v], action: Catalog.conv("mp3", kind: .video), param: "")
        audio.outputs = [vOut]
        XCTAssertTrue(QueueStore.originalsToTrash(audio).isEmpty, "l'audio di un video non sostituisce il video")
        XCTAssertEqual(QueueStore.trashAskLimit, 20)
    }

    // MARK: Progetti audio

    func testProgettoAudioVecchioSiApre() throws {
        let f = folder("audio-vecchi")
        try FileManager.default.createDirectory(at: f, withIntermediateDirectories: true)
        let id = UUID()
        // Un progetto salvato prima della 5.1: senza opzioni
        let json = """
        {"id":"\(id.uuidString)","name":"Vocale","paths":["/tmp/vocale.m4a"],"bookmarks":[],"tool":"cut","start":1,"end":4,"modified":"2026-10-01T10:00:00Z"}
        """
        try Data(json.utf8).write(to: AudioProjectLibrary.url(for: id, in: f))
        let list = AudioProjectLibrary.list(in: f)
        XCTAssertEqual(list.map(\.name), ["Vocale"])
        XCTAssertNil(list.first?.options)
        XCTAssertEqual(list.first?.end, 4)
    }

    func testOpzioniSalvateERitrovate() throws {
        let f = folder("audio-opzioni")
        var o = AudioOptions()
        o.ttsText = "Ciao, questa è una prova."
        o.voiceId = "com.apple.voice.premium.it-IT.Federica"
        o.rate = 0.42
        o.ringLength = 20
        o.fade = false
        o.normalize = false
        o.speed = "0.75"
        let p = AudioProject(name: "Suoneria", paths: ["/tmp/canzone.mp3"], tool: "tts", start: 10, end: 30, options: o)
        AudioProjectLibrary.save(p, in: f)
        let back = try XCTUnwrap(AudioProjectLibrary.read(AudioProjectLibrary.url(for: p.id, in: f)))
        XCTAssertEqual(back.options, o)
        XCTAssertEqual(back.tool, "tts")
        // Opzioni scritte solo in parte (versioni diverse): i campi mancanti prendono il valore di partenza
        let partial = try JSONDecoder().decode(AudioOptions.self, from: Data(#"{"ttsText":"Ciao"}"#.utf8))
        XCTAssertEqual(partial.ttsText, "Ciao")
        XCTAssertEqual(partial.ringLength, 30)
        XCTAssertTrue(partial.fade)
        XCTAssertEqual(partial.speed, "1.25")
    }

    func testNessunProgettoNelCestinoDaSolo() {
        let f = folder("audio-tanti")
        for i in 0..<45 {
            AudioProjectLibrary.save(AudioProject(name: "P\(i)", paths: ["/tmp/\(i).m4a"], tool: "cut", start: 0, end: 1), in: f)
        }
        XCTAssertEqual(AudioProjectLibrary.list(in: f).count, 45)
        XCTAssertEqual(AudioProjectLibrary.list(in: f).count, 45, "anche alla seconda lettura")
        let files = (try? FileManager.default.contentsOfDirectory(atPath: f.path)) ?? []
        XCTAssertEqual(files.filter { $0.hasSuffix(".json") }.count, 45, "nessun file va nel Cestino")
    }
}
