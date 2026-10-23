import Foundation
import AppKit
import UserNotifications

// ════════════════════════════════════════════════════════════════════
//  2.9.2 · Permessi chiesti tutti all'inizio.
//  macOS chiede l'accesso a Scrivania, Documenti e Download la prima
//  volta che l'app li tocca: prima succedeva a metà lavoro, aprendo una
//  scheda. Ora si chiedono in fila, con una spiegazione, al primo avvio
//  e dopo ogni aggiornamento (senza la firma Apple macOS li dimentica
//  a ogni nuova versione).
// ════════════════════════════════════════════════════════════════════

final class Permissions: ObservableObject, @unchecked Sendable {
    enum State: Equatable { case waiting, asking, granted, denied }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let why: String
        let symbol: String
        var state: State = .waiting
    }

    @Published var items: [Item] = [
        Item(id: "desktop", title: "Scrivania", why: "per convertire i file che tieni sulla Scrivania", symbol: "menubar.dock.rectangle"),
        Item(id: "documents", title: "Documenti", why: "per aprire e salvare i tuoi progetti", symbol: "doc.fill"),
        Item(id: "downloads", title: "Download", why: "per i file scaricati e i risultati", symbol: "arrow.down.circle.fill"),
        Item(id: "notifications", title: "Notifiche", why: "per avvisarti quando un lavoro lungo è finito", symbol: "bell.fill"),
        Item(id: "finder", title: "Finder", why: "per leggere i file selezionati quando premi ⌥⌘C", symbol: "face.smiling"),
    ]
    @Published var running = false
    @Published var done = false

    /// Chiede i permessi uno dopo l'altro (ogni finestra di macOS aspetta la risposta prima della successiva).
    func askAll(then finish: @escaping () -> Void) {
        guard !running else { return }
        running = true
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            for i in items.indices {
                let id = items[i].id
                DispatchQueue.main.sync { items[i].state = .asking }
                let ok = Self.ask(id)
                DispatchQueue.main.sync { items[i].state = ok ? .granted : .denied }
            }
            DispatchQueue.main.async {
                self.running = false
                self.done = true
                finish()
            }
        }
    }

    private static func ask(_ id: String) -> Bool {
        let fm = FileManager.default
        switch id {
        case "desktop", "documents", "downloads":
            let dir: FileManager.SearchPathDirectory = id == "desktop" ? .desktopDirectory : id == "documents" ? .documentDirectory : .downloadsDirectory
            guard let url = fm.urls(for: dir, in: .userDomainMask).first else { return false }
            // Leggere l'elenco della cartella fa comparire la richiesta di macOS (solo se non è già stata data)
            return (try? fm.contentsOfDirectory(atPath: url.path)) != nil
        case "notifications":
            let sem = DispatchSemaphore(value: 0)
            var ok = false
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
                ok = granted
                sem.signal()
            }
            _ = sem.wait(timeout: .now() + 120)
            return ok
        case "finder":
            // Il Finder deve essere aperto (lo è quasi sempre); la richiesta compare una volta sola
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            guard let desc = target.aeDesc else { return false }
            let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, true)
            // -1743 = negato; -600 = Finder chiuso (si chiederà al primo ⌥⌘C)
            return status != OSStatus(errAEEventNotPermitted)
        default:
            return false
        }
    }
}
