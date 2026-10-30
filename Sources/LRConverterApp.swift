import SwiftUI
import AppKit
import UserNotifications
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    /// 5.1 · Un avviso breve quando OrbitLR non è in primo piano (per esempio dalla scorciatoia nel Finder).
    static func say(_ text: String) {
        NSSound.beep()
        let c = UNMutableNotificationContent()
        c.title = "OrbitLR"
        c.body = text
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    private let services = ServiceProvider()
    /// Vero se un'altra OrbitLR era già aperta: questa passa i file alla prima e si chiude.
    private var duplicate = false
    static let openNotification = Notification.Name("it.ledion.OrbitLR.open")

    func applicationWillFinishLaunching(_ notification: Notification) {
        Perf.begin(.launch)                  // 3.4.1 · fino a quando la finestra è pronta
        let me = NSRunningApplication.current
        let others = NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "it.ledion.OrbitLR")
            .filter { $0.processIdentifier != me.processIdentifier && !$0.isTerminated }
        if let first = others.first {
            duplicate = true
            NSApp.setActivationPolicy(.prohibited)      // niente icona nel Dock né finestre: passa i file e se ne va
            _ = first.activate(options: [])
            // Un attimo per ricevere gli eventuali file da passare all'altra, poi chiude
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { NSApp.terminate(nil) }
        } else {
            // La finestra principale nasce invisibile finché non si sa se c'è la schedina di avvio
            LaunchGate.holding = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if duplicate {
            NSApp.windows.forEach { $0.orderOut(nil) }
            DispatchQueue.main.async { NSApp.windows.forEach { $0.orderOut(nil) } }
            return
        }
        // File passati da un'altra OrbitLR che si è chiusa subito
        DistributedNotificationCenter.default().addObserver(forName: Self.openNotification, object: nil, queue: .main) { n in
            let urls = ((n.userInfo?["urls"] as? [String]) ?? []).compactMap { URL(string: $0) }
            NSApp.activate()
            AppDelegate.handle(urls)
        }

        Paths.installScript()
        WatchStore.shared.start()            // cartelle automatiche
        DropShelf.shared.start()             // 3.9.1 · il ripiano al bordo dello schermo quando trascini dei file
        UpdateCheck.autoCheckSoon()          // 2.8.1 · in silenzio, al massimo ogni 3 ore
        Appearance.apply()
        // 5.1 · Il progetto video che era aperto (anche dopo un crash) torna aperto, dov'eri
        DispatchQueue.main.async { VideoProjectStore.shared.restoreLastOpen() }
        Sounds.shared.prepare()
        cleanOldTemporaryFiles()
        ThumbCache.trimDisk()                // 3.4.4 · miniature sul disco: via quelle vecchie
        // 3.2 · La torta già pronta per la prima apertura (dopo che l'avvio ha finito il suo lavoro)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { PieController.shared.prewarm() }

        // Tasto destro nel Finder → OrbitLR
        NSApp.servicesProvider = services
        NSUpdateDynamicServices()

        // ⌥⌘C sui file selezionati nel Finder
        Hotkey.shared.action = {
            // 4.1.5 · Solo dal Finder (la scorciatoia è attiva solo lì)
            guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.finder" else { return }
            let files = FinderSelection.current()
            if files.isEmpty { AppDelegate.say(String(localized: "Nel Finder non c’è niente di selezionato.")) } else { PieController.shared.present(files: files) }
        }
        Hotkey.shared.setEnabled(UserDefaults.standard.object(forKey: "hotkey") as? Bool ?? true)
        Hotkey.shared.presetAction = { n in PresetStore.shared.run(hotkey: n) }
        PresetStore.shared.registerHotkeys()

        // Notifiche con il pulsante «Mostra»
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // 2.9.2 · Al primo avvio il permesso si chiede nella schermata «Prima di iniziare», insieme agli altri
        if !WelcomeController.isFirstLaunch { center.requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        let show = UNNotificationAction(identifier: "SHOW", title: String(localized: "Mostra"), options: [.foreground])
        center.setNotificationCategories([UNNotificationCategory(identifier: "DONE", actions: [show], intentIdentifiers: [])])

        // Aperta all'accesso al Mac: niente schedina di avvio
        if let ev = NSAppleEventManager.shared().currentAppleEvent, ev.eventID == AEEventID(kAEOpenApplication),
           ev.paramDescriptor(forKeyword: AEKeyword(keyAEPropData))?.enumCodeValue == OSType(keyAELaunchedAsLogInItem) {
            WelcomeController.shared.skipNextSplash = true
        }
        // Mac appena acceso (meno di 3 minuti): quasi certamente è l'apertura automatica all'accesso
        if ProcessInfo.processInfo.systemUptime < 180 { WelcomeController.shared.skipNextSplash = true }
        // Schedina di avvio (o benvenuto al primo avvio). Aspetta un attimo: così la finestra principale esiste
        // già (per nasconderla) e si sa se l'app è stata aperta per dei file.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { WelcomeController.shared.showAtLaunch() }
        // Rete di sicurezza: se per qualsiasi motivo la finestra resta nascosta, dopo 20 secondi si mostra
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
            guard LaunchGate.holding, !Updater.shared.busy, !WelcomeController.shared.isShowing else { return }
            LaunchGate.release()
            AppDelegate.revealMainWindow()
        }
    }

    /// Clic sull'icona nel Dock: la finestra principale torna sempre visibile (mai bloccata invisibile).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !duplicate, !Updater.shared.busy else { return false }
        if WelcomeController.shared.isShowing { return false }
        LaunchGate.release()
        if let w = AppState.shared.mainWindow {
            w.alphaValue = 1
            w.ignoresMouseEvents = false
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            return false
        }
        return true          // nessuna finestra: la ricrea SwiftUI
    }

    /// Pulizia automatica: cartelle temporanee rimaste da operazioni interrotte e log troppo lungo.
    private func cleanOldTemporaryFiles() {
        DispatchQueue.global(qos: .utility).async {
            let fm = FileManager.default
            // La copia compilata durante l'ultimo aggiornamento: se macOS la ricorda come app,
            // può aprirsi una seconda OrbitLR. Si toglie (solo se questa è l'app installata in Applicazioni).
            if Bundle.main.bundlePath.hasPrefix("/Applications/") {
                for dir in ["Library/Caches/OrbitLR-build"] {
                    let d = Paths.home.appendingPathComponent(dir)
                    guard fm.fileExists(atPath: d.path), !Updater.shared.busy else { continue }
                    let built = d.appendingPathComponent("Build/Products/Release/OrbitLR.app")
                    if fm.fileExists(atPath: built.path) {
                        let p = Process()
                        p.executableURL = URL(fileURLWithPath: Updater.lsregister)
                        p.arguments = ["-u", built.path]
                        try? p.run()
                        p.waitUntilExit()
                    }
                    try? fm.removeItem(at: d)
                }
            }
            let cache = Paths.home.appendingPathComponent("Library/Caches/LRConverter")
            let limit = Date().addingTimeInterval(-6 * 3600)
            if let items = try? fm.contentsOfDirectory(at: cache, includingPropertiesForKeys: [.contentModificationDateKey]) {
                for u in items where u.lastPathComponent.hasPrefix("job.") {
                    let d = (try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date()
                    if d < limit { try? fm.removeItem(at: u) }
                }
            }
            if let attrs = try? fm.attributesOfItem(atPath: Paths.log.path),
               let size = attrs[.size] as? NSNumber, size.int64Value > 5_000_000,
               let text = try? String(contentsOf: Paths.log, encoding: .utf8) {
                try? String(text.suffix(1_000_000)).write(to: Paths.log, atomically: true, encoding: .utf8)
            }
        }
    }

    /// «Apri con → OrbitLR» e file trascinati sull'icona nel Dock
    func application(_ application: NSApplication, open urls: [URL]) {
        if duplicate {
            DistributedNotificationCenter.default().postNotificationName(
                Self.openNotification, object: nil, userInfo: ["urls": urls.map { $0.absoluteString }], deliverImmediately: true)
            return
        }
        WelcomeController.shared.skipNextSplash = true      // aperta per dei file: il menu subito, senza schedina
        Self.handle(urls)
    }

    /// Porta in primo piano la finestra principale con i file caricati in «Modifica e converti».
    static func showInWindow(_ files: [URL]) {
        let app = AppState.shared
        app.selection = .workspace
        app.workspace.load(files)
        LaunchGate.release()
        NSApp.activate()
        PieController.shared.close()
        bringMainWindow(attempt: 0)
    }

    /// 3.0 · Porta davanti la finestra principale (per «Modifica in…» dal menu del Finder).
    static func showMain() {
        LaunchGate.release()
        NSApp.activate()
        bringMainWindow(attempt: 0)
    }

    /// Mostra la finestra principale se esiste già (dopo la schedina di avvio); non ne crea di nuove.
    static func revealMainWindow() {
        guard let w = AppState.shared.mainWindow else { return }
        w.alphaValue = 1
        w.ignoresMouseEvents = false
        if !w.isVisible || w.isMiniaturized {
            if w.isMiniaturized { w.deminiaturize(nil) }
        }
        w.makeKeyAndOrderFront(nil)
    }

    /// Porta davanti la finestra principale che c'è già. Se l'app si è appena aperta, aspetta che macOS la crei
    /// (così non ne nascono due); solo se è stata chiusa davvero, la riapre come col clic sull'icona nel Dock.
    private static func bringMainWindow(attempt: Int) {
        if let w = AppState.shared.mainWindow, w.isVisible || w.isMiniaturized {
            w.alphaValue = 1
            w.ignoresMouseEvents = false
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
            return
        }
        if attempt < 5 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { bringMainWindow(attempt: attempt + 1) }
            return
        }
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// File, aggiornamenti .orbitlr o link orbitlr:// (dall'estensione «Condividi»).
    static func handle(_ urls: [URL]) {
        let links = urls.filter { $0.scheme == "orbitlr" }
        let files = urls.filter { $0.isFileURL }
        if !links.isEmpty {
            // Da «Condividi»: i file si aprono al centro della finestra, come se li avessi trascinati dentro
            let shared = links.flatMap { SharedFiles.receive($0) }
            if !shared.isEmpty { showInWindow(shared) }
            return
        }
        if let update = files.first(where: { $0.pathExtension.lowercased() == "orbitlr" }) {
            Updater.shared.open(update)       // doppio clic su un aggiornamento
            return
        }
        // «Apri con», Siri, icona nel Dock: i file si aprono al centro della finestra, come caricati a mano
        if !files.isEmpty { showInWindow(files) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// 3.5 · ⌘Q con dei lavori in corso: si chiede, mai interruzioni silenziose (tranne durante un aggiornamento).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let running = QueueStore.shared.runningJobs.count + QueueStore.shared.jobs.filter { $0.state == .waiting }.count
        guard running > 0, !Updater.shared.busy else { return .terminateNow }
        let a = NSAlert()
        a.messageText = running == 1 ? String(localized: "C’è un lavoro in corso") : String(localized: "Ci sono \(running) lavori in corso")
        a.informativeText = String(localized: "Se esci adesso si interrompono. I file già pronti restano.")
        a.addButton(withTitle: String(localized: "Continua a lavorare"))
        a.addButton(withTitle: String(localized: "Interrompi ed esci"))
        NSApp.activate()
        if a.runModal() == .alertFirstButtonReturn { return .terminateCancel }
        for j in QueueStore.shared.jobs where j.state == .running || j.state == .waiting { QueueStore.shared.cancel(j) }
        return .terminateNow
    }

    /// 3.5 · La prima volta che chiudi la finestra: OrbitLR resta pronta in alto, e lo dice (una volta sola).
    static func windowClosed() {
        let key = "closeNoticeShown"
        guard !UserDefaults.standard.bool(forKey: key), !Updater.shared.busy else { return }
        UserDefaults.standard.set(true, forKey: key)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            let a = NSAlert()
            a.messageText = String(localized: "OrbitLR resta pronta")
            a.informativeText = String(localized: "La trovi nella barra in alto: ⌥⌘C sui file nel Finder, o trascinali sull’icona. Per chiuderla del tutto: ⌘Q.")
            a.addButton(withTitle: String(localized: "Va bene"))
            a.addButton(withTitle: String(localized: "Esci del tutto"))
            NSApp.activate()
            if a.runModal() == .alertSecondButtonReturn { NSApp.terminate(nil) }
        }
    }

    /// 5.1 · Uscendo dall'app il progetto è già salvato; si scrive l'ultimo secondo, se manca.
    /// Il progetto resta segnato come aperto: al prossimo avvio torna dov'eri.
    func applicationWillTerminate(_ notification: Notification) {
        let s = VideoProjectStore.shared
        if s.currentID != nil { s.applyChanges() }
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let p = response.notification.request.content.userInfo["path"] as? String {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: p)])
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// File arrivati dall'estensione «Condividi».
enum SharedFiles {
    /// orbitlr://open?f=/percorso&f=… → i file da aprire. Quelli che l'estensione ha copiato nel suo spazio temporaneo
    /// vengono spostati in Download/OrbitLR, così i risultati finiscono lì e non in una cartella nascosta.
    static func receive(_ link: URL) -> [URL] {
        guard let c = URLComponents(url: link, resolvingAgainstBaseURL: false), c.host == "open" else { return [] }
        let fm = FileManager.default
        var out: [URL] = []
        for p in (c.queryItems ?? []).filter({ $0.name == "f" }).compactMap({ $0.value }) {
            let u = URL(fileURLWithPath: p)
            guard fm.fileExists(atPath: u.path) else { continue }
            // 3.5.2 · Sicurezza: un link non può mai spostare file dai dati di altre app.
            // Solo lo spazio dell'estensione Condividi di OrbitLR viene copiato (mai spostato); gli altri si ignorano.
            let real = u.resolvingSymlinksInPath().standardizedFileURL.path
            if real.contains("/Library/Containers/") {
                guard real.contains("/Library/Containers/it.ledion.OrbitLR.Share/") else { continue }
                let inbox = IntentRunner.inbox
                try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
                let ext = u.pathExtension
                let dest = Destination.unique(inbox, base: u.deletingPathExtension().lastPathComponent, ext: ext.isEmpty ? "dat" : ext)
                if (try? fm.copyItem(at: u, to: dest)) != nil { out.append(dest) }
            } else {
                out.append(u)
            }
        }
        return out
    }
}

/// Riceve i file dal servizio «OrbitLR» del menu del tasto destro.
final class ServiceProvider: NSObject {
    @objc func convertFiles(_ pboard: NSPasteboard, userData: String?, error: AutoreleasingUnsafeMutablePointer<NSString?>) {
        let urls = (pboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL]) ?? []
        DispatchQueue.main.async {
            WelcomeController.shared.skipNextSplash = true
            if !urls.isEmpty { PieController.shared.present(files: urls) }
        }
    }
}
