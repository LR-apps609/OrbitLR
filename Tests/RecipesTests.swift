import XCTest

/// 3.2 · Ricette: OrbitLR riconosce i passi fatti in fila e li rifà con un clic.
final class RecipesTests: XCTestCase {
    private func entry(_ id: String, _ title: String, in input: String, out: String, param: String = "", ago: Double, kind: String = "audio") -> HistoryEntry {
        HistoryEntry(date: Date().addingTimeInterval(-ago), title: "x", action: title, outputs: [out], kind: kind,
                     actionId: id, param: param, inputs: [input])
    }

    func testRiconosceIPassiInFila() {
        let a = entry("to:mp3", "Converti in MP3", in: "/v/canzone.wav", out: "/v/canzone.mp3", ago: 300)
        let b = entry("cut", "Taglia", in: "/v/canzone.mp3", out: "/v/canzone (taglio).mp3", param: "10.000|40.000", ago: 200)
        let c = entry("ringtone", "Suoneria iPhone", in: "/v/canzone (taglio).mp3", out: "/v/canzone.m4r", param: "0|30|1|1", ago: 100)
        let other = entry("normalize", "Volume uniforme", in: "/v/altro.wav", out: "/v/altro (volume).wav", ago: 50)
        let history = [other, c, b, a]           // la cronologia è dalla più recente
        let chain = RecipeStore.chain(endingAt: c, in: history)
        XCTAssertEqual(chain.map { $0.actionId }, ["to:mp3", "cut", "ringtone"])
        let r = RecipeStore.recipe(from: chain)
        XCTAssertEqual(r?.summary, "MP3 → Taglia → Suoneria iPhone")
        XCTAssertEqual(r?.steps[1].param, "10.000|40.000", "le opzioni restano quelle usate")
        XCTAssertTrue(RecipeStore.chain(endingAt: other, in: history).isEmpty, "un passo solo non è una ricetta")
    }

    func testVociVecchieSenzaDatiNonRompono() {
        let old = HistoryEntry(date: Date(), title: "x", action: "Converti in MP3", outputs: ["/a.mp3"])
        XCTAssertTrue(RecipeStore.chain(endingAt: old, in: [old]).isEmpty)
        // Le voci salvate prima della 3.2 si leggono ancora
        let json = #"[{"id":"2B0C8A4E-5D1F-4C3B-9E2A-7F6D5C4B3A21","date":0,"title":"x","action":"y","outputs":["/a"],"undone":false}]"#
        XCTAssertNotNil(try? JSONDecoder().decode([HistoryEntry].self, from: Data(json.utf8)))
    }

    func testSalvaNelMenuEPoiTogli() {
        let file = Fixtures.dir.appendingPathComponent("ricette-\(UUID().uuidString).json")
        let store = RecipeStore(url: file)
        let r = Recipe(name: "Suoneria veloce", kind: "audio", steps: [RecipeStep(actionId: "to:m4a", param: "", title: "M4A"),
                                                                      RecipeStep(actionId: "ringtone", param: "0|30|1|1", title: "Suoneria")])
        store.add(r)
        store.add(r)
        XCTAssertEqual(store.recipes.count, 1, "la stessa ricetta una volta sola")
        let menu = store.merged([Catalog.conv("mp3", kind: .audio)], kind: .audio)
        XCTAssertEqual(menu.count, 2)
        XCTAssertEqual(store.recipe(for: menu[1])?.id, r.id)
        XCTAssertEqual(RecipeStore(url: file).recipes.count, 1, "resta salvata")
        store.delete(r)
        XCTAssertTrue(store.recipes.isEmpty)
    }

    /// Il secondo passo parte dal risultato del primo (senza aspettare il motore: il passo 1 «finisce» a mano).
    func testIlPassoDopoParteDalRisultato() throws {
        let src = try Fixtures.wav(Fixtures.tone(seconds: 1, freq: 440), name: "ricetta-\(UUID().uuidString).wav")
        let made = try Fixtures.wav(Fixtures.tone(seconds: 1, freq: 330), name: "ricetta-fatta-\(UUID().uuidString).wav")
        let store = RecipeStore(url: Fixtures.dir.appendingPathComponent("ricette-\(UUID().uuidString).json"))
        let r = Recipe(name: "Prova", kind: "audio", steps: [RecipeStep(actionId: "to:m4a", param: "", title: "M4A"),
                                                            RecipeStep(actionId: "normalize", param: "", title: "Volume uniforme")])
        let first = try XCTUnwrap(store.run(r, files: [src]))
        defer { QueueStore.shared.cancel(first) }
        XCTAssertEqual(first.action.id, "to:m4a")
        let next = try XCTUnwrap(first.then, "il primo passo deve sapere cosa viene dopo")
        let done = Job(files: [src], action: first.action, param: "")
        done.outputs = [made]
        next(done)
        let second = try XCTUnwrap(QueueStore.shared.jobs.first { $0.action.id == "normalize" && $0.files == [made] })
        QueueStore.shared.cancel(second)
        XCTAssertNil(second.then, "l'ultimo passo non ha seguito")
    }
}
