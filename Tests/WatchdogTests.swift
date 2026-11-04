import XCTest
import AppKit

/// 6.0.3 «Rapporti» · Il guardiano, il rapporto sulla Scrivania e i percorsi senza il nome dell'utente.
final class WatchdogTests: XCTestCase {
    private func tempDir() -> URL {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("guardiano-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    /// Raccoglie le righe che il guardiano scriverebbe nel registro.
    final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [String] = []
        func add(_ a: String, _ t: String) { lock.lock(); items.append("\(a): \(t)"); lock.unlock() }
        var all: String { lock.lock(); defer { lock.unlock() }; return items.joined(separator: "\n") }
    }

    // MARK: Finestra che non risponde

    func testBloccoSoloDopoIlLimite() {
        var d = HangDetector(limit: 4)
        XCTAssertTrue(d.tick(now: 0).sendPing, "il primo giro bussa")
        XCTAssertEqual(d.tick(now: 2).event, .none)
        XCTAssertEqual(d.answered(now: 2.1), .none, "risposta in tempo: niente da dire")
        XCTAssertTrue(d.tick(now: 4).sendPing)
        XCTAssertEqual(d.tick(now: 7).event, .none, "3 secondi: ancora sotto il limite")
        XCTAssertEqual(d.tick(now: 9).event, .hang(5))
        XCTAssertEqual(d.tick(now: 11).event, .none, "lo stesso blocco si scrive una volta sola")
        XCTAssertEqual(d.answered(now: 12), .recovered(8))
    }

    /// Il thread principale fermo davvero per 2,5 secondi (limite di prova: 1): il guardiano se ne accorge.
    func testBloccoVeroDelThreadPrincipale() {
        let lines = Lines()
        let w = Watchdog(dir: tempDir(), interval: 0.3, hangLimit: 1, log: lines.add)
        w.start()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))      // il primo colpo arriva e torna
        Thread.sleep(forTimeInterval: 2.5)                              // la finestra «non risponde»
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        w.stop()
        XCTAssertTrue(lines.all.contains("non risponde"), lines.all)
        XCTAssertTrue(lines.all.contains("tornata a rispondere"), lines.all)
        XCTAssertTrue((w.pending ?? "").contains("La finestra non risponde"), w.pending ?? "nessun problema")
    }

    /// A riposo il guardiano si sveglia una volta ogni 2 secondi, non di più (niente processore sprecato).
    func testGuardianoLeggeroARiposo() {
        let w = Watchdog(dir: tempDir(), log: { _, _ in })
        w.start()
        RunLoop.main.run(until: Date().addingTimeInterval(5.2))
        w.stop()
        XCTAssertLessThanOrEqual(w.ticks, 3, "troppi risvegli: \(w.ticks)")
        XCTAssertGreaterThanOrEqual(w.ticks, 1)
        XCTAssertNil(w.pending, "a riposo nessun problema")
    }

    // MARK: Chiusura di colpo

    func testChiusuraDiColpoAlProssimoAvvio() {
        let dir = tempDir()
        let first = Watchdog(dir: dir, log: { _, _ in })
        first.launch(previousVersion: "6.0.1", firstLaunch: false, start: false)
        XCTAssertNil(first.pending, "primo avvio: niente da riferire")
        XCTAssertTrue(first.launchKind.contains("aggiornata dalla 6.0.1"))
        // … l'app si chiude di colpo: nessun cleanExit()
        let second = Watchdog(dir: dir, log: { _, _ in })
        second.launch(previousVersion: nil, firstLaunch: false, start: false)
        XCTAssertTrue((second.pending ?? "").contains("all’improvviso"), second.pending ?? "")
        XCTAssertTrue((second.pending ?? "").contains("aggiornata dalla 6.0.1"), "si sa com'era partita la volta prima")
        second.settlePending()
        XCTAssertNil(second.pending, "dopo la domanda non si chiede più")
        XCTAssertNotNil(second.lastProblem, "ma resta per «Segnala»")
        second.cleanExit()
        let third = Watchdog(dir: dir, log: { _, _ in })
        third.launch(previousVersion: nil, firstLaunch: false, start: false)
        XCTAssertNil(third.pending, "uscita normale: niente rapporto")
        third.cleanExit()
    }

    // MARK: Lavori fermi

    func testLavoroFermoUnaVoltaSola() {
        var s = StallTracker(limit: 60)
        let id = UUID()
        XCTAssertFalse(s.update(id, sig: "a", now: 0))
        XCTAssertFalse(s.update(id, sig: "a", now: 50))
        XCTAssertTrue(s.update(id, sig: "a", now: 61), "fermo da più di un minuto")
        XCTAssertFalse(s.update(id, sig: "a", now: 200), "una volta sola")
        XCTAssertFalse(s.update(id, sig: "b", now: 201), "avanza di nuovo")
        XCTAssertFalse(s.update(id, sig: "b", now: 250))
        XCTAssertTrue(s.update(id, sig: "b", now: 262))
    }

    func testUltimoErroreRicordato() throws {
        let d = try XCTUnwrap(UserDefaults(suiteName: "guardiano-\(UUID().uuidString)"))
        let a = try XCTUnwrap(Catalog.pieActions(for: .img, exts: ["jpg"], mergeable: 1, count: 1).first)
        let j = Job(files: [URL(fileURLWithPath: "/tmp/foto.jpg")], action: a, param: "")
        j.state = .failed
        j.failures = ["il motore non risponde"]
        let w = Watchdog(dir: tempDir(), log: { _, _ in })
        w.noteFinished(j, defaults: d)
        XCTAssertTrue((Watchdog.lastError(d) ?? "").contains(a.id), Watchdog.lastError(d) ?? "")
        XCTAssertFalse(w.enginesUsed.isEmpty, "si sa quale motore è stato usato")
    }

    // MARK: Il rapporto

    func testRapportoCompletoESenzaNomi() throws {
        let text = ProblemReport.text(problems: "• La finestra non risponde in /Users/Mario Rossi/Desktop/vacanze.mov")
        for part in ["COSA È SUCCESSO", "La finestra non risponde", "macOS", "Mac:", "Memoria (RAM)", "Spazio libero",
                     "Schermi:", "Scheda grafica", "Lingua", "Regione", "Motori dentro l’app", "Scrivania in iCloud",
                     "Questo avvio", "ULTIMO ERRORE", "Registro (ultime righe)"] {
            XCTAssertTrue(text.contains(part), "manca «\(part)»")
        }
        XCTAssertFalse(text.contains("Rossi"), "il nome dell'utente non deve esserci")
        XCTAssertFalse(text.contains("vacanze"), "nemmeno i nomi dei file")
        XCTAssertTrue(text.contains("/Users/***/Desktop"))
        XCTAssertFalse(text.contains(FileManager.default.homeDirectoryForCurrentUser.lastPathComponent + "/"),
                       "nemmeno il nome dell'utente di questo Mac")
        let u = try XCTUnwrap(ProblemReport.save(text))
        defer { try? FileManager.default.removeItem(at: u) }
        XCTAssertEqual(u.pathExtension, "txt")
        XCTAssertEqual(try String(contentsOf: u, encoding: .utf8), text)
    }

    func testRigaDelloSchermo() {
        XCTAssertEqual(SystemInfo.screenLine(points: CGSize(width: 1440, height: 900), scale: 2),
                       "1440×900 punti («sembra»), scala 2× → 2880×1800 pixel")
    }

    // MARK: Percorsi senza il nome dell'utente (anche in «Segnala»)

    func testNomeUtenteTolto() {
        let home = "/Users/Mario Rossi"
        let cases = [
            "/Users/Mario Rossi/Desktop/a.txt",              // il proprio, con lo spazio
            "file:///Users/Mario%20Rossi/Documents/b",       // in un link
            "/Users/Anna Bianchi/Movies/c",                  // un altro utente, con lo spazio
            "errore in /users/luca",                         // in fondo e in minuscolo
            "/Volumes/Disco/Users/giulia/x",                 // su un altro disco
        ]
        for c in cases {
            let out = Redact.userPaths(c, home: home)
            for name in ["Mario", "Rossi", "Anna", "Bianchi", "luca", "giulia"] {
                XCTAssertFalse(out.contains(name), "«\(c)» → «\(out)»")
            }
            XCTAssertTrue(out.contains("/Users/***"), out)
        }
        XCTAssertEqual(Redact.userPaths("/Users/Mario Rossi/Desktop/a.txt", home: home), "/Users/***/Desktop/a.txt")
        XCTAssertEqual(Redact.userPaths("/Users/***/x", home: home), "/Users/***/x", "già pulito resta uguale")
        XCTAssertEqual(Redact.userPaths("/Users/Shared/x", home: home), "/Users/Shared/x", "la cartella condivisa non è un nome")
    }

    func testSegnalaTogleIlNomeUtente() {
        let out = BugReport.anonymize("Salvato in /Users/Mario Rossi/Desktop e /Users/Anna Bianchi/Documents/prova",
                                      names: [], home: "/Users/Mario Rossi")
        XCTAssertFalse(out.contains("Rossi"), out)
        XCTAssertFalse(out.contains("Bianchi"), out)
        XCTAssertTrue(out.contains("/Users/***/Desktop"), out)
    }

    // MARK: Testi in italiano e inglese

    func testTestiTradotti() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Localizable.xcstrings")
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let s = try XCTUnwrap(json["strings"] as? [String: Any])
        for k in ["L’ultima volta qualcosa è andato storto. Vuoi mandarmi il rapporto?", "Salva il rapporto sulla Scrivania",
                  "Non ora", "Rapporto OrbitLR", "Puoi mandare questo file con WhatsApp o per email. Non contiene i nomi dei tuoi file.",
                  "Salvo sulla Scrivania un file di testo con le informazioni sul Mac e su OrbitLR, senza i nomi dei tuoi file. Puoi mandarlo con WhatsApp o per email.",
                  "La cartella è molto grande o non ancora scaricata da iCloud: ho preso i file trovati in pochi secondi."] {
            let en = ((s[k] as? [String: Any])?["localizations"] as? [String: Any])?["en"]
            XCTAssertNotNil(en, "manca l’inglese per «\(k)»")
        }
    }
}

/// 6.0.3 · Cartelle lente (enormi, di rete, in iCloud non scaricate): la finestra non si ferma più ad aspettarle.
final class SlowFolderTests: XCTestCase {
    /// Una cartella che «non finisce mai» di elencarsi: l'attesa è al massimo quella stabilita.
    func testCartellaLentaNonBloccaLaTorta() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lenta-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let single = dir.appendingPathComponent("foto.jpg")
        try Data([1]).write(to: single)
        let t0 = Date()
        let out = PieController.expand([dir], timeout: 0.5) { _, emit, _ in
            emit(single)
            Thread.sleep(forTimeInterval: 8)            // come iCloud che scarica una cartella
        }
        let spent = Date().timeIntervalSince(t0)
        XCTAssertLessThan(spent, 2, "la torta ha aspettato \(spent) secondi")
        XCTAssertEqual(out, [single], "si tengono i file trovati fin lì")
        XCTAssertTrue(PieController.lastExpandIncomplete)
    }

    /// Una cartella normale si elenca come prima (stessi file, cartelle «Convertiti» escluse).
    func testCartellaNormaleComePrima() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("normale-\(UUID().uuidString)")
        try fm.createDirectory(at: dir.appendingPathComponent("sotto"), withIntermediateDirectories: true)
        try fm.createDirectory(at: dir.appendingPathComponent("Convertiti"), withIntermediateDirectories: true)
        for n in ["a.jpg", "sotto/b.png", "Convertiti/c.jpg"] { try Data([1]).write(to: dir.appendingPathComponent(n)) }
        let loose = fm.temporaryDirectory.appendingPathComponent("sciolto-\(UUID().uuidString).pdf")
        try Data([1]).write(to: loose)
        let out = PieController.expand([dir, loose]).map { $0.resolvingSymlinksInPath().lastPathComponent }
        XCTAssertEqual(Set(out), ["a.jpg", "b.png", loose.lastPathComponent])
        XCTAssertFalse(PieController.lastExpandIncomplete)
    }

    /// Il lavoro in sottofondo che non finisce: chi aspetta riparte dopo il tempo massimo.
    func testAttesaLimitata() {
        let t0 = Date()
        let r = BoundedWalk<Int>.collect(timeout: 0.3) { emit, stopped in
            emit(1)
            while !stopped() { Thread.sleep(forTimeInterval: 0.05) }
            emit(2)                                         // dopo lo stop non conta più
        }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.5)
        XCTAssertEqual(r.items, [1])
        XCTAssertFalse(r.complete)
    }

    /// Il peso di una cartella si conta come prima.
    func testPesoCartella() throws {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("peso-\(UUID().uuidString)")
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data(count: 1000).write(to: dir.appendingPathComponent("a"))
        try Data(count: 500).write(to: dir.appendingPathComponent("b"))
        XCTAssertEqual(Job.size(of: dir), 1500)
    }
}
