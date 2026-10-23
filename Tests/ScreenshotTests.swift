import XCTest
import SwiftUI
import AppKit
import PDFKit

/// 3.0 · Foto di tutte le schermate, chiare e scure, per la revisione dell'aspetto.
/// Partono solo con SCREENSHOTS=1 (workflow «Foto delle schermate»); nei test normali si saltano.
@MainActor
final class ScreenshotTests: XCTestCase {
    private var outDir: URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["SCREENSHOT_DIR"] ?? "/tmp/orbitlr-foto", isDirectory: true)
    }

    override func setUp() async throws {
        guard ProcessInfo.processInfo.environment["SCREENSHOTS"] == "1" else { throw XCTSkip("foto solo su richiesta") }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
    }

    /// Disegna una vista in una finestra fuori schermo e la salva in PNG (2×), chiara o scura.
    private func shoot<V: View>(_ name: String, _ view: V, size: CGSize, dark: Bool, wait: Double = 1.2) {
        let root = view
            .environmentObject(QueueStore.shared)
            .environmentObject(AppState.shared)
            .environmentObject(SettingsModel())
            .frame(width: size.width, height: size.height)
            .background(Theme.background)
        let host = NSHostingView(rootView: root)
        host.frame = CGRect(origin: .zero, size: size)
        let w = NSWindow(contentRect: CGRect(origin: CGPoint(x: -4000, y: -4000), size: size),
                         styleMask: [.borderless], backing: .buffered, defer: false)
        w.isReleasedWhenClosed = false
        w.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        w.contentView = host
        w.orderFrontRegardless()
        // Il tempo per miniature, anteprime e animazioni d'ingresso
        RunLoop.main.run(until: Date().addingTimeInterval(wait))
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { XCTFail("\(name): niente immagine"); return }
        host.cacheDisplay(in: host.bounds, to: rep)
        let file = outDir.appendingPathComponent("\(name)-\(dark ? "scuro" : "chiaro").png")
        try? rep.representation(using: .png, properties: [:])?.write(to: file)
        w.orderOut(nil)
        w.contentView = nil
    }

    private func both<V: View>(_ name: String, _ view: @autoclosure () -> V, size: CGSize = CGSize(width: 900, height: 640), wait: Double = 1.2) {
        shoot(name, view(), size: size, dark: false, wait: wait)
        shoot(name, view(), size: size, dark: true, wait: wait)
    }

    private func samplePDF() throws -> URL {
        let u = Fixtures.url("Contratto di prova.pdf")
        let doc = PDFDocument()
        if let img = NSImage(contentsOf: try Fixtures.photo(name: "pagina.png", width: 850, height: 1100)), let page = PDFPage(image: img) {
            doc.insert(page, at: 0)
        }
        doc.write(to: u)
        return u
    }

    func test1_Conversione() async throws {
        let app = AppState.shared
        app.workspace.load([])
        both("01-conversione-vuota", WorkspaceView(ws: app.workspace))
        let photo = try Fixtures.photo(name: "Vacanze al mare.jpg", width: 1600, height: 1200)
        app.workspace.load([photo])
        both("02-conversione-foto", WorkspaceView(ws: app.workspace), wait: 2)
        let v = try await Fixtures.video(name: "Compleanno.mp4", width: 640, height: 360, seconds: 2)
        app.workspace.load([photo, v])
        both("03-conversione-due-tipi", WorkspaceView(ws: app.workspace), wait: 2)
        app.workspace.load([])
    }

    func test2_ImmaginiEFile() async throws {
        let m = KindTabModel(accepts: [.img])
        both("04-immagini-vuota", KindTabView(m: m, style: .images))
        m.add([try Fixtures.photo(name: "Tramonto.jpg"), try Fixtures.photo(name: "Ritratto.jpg", width: 900, height: 1200),
               try Fixtures.photo(name: "Spiaggia.png", width: 1200, height: 800)])
        both("05-immagini-tre-foto", KindTabView(m: m, style: .images), wait: 2.5)
        let f = KindTabModel(accepts: [.pdf, .doc, .sheet, .slide, .text])
        both("06-file-vuota", KindTabView(m: f, style: .files))
        f.add([try samplePDF()])
        both("07-file-pdf", KindTabView(m: f, style: .files), wait: 2.5)
    }

    func test3_Video() async throws {
        let folder = Fixtures.dir.appendingPathComponent("foto-video-\(UUID().uuidString)", isDirectory: true)
        let s = VideoProjectStore(folder: folder)
        both("08-video-progetti", VideoEditorView(s: s))
        s.newProject(nil)
        both("09-video-nuovo-progetto", VideoEditorView(s: s))
        let a = try await Fixtures.video(name: "Gita.mp4", width: 640, height: 360, seconds: 4)
        let b = try await Fixtures.video(name: "Cena.mp4", width: 640, height: 360, seconds: 3)
        s.add([a, b], undo: nil)
        for _ in 0..<40 where s.project.clips.count < 2 { try await Task.sleep(nanoseconds: 100_000_000) }
        var t = VPText(); t.text = "Estate 2026"; t.start = 0; t.end = 3; t.style = "big"
        s.change(nil, "Testo") { $0.texts = [t] }
        s.seek(1)
        for tool in VideoEditTool.allCases {
            both("10-video-\(tool.rawValue.lowercased())", VideoEditorView(s: s, startTool: tool), size: CGSize(width: 1000, height: 700), wait: 2.5)
        }
        s.closeProject(nil)
    }

    func test4_Audio() async throws {
        let m = MediaTabModel(videoTab: false, projectsFolder: Fixtures.dir.appendingPathComponent("foto-audio-\(UUID().uuidString)"))
        both("11-audio-vuota", AudioTabView(m: m))
        let song = try Fixtures.wav(Fixtures.tone(seconds: 40, freq: 330), name: "La mia canzone.wav")
        m.load([song])
        for tool in AudioTool.allCases {
            both("12-audio-\(tool.rawValue)", AudioTabView(m: m, startTool: tool), wait: 2)
        }
    }

    func test5_AttivitaEAiuto() throws {
        both("13-attivita", ActivityView())
        both("15-aiuto", HelpView())
        both("16-opzioni", SettingsView(), size: CGSize(width: 640, height: 620))
    }

    func test6_Avvio() throws {
        let ctl = WelcomeController()
        ctl.firstLaunch = true
        for (i, phase) in [WelcomeController.Phase.permissions, .page(0), .page(1), .page(2), .news].enumerated() {
            ctl.phase = phase
            both("17-avvio-\(i)", WelcomeView(ctl: ctl), size: CGSize(width: 500, height: 470), wait: 0.8)
        }
    }

    func test7_FinestraIntera() throws {
        AppState.shared.selection = .workspace
        both("00-finestra-intera", MainWindow(), size: CGSize(width: 1180, height: 760), wait: 2)
        AppState.shared.selection = .video
        both("00-finestra-video", MainWindow(), size: CGSize(width: 1180, height: 760), wait: 2)
        AppState.shared.selection = .workspace
    }

    func test8_Finestrelle() throws {
        let photo = try Fixtures.photo(name: "Logo da togliere.jpg", width: 1600, height: 900)
        both("18-nascondi-filigrana", HideMarkEditor(url: photo, onDone: { _ in }), size: CGSize(width: 700, height: 600), wait: 2)
        if let a = Catalog.action(id: "resize", kind: .img) {
            both("19-opzioni-ridimensiona", ParamView(kind: .resize, action: a, files: [photo], onDone: { _ in }), size: CGSize(width: 480, height: 420))
        }
        if let a = Catalog.action(id: "removebg", kind: .img) {
            both("20-opzioni-sfondo", ParamView(kind: .removebg, action: a, files: [photo], onDone: { _ in }), size: CGSize(width: 480, height: 420))
        }
    }
}
