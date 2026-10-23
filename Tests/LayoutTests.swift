import XCTest
import SwiftUI
import AppKit

/// 2.8.9 · Nessuna scheda deve chiedere più spazio della finestra.
/// (Il bug della 2.8.4: una frase dell'Audio faceva crescere la finestra oltre lo schermo.)
@MainActor
final class LayoutTests: XCTestCase {
    private let detail = CGSize(width: 660, height: 560)      // la parte destra della finestra più piccola

    private func check<V: View>(_ name: String, _ view: V, file: StaticString = #filePath, line: UInt = #line) {
        let root = view
            .environmentObject(QueueStore.shared)
            .environmentObject(AppState.shared)
            .environmentObject(SettingsModel())
        let host = NSHostingController(rootView: root)
        let fit = host.sizeThatFits(in: detail)
        XCTAssertLessThanOrEqual(fit.height, detail.height + 1, "\(name): troppo alta (\(Int(fit.height)) punti)", file: file, line: line)
        XCTAssertLessThanOrEqual(fit.width, detail.width + 1, "\(name): troppo larga (\(Int(fit.width)) punti)", file: file, line: line)
        // La misura minima: con la proposta più piccola possibile non deve diventare gigantesca
        let least = host.sizeThatFits(in: CGSize(width: 1, height: 1))
        XCTAssertLessThan(least.height, 2000, "\(name): la misura minima è enorme (\(Int(least.height)) punti)", file: file, line: line)
    }

    private func folder() -> URL { Fixtures.dir.appendingPathComponent("layout-\(UUID().uuidString)", isDirectory: true) }

    func testConversione() { check("Conversione", WorkspaceView(ws: Workspace())) }
    func testImmagini() { check("Immagini", KindTabView(m: KindTabModel(accepts: [.img]), style: .images)) }
    func testFile() { check("File", KindTabView(m: KindTabModel(accepts: [.pdf, .doc]), style: .files)) }
    func testVideo() { check("Video", VideoEditorView(s: VideoProjectStore(folder: folder()))) }
    /// 2.9.10 · La schermata Video con una clip (anteprima, pannello, sequenza) sta nella finestra più piccola.
    func testVideoEditorWithClip() async throws {
        let v = try await Fixtures.video(name: "layout-video.mp4", width: 320, height: 180, seconds: 2)
        let s = VideoProjectStore(folder: folder())
        s.newProject(nil)
        s.change(nil, "Aggiungi") { $0.clips = [VPClip(path: v.path, inPoint: 0, outPoint: 2)] }
        check("Video con una clip", VideoEditorView(s: s))
        s.closeProject(nil)
    }
    func testAudio() { check("Audio", AudioTabView(m: MediaTabModel(videoTab: false, projectsFolder: folder()))) }
    func testAttivita() { check("Attività", ActivityView()) }
    func testStrumentiVideo() { check("Strumenti video", KindTabView(m: KindTabModel(accepts: [.video]), style: .video)) }
    func testAiuto() { check("Aiuto", HelpView()) }

    /// 2.9.2 · La schermata dei permessi sta nella schedina di avvio (500 × 470), anche con la riga dei ✕.
    func testPermessi() {
        let p = Permissions()
        for i in p.items.indices { p.items[i].state = i % 2 == 0 ? .denied : .granted }
        p.done = true
        let host = NSHostingController(rootView: PermissionsView(p: p, firstLaunch: false) {}.frame(width: 500))
        let fit = host.sizeThatFits(in: CGSize(width: 500, height: 470))
        XCTAssertLessThanOrEqual(fit.height, 471, "permessi: troppo alta (\(Int(fit.height)) punti)")
    }
}
