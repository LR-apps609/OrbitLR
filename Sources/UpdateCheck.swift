import Foundation
import AppKit

// ════════════════════════════════════════════════════════════════════
//  2.8.1 · «Controlla aggiornamenti»: OrbitLR guarda da sola su GitHub
//  se c'è una versione nuova (una volta al giorno, in silenzio) e, se
//  la vuoi, la scarica e la installa con l'aggiornamento di sempre.
// ════════════════════════════════════════════════════════════════════

enum UpdateCheck {
    struct Release: Equatable {
        let version: String
        let asset: URL
        let page: URL
    }

    static let api = URL(string: "https://api.github.com/repos/LR-apps609/OrbitLR/releases/latest")!
    static let lastKey = "updateLastCheck"
    static let autoKey = "updateAutoCheck"
    static let skipKey = "updateSkipVersion"

    static var current: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0" }

    /// Dalla risposta di GitHub: versione («v2.8.1» → «2.8.1») e file .orbitlr da scaricare.
    static func parse(_ data: Data) -> Release? {
        guard let j = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = j["tag_name"] as? String,
              let assets = j["assets"] as? [[String: Any]] else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard let a = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".orbitlr") == true }),
              let s = a["browser_download_url"] as? String, let u = URL(string: s),
              // 3.5.2 · Solo dalla pagina ufficiale, solo in modo sicuro
              u.scheme == "https", u.host == "github.com", u.path.lowercased().hasPrefix("/lr-apps609/orbitlr/releases/download/") else { return nil }
        let page = (j["html_url"] as? String).flatMap(URL.init(string:)) ?? URL(string: "https://github.com/LR-apps609/OrbitLR/releases")!
        return Release(version: version, asset: u, page: page)
    }

    /// Controllo automatico: al massimo una volta ogni 20 ore, se non è stato spento.
    static func shouldAutoCheck(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: autoKey) as? Bool == false { return false }
        let last = defaults.double(forKey: lastKey)
        return last == 0 || now.timeIntervalSince1970 - last > 20 * 3600
    }

    static func latest() async throws -> Release? {
        var req = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("OrbitLR/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    /// All'avvio, dopo qualche secondo: in silenzio, parla solo se c'è una versione nuova.
    static func autoCheckSoon() {
        guard shouldAutoCheck() else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            Task { @MainActor in await check(userInitiated: false) }
        }
    }

    @MainActor
    static func check(userInitiated: Bool) async {
        guard !Updater.shared.busy else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
        let rel: Release?
        do { rel = try await latest() } catch {
            if userInitiated { info("Non riesco a controllare gli aggiornamenti", "Controlla di essere connesso a internet e riprova.") }
            return
        }
        guard let rel else {
            if userInitiated { info("Non riesco a controllare gli aggiornamenti", "GitHub non ha risposto come previsto. Riprova più tardi.") }
            return
        }
        guard News.newer(rel.version, than: current) else {
            if userInitiated { info("Hai già l’ultima versione", "OrbitLR \(current) è la più recente.") }
            return
        }
        // Una versione che hai scelto di saltare non si ripropone da sola (ma «Controlla aggiornamenti» sì)
        if !userInitiated, UserDefaults.standard.string(forKey: skipKey) == rel.version { return }
        let a = NSAlert()
        a.messageText = "È disponibile OrbitLR \(rel.version)"
        a.informativeText = "Hai la \(current). La scarico e la installo? Ci vogliono pochi secondi e OrbitLR si riapre da sola."
        a.addButton(withTitle: "Scarica e installa")
        a.addButton(withTitle: "Più tardi")
        a.addButton(withTitle: "Salta questa versione")
        NSApp.activate()
        switch a.runModal() {
        case .alertFirstButtonReturn: await download(rel)
        case .alertThirdButtonReturn: UserDefaults.standard.set(rel.version, forKey: skipKey)
        default: break
        }
    }

    @MainActor
    private static func download(_ rel: Release) async {
        let dir = Paths.home.appendingPathComponent("Library/Caches/OrbitLR-download")
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("OrbitLR.\(rel.version).orbitlr")
        do {
            let (tmp, resp) = try await URLSession.shared.download(from: rel.asset)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
            try fm.moveItem(at: tmp, to: dest)
        } catch {
            let a = NSAlert()
            a.messageText = "Il download non è riuscito"
            a.informativeText = "Riprova, oppure scarica l’aggiornamento dalla pagina di GitHub e aprilo con un doppio clic."
            a.addButton(withTitle: "Apri la pagina")
            a.addButton(withTitle: "Chiudi")
            if a.runModal() == .alertFirstButtonReturn { NSWorkspace.shared.open(rel.page) }
            return
        }
        Updater.shared.open(dest, confirmed: true, expectedVersion: rel.version)
    }

    @MainActor
    private static func info(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.addButton(withTitle: "OK")
        NSApp.activate()
        a.runModal()
    }
}
