import SwiftUI
import AppKit
import UserNotifications
import Carbon

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
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
        UpdateCheck.autoCheckSoon()          // 2.8.1 · una volta al giorno, in silenzio
        Appearance.apply()
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
            let files = FinderSelection.current()
            if files.isEmpty { NSSound.beep() } else { PieController.shared.present(files: files) }
        }
        if UserDefaults.standard.object(forKey: "hotkey") as? Bool ?? true { Hotkey.shared.register() }
        Hotkey.shared.presetAction = { n in PresetStore.shared.run(hotkey: n) }
        PresetStore.shared.registerHotkeys()

        // Notifiche con il pulsante «Mostra»
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        // 2.9.2 · Al primo avvio il permesso si chiede nella schermata «Prima di iniziare», insieme agli altri
        if !WelcomeController.isFirstLaunch { center.requestAuthorization(options: [.alert, .sound]) { _, _ in } }
        let show = UNNotificationAction(identifier: "SHOW", title: "Mostra", options: [.foreground])
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

    /// 2.9.10 · Uscendo dall'app, le modifiche del Video ancora da confermare non si perdono.
    func applicationWillTerminate(_ notification: Notification) {
        let s = VideoProjectStore.shared
        if s.hasPending { s.applyChanges(); s.saveNow() }
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
            if p.contains("/Library/Containers/") {
                let inbox = IntentRunner.inbox
                try? fm.createDirectory(at: inbox, withIntermediateDirectories: true)
                let ext = u.pathExtension
                let dest = Destination.unique(inbox, base: u.deletingPathExtension().lastPathComponent, ext: ext.isEmpty ? "dat" : ext)
                if (try? fm.moveItem(at: u, to: dest)) != nil || (try? fm.copyItem(at: u, to: dest)) != nil { out.append(dest) }
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
