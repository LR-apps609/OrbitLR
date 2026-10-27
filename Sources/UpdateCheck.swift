import Foundation
import SwiftUI
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

    /// Controllo automatico: al massimo una volta ogni 3 ore (4.1.2: prima ogni 20), se non è stato spento.
    static func shouldAutoCheck(now: Date = Date(), defaults: UserDefaults = .standard) -> Bool {
        if defaults.object(forKey: autoKey) as? Bool == false { return false }
        let last = defaults.double(forKey: lastKey)
        return last == 0 || now.timeIntervalSince1970 - last > 3 * 3600
    }

    static func latest() async throws -> Release? {
        var req = URLRequest(url: api, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("OrbitLR/\(current)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    /// All'avvio, dopo qualche secondo, e poi ogni ora (controlla davvero al massimo ogni 3 ore):
    /// in silenzio. Se c'è una versione nuova compare il pulsante «Aggiornamento disponibile» in alto a destra.
    static func autoCheckSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            Task { @MainActor in if shouldAutoCheck() { await check(userInitiated: false) } }
        }
        Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { _ in
            Task { @MainActor in if shouldAutoCheck() { await check(userInitiated: false) } }
        }
    }

    @MainActor
    static func check(userInitiated: Bool) async {
        guard !Updater.shared.busy else { return }
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastKey)
        let rel: Release?
        do { rel = try await latest() } catch {
            if userInitiated { info(String(localized: "Non riesco a controllare gli aggiornamenti"), String(localized: "Controlla di essere connesso a internet e riprova.")) }
            return
        }
        guard let rel else {
            if userInitiated { info(String(localized: "Non riesco a controllare gli aggiornamenti"), String(localized: "GitHub non ha risposto come previsto. Riprova più tardi.")) }
            return
        }
        guard News.newer(rel.version, than: current) else {
            UpdateBadge.shared.available = nil
            if userInitiated { info(String(localized: "Hai già l’ultima versione"), String(localized: "OrbitLR \(current) è la più recente.")) }
            return
        }
        // Una versione che hai scelto di saltare non si ripropone da sola (ma «Controlla aggiornamenti» sì)
        if !userInitiated, UserDefaults.standard.string(forKey: skipKey) == rel.version { return }
        // 4.1.2 · Il controllo automatico non interrompe più con una finestra: compare il pulsante in alto a destra
        if !userInitiated {
            UpdateBadge.shared.available = rel
            return
        }
        let a = NSAlert()
        a.messageText = String(localized: "È disponibile OrbitLR \(rel.version)")
        a.informativeText = String(localized: "Hai la \(current). La scarico e la installo? Ci vogliono pochi secondi e OrbitLR si riapre da sola.")
        a.addButton(withTitle: String(localized: "Scarica e installa"))
        a.addButton(withTitle: String(localized: "Più tardi"))
        a.addButton(withTitle: String(localized: "Salta questa versione"))
        NSApp.activate()
        switch a.runModal() {
        case .alertFirstButtonReturn: await download(rel)
        case .alertThirdButtonReturn: UserDefaults.standard.set(rel.version, forKey: skipKey)
        default: break
        }
    }

    /// 4.1.2 · Dal pulsante «Aggiornamento disponibile»: scarica e installa subito (il clic è già la conferma).
    @MainActor
    static func install(_ rel: Release) async {
        guard !UpdateBadge.shared.installing else { return }
        UpdateBadge.shared.progress = 0
        UpdateBadge.shared.installing = true
        await download(rel)
        UpdateBadge.shared.installing = false
    }

    @MainActor
    private static func download(_ rel: Release) async {
        let dir = Paths.home.appendingPathComponent("Library/Caches/OrbitLR-download")
        let fm = FileManager.default
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent("OrbitLR.\(rel.version).orbitlr")
        do {
            // 4.5.1 · Con la percentuale, come su Windows: il pulsante in alto dice a che punto è il download
            try await DownloadWithProgress.run(rel.asset, to: dest) { p in
                Task { @MainActor in UpdateBadge.shared.progress = p }
            }
        } catch {
            let a = NSAlert()
            a.messageText = String(localized: "Il download non è riuscito")
            a.informativeText = String(localized: "Riprova, oppure scarica l’aggiornamento dalla pagina di GitHub e aprilo con un doppio clic.")
            a.addButton(withTitle: String(localized: "Apri la pagina"))
            a.addButton(withTitle: String(localized: "Chiudi"))
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
        a.addButton(withTitle: String(localized: "OK"))
        NSApp.activate()
        a.runModal()
    }
}

/// 4.1.2 · La versione nuova trovata dal controllo automatico: fa comparire il pulsante in alto a destra
/// (e una riga nel menu in alto). Sparisce quando non serve più.
@MainActor
final class UpdateBadge: ObservableObject {
    static let shared = UpdateBadge()
    @Published var available: UpdateCheck.Release? = nil
    @Published var installing = false
    /// 4.5.1 · Quanto è stato scaricato (0…1), mostrato sul pulsante
    @Published var progress: Double = 0
    /// Il testo del pulsante mentre scarica: «Scarico l’aggiornamento… 86%»
    var downloadingText: String {
        let pct = Int((progress * 100).rounded(.down))
        return String(localized: "Scarico l’aggiornamento… \(pct)%")
    }
}

/// 4.5.1 · Download con l'avanzamento: lo stesso file di prima, scaricato con un delegato che dice quanti byte
/// sono arrivati. Il file viene spostato al suo posto appena finisce (il file temporaneo sparisce subito dopo).
final class DownloadWithProgress: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private let dest: URL
    private let onProgress: @Sendable (Double) -> Void
    private var cont: CheckedContinuation<Void, Error>?
    private var lastPct = -1
    private let lock = NSLock()

    private init(dest: URL, onProgress: @escaping @Sendable (Double) -> Void) {
        self.dest = dest
        self.onProgress = onProgress
    }

    static func run(_ url: URL, to dest: URL, onProgress: @escaping @Sendable (Double) -> Void) async throws {
        let d = DownloadWithProgress(dest: dest, onProgress: onProgress)
        let session = URLSession(configuration: .default, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            d.lock.lock(); d.cont = c; d.lock.unlock()
            session.downloadTask(with: url).resume()
        }
    }

    private func finish(_ r: Result<Void, Error>) {
        lock.lock(); let c = cont; cont = nil; lock.unlock()
        c?.resume(with: r)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let p = min(1, Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
        let pct = Int(p * 100)
        lock.lock(); let changed = pct != lastPct; lastPct = pct; lock.unlock()
        if changed { onProgress(p) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard (downloadTask.response as? HTTPURLResponse)?.statusCode == 200 else {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        do {
            try? FileManager.default.removeItem(at: dest)
            try FileManager.default.moveItem(at: location, to: dest)
            onProgress(1)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) } else { finish(.failure(URLError(.unknown))) }
    }
}

/// Il pulsante in alto a destra nella finestra, accanto a «Tasti».
struct UpdateBadgeButton: View {
    @ObservedObject var badge = UpdateBadge.shared

    var body: some View {
        if let rel = badge.available {
            Button { Task { @MainActor in await UpdateCheck.install(rel) } } label: {
                Label(badge.installing ? badge.downloadingText : String(localized: "Nuovo aggiornamento: \(rel.version)"),
                      systemImage: badge.installing ? "arrow.down.circle" : "arrow.down.circle.fill")
                    .labelStyle(.titleAndIcon)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(.white)
            }
            // 4.4.1 · Pulsante di sistema colorato: nella barra in alto resta centrato come «Tasti»
            // (con lo sfondo disegnato a mano finiva spostato a sinistra dentro il gruppo della barra)
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(Theme.brass)
            .monospacedDigit()
            .animation(.default, value: badge.installing)
            .allowsHitTesting(!badge.installing)
            .help("È uscita OrbitLR \(rel.version): un clic la scarica e la installa, e OrbitLR si riapre da sola")
            .accessibilityLabel("Installa l’aggiornamento \(rel.version)")
        }
    }
}
