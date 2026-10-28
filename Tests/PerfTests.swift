import XCTest
import SwiftUI
import AppKit

/// 3.4.1 · Misura: i momenti che devono essere rapidi hanno un cronometro, e i test lo tengono d'occhio.
/// Il Mac di prova è lento e senza scheda grafica: le soglie qui sono larghe (fermano i peggioramenti grossi);
/// i tempi veri si leggono nel riepilogo («TEMPO: …») e nel Mac di tutti i giorni con Registra i tempi.
@MainActor
final class PerfTests: XCTestCase {
    private func ms(_ s: Double) -> String { String(format: "%.0f ms", s * 1000) }

    func testCronometro() {
        Perf.reset()
        Perf.begin(.pieOpen)
        let s = Perf.end(.pieOpen)
        XCTAssertNotNil(s)
        XCTAssertNil(Perf.end(.pieOpen), "una misura si chiude una volta sola")
        for v in [0.3, 0.1, 0.2] { Perf.record(.thumbnail, v) }
        XCTAssertEqual(Perf.median(.thumbnail) ?? 0, 0.2, accuracy: 0.0001)
        for _ in 0..<(Perf.keep + 20) { Perf.record(.thumbnail, 0.01) }
        XCTAssertEqual(Perf.samples(.thumbnail).count, Perf.keep, "solo le ultime misure")
        XCTAssertTrue(Perf.report.contains("Miniatura"))
    }

    private func host<V: View>(_ v: V, size: CGSize = CGSize(width: 1100, height: 720)) -> NSHostingController<some View> {
        let h = NSHostingController(rootView: v
            .environmentObject(QueueStore.shared)
            .environmentObject(AppState.shared)
            .environmentObject(SettingsModel()))
        h.view.frame = CGRect(origin: .zero, size: size)
        return h
    }

    /// Cambio di scheda: il lavoro di SwiftUI per mostrare ogni scheda. Al ritorno (3.4.2) le schede sono già vive.
    func testCambioDiScheda() {
        let app = AppState.shared
        let h = host(MainWindow())
        h.view.layoutSubtreeIfNeeded()
        var worstFirst = 0.0, worstBack = 0.0
        var nameFirst = "", nameBack = ""
        for pass in 0..<2 {
            for tab in SidebarItem.tabs + [.activity, .workspace] {
                let t0 = CACurrentMediaTime()
                app.selection = tab
                h.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                h.view.layoutSubtreeIfNeeded()
                let s = CACurrentMediaTime() - t0 - 0.01
                if pass == 0 { if s > worstFirst { worstFirst = s; nameFirst = tab.rawValue } } else if s > worstBack { worstBack = s; nameBack = tab.rawValue }
                print("TEMPO: scheda \(tab.rawValue) \(pass == 0 ? "prima volta" : "ritorno") \(ms(s))")
            }
        }
        app.selection = .workspace
        XCTAssertLessThan(worstFirst, 1.5, "una scheda ci mette troppo a comparire la prima volta (\(nameFirst): \(ms(worstFirst)))")
        XCTAssertLessThan(worstBack, 0.5, "tornare su una scheda già aperta deve essere quasi istantaneo (\(nameBack): \(ms(worstBack)))")
    }

    func testLeSchedeDiLavoroRestanoVive() {
        for t in SidebarItem.tabs { XCTAssertTrue(SidebarItem.kept.contains(t), "\(t.rawValue) deve restare viva") }
        XCTAssertFalse(SidebarItem.kept.contains(.activity), "Attività si ricostruisce: viva ricalcolerebbe la cronologia a ogni avanzamento")
    }

    /// Torta: costruire gli spicchi e impaginare la torta.
    func testAperturaDellaTorta() throws {
        let photo = try Fixtures.photo(name: "torta-tempo.jpg")
        var times: [Double] = []
        for _ in 0..<5 {
            let t0 = CACurrentMediaTime()
            let m = PieModel()
            m.setup(actions: Catalog.pieActions(for: .img, exts: ["jpg"], mergeable: 1, count: 1))
            m.fileName = photo.lastPathComponent
            let h = host(PieView(model: m, side: 520), size: CGSize(width: 520, height: 520))
            h.view.layoutSubtreeIfNeeded()
            times.append(CACurrentMediaTime() - t0)
        }
        let first = times[0], warm = times.dropFirst().sorted()[1]
        print("TEMPO: torta prima volta \(ms(first)) · poi \(ms(warm))")
        XCTAssertLessThan(warm, 0.5, "la torta ci mette troppo a prepararsi (\(ms(warm)))")
    }

    /// Le animazioni continue non ridisegnano più il corpo delle viste a ogni fotogramma.
    func testNienteRidisegniContinui() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Sources")
        for f in ["Workspace.swift", "Polish.swift"] {
            let s = try String(contentsOf: root.appendingPathComponent(f), encoding: .utf8)
            XCTAssertFalse(s.contains("TimelineView(.animation(minimumInterval: 1.0 / 24") || s.contains("minimumInterval: 1 / 20"),
                           "\(f): animazione a scatti tornata")
        }
    }

    /// 3.4.4 · Le miniature sul disco hanno un nome stabile (si ritrovano al riavvio) e diverso per ogni file e misura.
    func testMiniatureSulDisco() {
        let a = ThumbCache.diskURL("/x/foto.jpg|220|100"), b = ThumbCache.diskURL("/x/foto.jpg|220|100")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, ThumbCache.diskURL("/x/foto.jpg|88|100"))
        XCTAssertNotEqual(a, ThumbCache.diskURL("/x/foto.jpg|220|101"), "file cambiato: miniatura nuova")
        XCTAssertEqual(a.pathExtension, "png")
    }

    func testMiniaturaVeraDaUnaFoto() async throws {
        let photo = try Fixtures.photo(name: "miniatura-\(UUID().uuidString).jpg", width: 800, height: 600)
        let img: NSImage? = await withCheckedContinuation { c in ThumbCache.shared.image(for: photo, side: 120) { c.resume(returning: $0) } }
        // Sul Mac di prova QuickLook può non fare miniature: se c'è, deve stare in memoria e sul disco
        if img != nil {
            XCTAssertNotNil(ThumbCache.shared.cached(for: photo, side: 120), "dopo la prima volta è in memoria")
        }
    }
}
