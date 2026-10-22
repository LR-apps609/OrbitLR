import SwiftUI
import AppKit

// Il punto d'ingresso dell'app, da solo in questo file: i test automatici compilano tutto il resto
// senza aprire l'app (niente finestre, niente schermata di avvio sul Mac di GitHub).
@main
struct OrbitLRApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var store = QueueStore.shared
    @StateObject private var settings = SettingsModel()
    @StateObject private var app = AppState.shared

    var body: some Scene {
        // «Window» e non «WindowGroup»: una finestra unica. macOS non può aprirne una seconda in nessun caso
        // (Siri, «Apri con», Condividi, aggiornamenti): al massimo riporta davanti quella che c'è.
        Window("OrbitLR", id: "main") {
            MainWindow()
                .environmentObject(store)
                .environmentObject(settings)
                .environmentObject(app)
                .frame(minWidth: 880, minHeight: 620)
        }
        .defaultSize(width: 1120, height: 760)

        MenuBarExtra {
            MenuBarView().environmentObject(store).environmentObject(app)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView().environmentObject(settings)
        }
    }
}
