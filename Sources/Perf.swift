import Foundation
import os
import QuartzCore

// ════════════════════════════════════════════════════════════════════
//  3.4.1 · Misura: cronometri dentro l'app.
//  Ogni momento che deve essere rapido (torta, cambio scheda, anteprima
//  del montaggio, miniature) si misura qui. I tempi:
//  • si vedono in Instruments (segnali «OrbitLR»),
//  • restano in memoria per i test (Perf.last / Perf.samples),
//  • con «Registra i tempi» acceso (defaults write … perfLog -bool YES)
//    finiscono anche in ~/Library/Application Support/LRConverter/tempi.log.
// ════════════════════════════════════════════════════════════════════

enum Perf {
    /// I momenti misurati, con il tempo massimo accettato (secondi) sul Mac di tutti i giorni.
    enum Moment: String, CaseIterable, Sendable {
        case pieOpen = "Apertura della torta"
        case tabSwitch = "Cambio di scheda"
        case previewRebuild = "Anteprima del montaggio"
        case thumbnail = "Miniatura"
        case launch = "Avvio"

        var target: Double {
            switch self {
            case .pieOpen: return 0.15
            case .tabSwitch: return 0.10
            case .previewRebuild: return 0.20
            case .thumbnail: return 0.08
            case .launch: return 1.0
            }
        }
    }

    private static let signposter = OSSignposter(subsystem: "it.ledion.OrbitLR", category: "Fluidità")
    private static let lock = NSLock()
    private static var open: [Moment: (start: CFTimeInterval, state: OSSignpostIntervalState)] = [:]
    private static var store: [Moment: [Double]] = [:]
    static let keep = 50

    static var logging: Bool { UserDefaults.standard.bool(forKey: "perfLog") }

    /// Inizia a misurare un momento (se era già aperto, riparte da adesso).
    static func begin(_ m: Moment) {
        let state = signposter.beginInterval("momento", id: signposter.makeSignpostID(), "\(m.rawValue)")
        lock.withLock { open[m] = (CACurrentMediaTime(), state) }
    }

    /// Chiude la misura: restituisce i secondi passati (nil se non era aperta).
    @discardableResult
    static func end(_ m: Moment) -> Double? {
        let entry: (start: CFTimeInterval, state: OSSignpostIntervalState)? = lock.withLock { open.removeValue(forKey: m) }
        guard let e = entry else { return nil }
        signposter.endInterval("momento", e.state)
        let s = CACurrentMediaTime() - e.start
        record(m, s)
        return s
    }

    /// Misura un blocco di lavoro sincrono.
    @discardableResult
    static func measure<T>(_ m: Moment, _ body: () throws -> T) rethrows -> T {
        let t0 = CACurrentMediaTime()
        defer { record(m, CACurrentMediaTime() - t0) }
        return try body()
    }

    static func record(_ m: Moment, _ seconds: Double) {
        lock.withLock {
            var list = store[m] ?? []
            list.append(seconds)
            if list.count > keep { list.removeFirst(list.count - keep) }
            store[m] = list
        }
        guard logging else { return }
        let line = String(format: "%@ · %@ · %.1f ms%@\n", ISO8601DateFormatter().string(from: Date()), m.rawValue, seconds * 1000,
                          seconds > m.target ? " · LENTO" : "")
        let url = Paths.support.appendingPathComponent("tempi.log")
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
            try? line.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    static func samples(_ m: Moment) -> [Double] { lock.withLock { store[m] ?? [] } }
    static func last(_ m: Moment) -> Double? { samples(m).last }

    /// La mediana: un solo valore storto non sposta il giudizio.
    static func median(_ m: Moment) -> Double? {
        let s = samples(m).sorted()
        guard !s.isEmpty else { return nil }
        return s[s.count / 2]
    }

    static func reset() { lock.withLock { store = [:]; open = [:] } }

    /// Un riassunto leggibile, per «Segnala un problema».
    static var report: String {
        Moment.allCases.compactMap { m in
            median(m).map { String(format: "%@: %.0f ms (obiettivo %.0f ms, %d misure)", m.rawValue, $0 * 1000, m.target * 1000, samples(m).count) }
        }.joined(separator: "\n")
    }
}
