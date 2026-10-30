import XCTest

/// 5.1 · «Al sicuro»: bozze ritrovate riaprendo e «ci sono modifiche» prima di chiudere.
final class SafeCloseTests: XCTestCase {
    private var defaults: UserDefaults!
    private let suite = "OrbitLRTests.SafeClose"

    override func setUp() {
        super.setUp()
        defaults = UserDefaults(suiteName: suite)
        defaults.removePersistentDomain(forName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testBozzaSalvataERitrovata() {
        XCTAssertEqual(ReportDraft.load(ReportDraft.bugKey, in: defaults), "", "all'inizio niente bozza")
        ReportDraft.save("Il taglio si blocca a metà", key: ReportDraft.bugKey, in: defaults)
        XCTAssertEqual(ReportDraft.load(ReportDraft.bugKey, in: defaults), "Il taglio si blocca a metà")
        // Le due bozze non si mescolano
        XCTAssertEqual(ReportDraft.load(ReportDraft.ideaKey, in: defaults), "")
        ReportDraft.save("Un tema blu", key: ReportDraft.ideaKey, in: defaults)
        XCTAssertEqual(ReportDraft.load(ReportDraft.bugKey, in: defaults), "Il taglio si blocca a metà")
        XCTAssertEqual(ReportDraft.load(ReportDraft.ideaKey, in: defaults), "Un tema blu")
    }

    func testBozzaCancellataDopoLInvio() {
        ReportDraft.save("Testo", key: ReportDraft.bugKey, in: defaults)
        ReportDraft.clear(ReportDraft.bugKey, in: defaults)
        XCTAssertEqual(ReportDraft.load(ReportDraft.bugKey, in: defaults), "")
    }

    func testTestoVuotoNonEUnaBozza() {
        ReportDraft.save("Testo", key: ReportDraft.ideaKey, in: defaults)
        ReportDraft.save("  \n ", key: ReportDraft.ideaKey, in: defaults)
        XCTAssertNil(defaults.string(forKey: ReportDraft.ideaKey), "solo spazi: la bozza sparisce")
    }

    func testCiSonoModificheNelleSegnalazioni() {
        XCTAssertFalse(ReportDraft.hasWork(text: ""))
        XCTAssertFalse(ReportDraft.hasWork(text: " \n\t"))
        XCTAssertTrue(ReportDraft.hasWork(text: "Ciao"))
        XCTAssertTrue(ReportDraft.hasWork(text: "", attachments: 1), "uno screenshot basta")
    }

    func testZoneDelLogo() {
        let a = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.1)
        let b = CGRect(x: 0.6, y: 0.8, width: 0.3, height: 0.1)
        XCTAssertFalse(HideMark.needsDiscardAsk([], initial: []), "senza zone si chiude subito")
        XCTAssertTrue(HideMark.needsDiscardAsk([a], initial: []))
        XCTAssertTrue(HideMark.needsDiscardAsk([a, b], initial: []))
        XCTAssertFalse(HideMark.needsDiscardAsk([a], initial: [a]), "riaperto e non toccato: niente da buttare")
        XCTAssertTrue(HideMark.needsDiscardAsk([a, b], initial: [a]))
        XCTAssertFalse(HideMark.needsDiscardAsk([], initial: [a]), "tolte tutte: «Annulla» le tiene com'erano")
    }

    func testTaglioCambiato() {
        XCTAssertFalse(TrimModel.changed(start: 3, end: 9, baseline: nil), "file non ancora pronto")
        XCTAssertFalse(TrimModel.changed(start: 0, end: 30, baseline: (0, 30)))
        XCTAssertFalse(TrimModel.changed(start: 0.0004, end: 30, baseline: (0, 30)), "differenze invisibili non contano")
        XCTAssertTrue(TrimModel.changed(start: 1.5, end: 30, baseline: (0, 30)))
        XCTAssertTrue(TrimModel.changed(start: 0, end: 12, baseline: (0, 30)))
    }

    /// Con un file vero: appena pronto niente modifiche; spostato l'inizio sì.
    @MainActor
    func testTaglioDaUnFileVero() async throws {
        let w = try Fixtures.wav(Fixtures.tone(seconds: 3, level: 0.5), name: "taglio-sicuro.wav")
        let t = TrimModel(url: w, isVideo: false, defaultLength: nil)
        for _ in 0..<200 where t.loading { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(t.loading)
        XCTAssertFalse(t.hasChanges, "appena aperto: Esc chiude subito")
        t.setStart(1)
        XCTAssertTrue(t.hasChanges)
    }

    @MainActor
    func testOpzioniCambiate() {
        let base = ["1920", "medium", "best"]
        XCTAssertFalse(ParamView.changed(base, from: nil), "pannello non ancora pronto")
        XCTAssertFalse(ParamView.changed(base, from: base))
        XCTAssertTrue(ParamView.changed(["1280", "medium", "best"], from: base))
    }

    /// Ogni avviso nuovo ha la sua traduzione inglese.
    func testTestiTradotti() throws {
        let url = Bundle(for: SafeCloseTests.self).url(forResource: "Localizable", withExtension: "xcstrings")
            ?? URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent("Resources/Localizable.xcstrings")
        guard let data = try? Data(contentsOf: url) else { throw XCTSkip("Localizable.xcstrings non trovato") }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try XCTUnwrap(json["strings"] as? [String: Any])
        for key in ["Butta", "discard.keepEditing", "Continua a scrivere", "Buttare la zona disegnata?",
                    "Buttare le %lld zone disegnate?", "Buttare le scelte fatte?", "Buttare la segnalazione?",
                    "Buttare l’idea?", "Scrivi prima cosa è successo.", "Scegli una faccina o scrivi prima qualcosa.",
                    "Non riesco ad aprire l’email. Scrivimi a %@."] {
            let entry = try XCTUnwrap(strings[key] as? [String: Any], key)
            let en = (entry["localizations"] as? [String: Any])?["en"] as? [String: Any]
            let value = (en?["stringUnit"] as? [String: Any])?["value"] as? String
            XCTAssertFalse((value ?? "").isEmpty, "manca l'inglese: \(key)")
        }
    }
}
