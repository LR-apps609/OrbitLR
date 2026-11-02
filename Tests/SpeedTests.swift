import XCTest
import Combine

/// 6.0.1 · Passata sulle prestazioni: meno ridisegni e niente lavori doppi, con gli stessi risultati.
@MainActor
final class SpeedTests: XCTestCase {
    /// La testina di Audio e Taglia cambia 33 volte al secondo: non deve ridisegnare onda e pulsanti.
    func testLaTestinaNonRidisegnaLOnda() async throws {
        let w = try Fixtures.wav(Fixtures.tone(seconds: 2, level: 0.5), name: "testina-\(UUID().uuidString).wav")
        let t = TrimModel(url: w, isVideo: false, defaultLength: nil)
        for _ in 0..<200 where t.loading { try await Task.sleep(nanoseconds: 50_000_000) }
        var modelChanges = 0, clockChanges = 0
        let a = t.objectWillChange.sink { _ in modelChanges += 1 }
        let b = t.clock.objectWillChange.sink { _ in clockChanges += 1 }
        for i in 0..<30 { t.playhead = Double(i) * 0.03 }
        XCTAssertEqual(modelChanges, 0, "la posizione non tocca il modello dell'onda")
        XCTAssertEqual(clockChanges, 30)
        XCTAssertEqual(t.playhead, 0.87, accuracy: 0.0001)
        a.cancel(); b.cancel()
    }

    /// Doppio clic sulla torta: la stessa scelta entro mezzo secondo conta una volta.
    func testDoppioClicSullaTorta() {
        let ws = Workspace()
        let g = UUID(), t0 = Date()
        XCTAssertFalse(ws.isRepeatPick("to:png", group: g, now: t0))
        XCTAssertTrue(ws.isRepeatPick("to:png", group: g, now: t0.addingTimeInterval(0.2)), "doppio clic")
        XCTAssertFalse(ws.isRepeatPick("to:jpg", group: g, now: t0.addingTimeInterval(0.3)), "un'altra scelta passa")
        XCTAssertFalse(ws.isRepeatPick("to:jpg", group: g, now: t0.addingTimeInterval(1.0)), "dopo mezzo secondo è una scelta nuova")
        XCTAssertFalse(ws.isRepeatPick("to:jpg", group: UUID(), now: t0.addingTimeInterval(1.1)), "altro gruppo")
    }

    /// Togliendo un gruppo, quello che resta tiene peso e miniatura già calcolati (nessuna lettura in più).
    func testTogliereUnGruppoNonRifaGliAltri() throws {
        let photo = try Fixtures.photo(name: "resta-\(UUID().uuidString).jpg")
        let pdf = try Fixtures.wav(Fixtures.tone(seconds: 1), name: "via-\(UUID().uuidString).wav")
        let ws = Workspace()
        ws.load([photo, pdf])
        let img = try XCTUnwrap(ws.groups.first { $0.kind == .img })
        let other = try XCTUnwrap(ws.groups.first { $0.kind != .img })
        XCTAssertEqual(img.builtFiles, [photo])
        let subtitle = img.pie.subtitle
        img.pie.subtitle = "segno"
        ws.removeGroup(other)
        XCTAssertEqual(img.pie.subtitle, "segno", "il gruppo rimasto non è stato ricalcolato")
        img.pie.subtitle = subtitle
        img.files.append(photo)
        ws.remove(photo, from: img)
        XCTAssertEqual(img.builtFiles, img.files)
    }

    /// La ricerca nella torta e nell'Aiuto dà gli stessi risultati di prima (ora calcolati una volta per tasto).
    func testRicercheUguali() {
        let m = PieModel()
        let acts = Catalog.pieActions(for: .img, exts: ["jpg"], mergeable: 1, count: 1)
        m.setup(actions: acts)
        func naive(_ q: String) -> [String] {
            let words = PieModel.fold(q.trimmingCharacters(in: .whitespaces)).split(separator: " ").map(String.init)
            guard !words.isEmpty else { return [] }
            return acts.filter { a in
                a.id != Action.more.id && words.allSatisfy { PieModel.fold(a.title + " " + a.short + " " + a.hint + " " + a.id.replacingOccurrences(of: "to:", with: "")).contains($0) }
            }.map { $0.id }
        }
        for q in ["", "png", "PNG", "ridim", "qualita", "zzz", "pdf j"] {
            m.query = q
            XCTAssertEqual(m.results.map { $0.id }, naive(q), "torta: «\(q)»")
            for a in acts where a.id != Action.more.id { XCTAssertEqual(m.isResult(a.id), naive(q).contains(a.id)) }
        }
        for q in ["", "aggiorn", "ANNULLA", "zzz"] {
            let words = FAQ.fold(q).split(separator: " ").map(String.init)
            let expected = words.isEmpty ? FAQ.all.map { $0.id } : FAQ.all.filter { f in words.allSatisfy { FAQ.fold(f.question + " " + f.answer + " " + f.section).contains($0) } }.map { $0.id }
            XCTAssertEqual(FAQ.search(q).map { $0.id }, expected, "Aiuto: «\(q)»")
        }
    }

    /// Le stime in parallelo danno gli stessi numeri di quelle una dopo l'altra, nello stesso ordine.
    func testStimeInParalleloUguali() async throws {
        let photos = try (0..<3).map { try Fixtures.photo(name: "stima-\($0)-\(UUID().uuidString).jpg", width: 900, height: 600) }
        let acts = Catalog.pieActions(for: .img, exts: ["jpg"], mergeable: 1, count: 3)
        let e = await SizeEstimate.estimates(actions: acts, files: photos, kind: .img)
        for t in ["png", "heic", "jpg"] where acts.contains(where: { $0.id == "to:" + t }) {
            let seq = photos.compactMap { SizeEstimate.imageBytes($0, to: t) }.reduce(Int64(0), +)
            if seq > 0 { XCTAssertEqual(e["to:" + t], seq, t) }
        }
        let r = await SizeEstimate.parallel(["a", "b", "c", "d", "e"], limit: 2) { s in s == "c" ? nil : Int64(s.unicodeScalars.first!.value) }
        XCTAssertEqual(r.map { $0.0 }, ["a", "b", "d", "e"], "ordine conservato, i falliti fuori")
        XCTAssertGreaterThanOrEqual(SizeEstimate.parallelLimit, 1)
        XCTAssertLessThanOrEqual(SizeEstimate.parallelLimit, 3)
        let w = try Fixtures.wav(Fixtures.tone(seconds: 2), name: "durata-\(UUID().uuidString).wav")
        let d1 = await SizeEstimate.duration(w), d2 = await SizeEstimate.duration(w)
        XCTAssertEqual(d1, 2, accuracy: 0.05)
        XCTAssertEqual(d1, d2)
    }
}
