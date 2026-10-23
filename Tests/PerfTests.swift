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

    /// Cambio di scheda: il lavoro di SwiftUI per mostrare ogni scheda (costruzione e impaginazione).
    func testCambioDiScheda() {
        let app = AppState.shared
        let h = host(MainWindow())
        h.view.layoutSubtreeIfNeeded()
        var worst = 0.0
        for tab in SidebarItem.tabs + [.activity, .presets, .help, .workspace] {
            let t0 = CACurrentMediaTime()
            app.selection = tab
            h.view.layoutSubtreeIfNeeded()
            RunLoop.main.run(until: Date().addingTimeInterval(0.01))
            h.view.layoutSubtreeIfNeeded()
            let s = CACurrentMediaTime() - t0
            worst = max(worst, s)
            print("TEMPO: scheda \(tab.rawValue) \(ms(s))")
        }
        app.selection = .workspace
        XCTAssertLessThan(worst, 1.5, "una scheda ci mette troppo a comparire (\(ms(worst)))")
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
}
