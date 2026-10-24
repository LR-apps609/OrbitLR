import XCTest

/// 3.0 · Identità: parole uguali ovunque, niente gergo in vista, progetti distinguibili.
final class IdentityTests: XCTestCase {
    func testNienteGergoNegliStrumenti() {
        let banned = ["OCR", "Normalizza", "Scontorna", "preset", "Preset", "HEVC", "Togli la password"]
        for a in Catalog.tools.values {
            for w in banned {
                XCTAssertFalse(a.title.contains(w), "\(a.id): «\(a.title)» contiene «\(w)»")
                XCTAssertFalse(a.short.contains(w), "\(a.id): «\(a.short)» contiene «\(w)»")
            }
        }
    }

    func testApostrofiTipografici() {
        for a in Catalog.tools.values {
            XCTAssertFalse((a.title + a.hint).contains("'"), "\(a.id): usa ’ e non '")
        }
        for f in FAQ.all {
            XCTAssertFalse((f.question + f.answer).contains("'"), "FAQ \(f.id): usa ’ e non '")
        }
    }

    func testProgettiAudioConLoStessoNome() {
        let a = AudioProject(name: "On The Rope", paths: ["/a.mp3"], tool: "ringtone", start: 40, end: 70)
        let b = AudioProject(name: "On The Rope", paths: ["/a.mp3"], tool: "ringtone", start: 75, end: 105)
        let c = AudioProject(name: "Altro", paths: ["/b.mp3"], tool: "cut", start: 0, end: 10)
        XCTAssertEqual(AudioProjectsRow.title(a, among: [a, b, c]), "On The Rope · 0:40")
        XCTAssertEqual(AudioProjectsRow.title(b, among: [a, b, c]), "On The Rope · 1:15")
        XCTAssertEqual(AudioProjectsRow.title(c, among: [a, b, c]), "Altro")
    }

    func testStrumentiAudioCompleti() {
        // Quello che è uscito dalla torta per l'audio c'è nella scheda Audio
        let ids = Set(AudioTool.allCases.map { $0.rawValue })
        for t in ["cut", "normalize", "voiceclean", "speed", "silence", "transcribe", "ringtone", "whatsapp", "merge"] {
            XCTAssertTrue(ids.contains(t), "manca \(t) nella scheda Audio")
        }
    }

    func testBarraLateraleSemplice() {
        XCTAssertEqual(SidebarItem.tabs.map { $0.rawValue }, ["Conversione", "File", "Immagini", "Video", "Audio"])
        XCTAssertEqual(SidebarItem.activities, [.activity])
        XCTAssertEqual(SidebarItem.presets.rawValue, "Le mie azioni")
    }
}
