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
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Controlla aggiornamenti…") {
                    Task { @MainActor in await UpdateCheck.check(userInitiated: true) }
                }
            }
            // 5.1 · Un menu vero: File, Vista e Aiuto, come in ogni app del Mac
            CommandGroup(replacing: .newItem) {
                Button("Nuovo progetto video") {
                    app.show(.video)
                    VideoProjectStore.shared.newProject(nil)
                    app.videoMode = .montage
                }.keyboardShortcut("n", modifiers: [.command, .shift])
                Button("Apri…") { app.openFiles() }.keyboardShortcut("o")
            }
            CommandGroup(before: .sidebar) {
                ForEach(Array(SidebarItem.tabs.enumerated()), id: \.offset) { i, item in
                    Button(item.title) { app.show(item) }
                        .keyboardShortcut(KeyEquivalent(Character(String(i + 1))), modifiers: .command)
                }
                Button(SidebarItem.activity.title) { app.show(.activity) }.keyboardShortcut("0")
                Divider()
            }
            CommandGroup(replacing: .help) {
                Button("Aiuto di OrbitLR") { app.show(.help) }.keyboardShortcut("?")
                Button("Segnala un problema…") { app.mainWindow?.makeKeyAndOrderFront(nil); app.showBugReport = true }
                Button("Suggerisci un’idea…") { Feedback.show() }
            }
        }

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
