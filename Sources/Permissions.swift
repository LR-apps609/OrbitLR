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
    enum State: Equatable { case waiting, asking, granted, denied, later }

    struct Item: Identifiable, Equatable {
        let id: String
        let title: String
        let why: String
        let symbol: String
        var state: State = .waiting
    }

    @Published var items: [Item] = [
        Item(id: "desktop", title: String(localized: "Scrivania"), why: String(localized: "per convertire i file che tieni sulla Scrivania"), symbol: "menubar.dock.rectangle"),
        Item(id: "documents", title: String(localized: "Documenti"), why: String(localized: "per aprire e salvare i tuoi progetti"), symbol: "doc.fill"),
        Item(id: "downloads", title: String(localized: "Download"), why: String(localized: "per i file scaricati e i risultati"), symbol: "arrow.down.circle.fill"),
        Item(id: "notifications", title: String(localized: "Notifiche"), why: String(localized: "per avvisarti quando un lavoro lungo è finito"), symbol: "bell.fill"),
        Item(id: "finder", title: "Finder", why: String(localized: "per leggere i file selezionati quando premi ⌥⌘C"), symbol: "face.smiling"),
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
                let st = Self.ask(id)
                DispatchQueue.main.sync { items[i].state = st }
            }
            DispatchQueue.main.async {
                self.running = false
                self.done = true
                finish()
            }
        }
    }

    private static func ask(_ id: String) -> State {
        let fm = FileManager.default
        switch id {
        case "desktop", "documents", "downloads":
            let dir: FileManager.SearchPathDirectory = id == "desktop" ? .desktopDirectory : id == "documents" ? .documentDirectory : .downloadsDirectory
            guard let url = fm.urls(for: dir, in: .userDomainMask).first else { return .denied }
            // Leggere l'elenco della cartella fa comparire la richiesta di macOS (solo se non è già stata data)
            return (try? fm.contentsOfDirectory(atPath: url.path)) != nil ? .granted : .denied
        case "notifications":
            // 5.0.1 · macOS chiede le notifiche con un avviso in alto a destra, non con una finestra: se non si vede
            // (Non disturbare, Full Screen) la risposta non arriva mai. Si aspetta poco e poi si va avanti: si darà dopo.
            let center = UNUserNotificationCenter.current()
            let sem = DispatchSemaphore(value: 0)
            var current: UNAuthorizationStatus = .notDetermined
            center.getNotificationSettings { st in current = st.authorizationStatus; sem.signal() }
            _ = sem.wait(timeout: .now() + 3)
            switch current {
            case .authorized, .provisional: return .granted
            case .denied: return .denied
            default: break
            }
            var answer: Bool?
            center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
                answer = granted
                sem.signal()
            }
            if sem.wait(timeout: .now() + 20) == .timedOut { return .later }
            return answer == true ? .granted : .denied
        case "finder":
            // Il Finder deve essere aperto (lo è quasi sempre); la richiesta compare una volta sola
            let target = NSAppleEventDescriptor(bundleIdentifier: "com.apple.finder")
            guard let desc = target.aeDesc else { return .denied }
            let status = AEDeterminePermissionToAutomateTarget(desc, typeWildCard, typeWildCard, true)
            // -1743 = negato; -600 = Finder chiuso (si chiederà al primo ⌥⌘C)
            return status != OSStatus(errAEEventNotPermitted) ? .granted : .denied
        default:
            return .denied
        }
    }
}
