import AppKit

/// Suoni discreti in stile radio: un clic quando passi da uno spicchio all'altro,
/// uno scatto quando confermi, un piccolo «ding» a lavoro finito (solo con l'app in primo piano).
/// Si spengono nelle Opzioni → Aspetto e suoni.
final class Sounds: @unchecked Sendable {
    static let shared = Sounds()

    enum Effect: String, CaseIterable { case tick, select, done, fail, drop }

    private var pools: [Effect: [NSSound]] = [:]
    private var next: [Effect: Int] = [:]
    private var lastTick = Date.distantPast

    private let volume: [Effect: Float] = [.tick: 0.22, .select: 0.38, .done: 0.45, .fail: 0.35, .drop: 0.3]

    var enabled: Bool { UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true }

    /// Carica i suoni una volta sola, all'avvio: così il primo clic non ha ritardi.
    func prepare() {
        for k in Effect.allCases where pools[k] == nil {
            guard let url = Bundle.main.url(forResource: k.rawValue, withExtension: "wav")
                    ?? Bundle.main.url(forResource: k.rawValue, withExtension: "wav", subdirectory: "Sounds"),
                  let base = NSSound(contentsOf: url, byReference: false) else { continue }
            // Più copie dello stesso suono: muovendo il mouse in fretta i clic si sovrappongono senza tagliarsi
            let copies = k == .tick ? 4 : 2
            pools[k] = (0..<copies).compactMap { _ in base.copy() as? NSSound }
            pools[k]?.forEach { $0.volume = volume[k] ?? 0.3 }
        }
    }

    func play(_ k: Effect) {
        guard enabled else { return }
        if k == .tick {
            // Al massimo un clic ogni 35 ms, per non fare «raffiche»
            let now = Date()
            guard now.timeIntervalSince(lastTick) > 0.035 else { return }
            lastTick = now
        }
        if pools[k] == nil { prepare() }
        guard let pool = pools[k], !pool.isEmpty else { return }
        let i = (next[k] ?? 0) % pool.count
        next[k] = i + 1
        let s = pool[i]
        if s.isPlaying { s.stop() }
        s.play()
    }

    static func tick() { shared.play(.tick) }
    static func select() { shared.play(.select) }

    /// 3.1 · Un piccolo tonfo quando un file arriva nella finestra.
    static func drop() { shared.play(.drop) }

    /// 3.1 · Lavoro non riuscito: due note che scendono, piano (solo con OrbitLR in primo piano).
    static func fail() {
        guard NSApp.isActive else { return }
        shared.play(.fail)
    }

    /// Fine lavoro: il ding solo se OrbitLR è in primo piano (altrimenti avvisa già la notifica).
    static func done() {
        guard NSApp.isActive else { return }
        shared.play(.done)
    }
}
