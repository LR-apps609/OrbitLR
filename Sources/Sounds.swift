import AppKit
import AVFoundation

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
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil { prepareEngine() }
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

    // MARK: 3.4.9 · Motore audio: i suoni sono già in memoria e partono subito (entro pochi millesimi)

    private var engine: AVAudioEngine?
    private var nodes: [Effect: [AVAudioPlayerNode]] = [:]
    private var buffers: [Effect: AVAudioPCMBuffer] = [:]
    private var nextNode: [Effect: Int] = [:]

    /// Prepara il motore con un piccolo gruppo di «lettori» per ogni suono (si sovrappongono senza tagliarsi).
    /// Se il Mac non ha un'uscita audio (o qualcosa va storto) restano i suoni di sempre.
    private func prepareEngine() {
        guard engine == nil else { return }
        let e = AVAudioEngine()
        var ok = false
        for k in Effect.allCases {
            guard let url = Bundle.main.url(forResource: k.rawValue, withExtension: "wav")
                    ?? Bundle.main.url(forResource: k.rawValue, withExtension: "wav", subdirectory: "Sounds"),
                  let f = try? AVAudioFile(forReading: url),
                  let b = AVAudioPCMBuffer(pcmFormat: f.processingFormat, frameCapacity: AVAudioFrameCount(f.length)),
                  (try? f.read(into: b)) != nil else { continue }
            buffers[k] = b
            nodes[k] = (0..<(k == .tick ? 4 : 2)).map { _ in
                let n = AVAudioPlayerNode()
                e.attach(n)
                e.connect(n, to: e.mainMixerNode, format: b.format)
                n.volume = volume[k] ?? 0.3
                return n
            }
            ok = true
        }
        guard ok else { return }
        e.prepare()
        do { try e.start(); e.pause(); engine = e } catch { nodes = [:]; buffers = [:] }
    }

    /// true se il suono è partito dal motore audio.
    private var idle: DispatchWorkItem?

    private func playFast(_ k: Effect) -> Bool {
        guard let e = engine, let b = buffers[k], let list = nodes[k], !list.isEmpty else { return false }
        if !e.isRunning { guard (try? e.start()) != nil else { return false } }
        // A riposo il motore si mette in pausa: niente consumo quando OrbitLR non suona
        idle?.cancel()
        let w = DispatchWorkItem { [weak e] in e?.pause() }
        idle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: w)
        let i = (nextNode[k] ?? 0) % list.count
        nextNode[k] = i + 1
        let n = list[i]
        n.stop()
        n.scheduleBuffer(b, at: nil, options: .interrupts)
        n.play()
        return true
    }

    func play(_ k: Effect) {
        guard enabled else { return }
        if k == .tick {
            // Al massimo un clic ogni 35 ms, per non fare «raffiche»
            let now = Date()
            guard now.timeIntervalSince(lastTick) > 0.035 else { return }
            lastTick = now
        }
        if playFast(k) { return }
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
