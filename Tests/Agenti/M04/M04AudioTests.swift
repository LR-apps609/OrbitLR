import XCTest
import AVFoundation
import Speech

/// M04 · Azioni audio native (suoneria .m4r, vocale leggero, taglia/normalizza nativi, unisci, trascrizione di macOS)
/// sui file generati dal workflow in /tmp/m04fx. Ogni risultato va in /tmp/m04-nativo.tsv.
/// Ogni lavoro ha un tempo massimo: se non finisce, la riga dice BLOCCATO.
final class M04AudioTests: XCTestCase {
    static let fx = URL(fileURLWithPath: ProcessInfo.processInfo.environment["M04_FX"] ?? "/tmp/m04fx")
    static let out = URL(fileURLWithPath: "/tmp/m04-nativo-out")
    static let tsv = URL(fileURLWithPath: "/tmp/m04-nativo.tsv")
    static var n = 0

    override class func setUp() {
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: tsv.path) {
            try? "n\tazione\tparam\tfile\tnativo\tesito\tsecondi\tmessaggio\tuscite\n".write(to: tsv, atomically: true, encoding: .utf8)
        }
    }

    static func line(_ s: String) {
        let h = try! FileHandle(forWritingTo: tsv); h.seekToEndOfFile(); h.write((s + "\n").data(using: .utf8)!); h.closeFile()
        print("M04: " + s)
    }

    static let ffprobe: String? = {
        for p in ["/Applications/OrbitLR.app/Contents/Resources/Motori/ffprobe", "/opt/homebrew/bin/ffprobe", "/usr/local/bin/ffprobe"]
            where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }()

    static func probe(_ f: URL) -> String {
        guard let fp = ffprobe else { return "{\(f.lastPathComponent) size=\(Job.size(of: f))}" }
        let p = Process(); p.executableURL = URL(fileURLWithPath: fp)
        p.arguments = ["-v", "error", "-show_entries", "format=format_name,duration:stream=codec_name,sample_rate,channels,bits_per_raw_sample,sample_fmt",
                       "-of", "default=nw=1", f.path]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try? p.run(); p.waitUntilExit()
        let s = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        return "{\(f.lastPathComponent): \(s.replacingOccurrences(of: "\n", with: " "))size=\(Job.size(of: f))}"
    }

    /// Lancia l'azione come fa l'app (NativeEngine.run, poi la verifica dell'uscita), con un tempo massimo.
    @discardableResult
    func act(_ id: String, _ param: String, _ files: [String], limit: Double = 240) -> (ok: Bool, outs: [URL], msg: String) {
        Self.n += 1
        let n = Self.n
        let urls = files.map { Self.fx.appendingPathComponent($0) }
        let label = files.joined(separator: "+")
        guard urls.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else {
            Self.line("\(n)\t\(id)\t\(param)\t\(label)\t-\tMANCA-FIXTURE\t0\t\t"); return (false, [], "manca")
        }
        let kind = Catalog.kind(of: urls[0]) ?? .audio
        guard let action = Catalog.action(id: id, kind: kind) else {
            Self.line("\(n)\t\(id)\t\(param)\t\(label)\t-\tNO-AZIONE\t0\tazione non disponibile per \(kind)\t"); return (false, [], "no azione")
        }
        let dir = Self.out.appendingPathComponent("\(n)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let job = Job(files: urls, action: action, param: param)
        job.destOverride = dir
        let native = NativeEngine.supports(job) || Media.ids.contains(id)
        final class Box: @unchecked Sendable { var outs: [URL] = []; var err: String? = nil; var verify: String? = nil }
        let box = Box()
        let sema = DispatchSemaphore(value: 0)
        let t0 = Date()
        Task.detached {
            do {
                let o: URL
                if Media.multi.contains(id) {
                    o = try await Media.runMulti(job: job, files: urls, dir: dir) { _ in }
                } else {
                    o = try await NativeEngine.run(job: job, file: urls[0]) { _ in }
                }
                box.outs = [o] + job.outputs.filter { $0 != o }
                box.verify = await Verifier.problem(o)
            } catch {
                box.err = "\(error)"
            }
            sema.signal()
        }
        let finished = sema.wait(timeout: .now() + limit) == .success
        let secs = String(format: "%.1f", Date().timeIntervalSince(t0))
        if !finished {
            job.cancelRequested = true
            Self.line("\(n)\t\(id)\t\(param)\t\(label)\t\(native)\tBLOCCATO\t\(secs)\toltre \(Int(limit)) s senza risposta\t")
            _ = sema.wait(timeout: .now() + 20)
            return (false, [], "bloccato")
        }
        // Anche i file rimasti nella cartella (es. il .txt della trascrizione)
        let all = ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).sorted { $0.path < $1.path }
        let outs = all.isEmpty ? box.outs : all
        let msg = (box.err ?? "") + (box.verify.map { " VERIFICA: \($0)" } ?? "")
        let esito = box.err == nil ? (box.verify == nil ? "OK" : "VERIFICA-KO") : "ERRORE"
        Self.line("\(n)\t\(id)\t\(param)\t\(label)\t\(native)\t\(esito)\t\(secs)\t\(msg.replacingOccurrences(of: "\n", with: " "))\t\(outs.map(Self.probe).joined(separator: " "))")
        return (box.err == nil, outs, msg)
    }

    static func duration(_ u: URL) -> Double {
        let a = AVURLAsset(url: u)
        final class D: @unchecked Sendable { var v = -1.0 }
        let d = D()
        let sema = DispatchSemaphore(value: 0)
        Task.detached { d.v = (try? await a.load(.duration).seconds) ?? -1; sema.signal() }
        _ = sema.wait(timeout: .now() + 20)
        return d.v
    }
    static func streamInfo(_ u: URL) -> (rate: Double, ch: Int, bits: Int, fmt: String) {
        guard let f = try? AVAudioFile(forReading: u) else { return (0, 0, 0, "?") }
        let d = f.fileFormat.streamDescription.pointee
        let id = d.mFormatID
        let cc = String(bytes: [UInt8((id >> 24) & 255), UInt8((id >> 16) & 255), UInt8((id >> 8) & 255), UInt8(id & 255)], encoding: .ascii) ?? "?"
        return (d.mSampleRate, Int(d.mChannelsPerFrame), Int(d.mBitsPerChannel), cc)
    }
    static func brand(_ u: URL) -> String {
        guard let h = try? FileHandle(forReadingFrom: u), let d = try? h.read(upToCount: 12), d.count == 12 else { return "?" }
        return String(data: d.subdata(in: 4..<12), encoding: .ascii) ?? "?"
    }

    // MARK: Suoneria iPhone

    func test1Ringtone() {
        let files = ["corto3s.wav", "voce_vbr.mp3", "voce.m4a", "voce.flac", "voce.ogg", "hd_24_96.wav", "hd_24_96.flac",
                     "mono.wav", "surround51.wav", "surround51.m4a", "surround51.flac", "lungo2h.m4a",
                     "Caffè città — è già.wav", "L'ultima nota (versione 2).m4a", "rotto.mp3", "vuoto.wav", "tutto_muto.wav"]
        for f in files {
            let t0 = Date()
            let r = act("ringtone", "", [f])
            let secs = Date().timeIntervalSince(t0)
            guard r.ok, let o = r.outs.first(where: { $0.pathExtension == "m4r" }) else { continue }
            let d = Self.duration(o), si = Self.streamInfo(o), b = Self.brand(o)
            Self.line("  controllo suoneria \(f): durata=\(String(format: "%.3f", d)) Hz=\(si.rate) canali=\(si.ch) formato=\(si.fmt) ftyp=\(b) secondi=\(String(format: "%.1f", secs))")
            XCTAssertLessThanOrEqual(d, 30.05, "\(f): suoneria oltre 30 s")
            XCTAssertEqual(o.pathExtension, "m4r")
            XCTAssertEqual(si.fmt, "aac ", "\(f): la suoneria non è AAC")
        }
        // Selezioni: oltre 30 s, al contrario, oltre la fine, da metà di un file lungo
        for (f, p) in [("lungo2h.m4a", "0|45|1|1"), ("lungo2h.m4a", "3590|3640|0|0"), ("voce_vbr.mp3", "10|2|1|1"),
                       ("corto3s.wav", "5|9|1|1"), ("corto3s.wav", "2.9|3|1|1"), ("pause.wav", "abc|xyz|1|1"),
                       ("lungo2h.m4a", "7190|7300|1|1"), ("surround51.m4a", "1|4|1|0")] {
            let r = act("ringtone", p, [f])
            guard r.ok, let o = r.outs.first(where: { $0.pathExtension == "m4r" }) else { continue }
            let d = Self.duration(o)
            Self.line("  controllo suoneria \(f) [\(p)]: durata=\(String(format: "%.3f", d))")
            XCTAssertLessThanOrEqual(d, 30.05, "\(f) [\(p)]: suoneria oltre 30 s")
            XCTAssertGreaterThan(d, 0.05, "\(f) [\(p)]: suoneria vuota")
        }
    }

    // MARK: Vocale leggero (comprimi), taglia e normalizza nativi, unisci

    func test2Compress() {
        for f in ["voce_vbr.mp3", "hd_24_96.wav", "surround51.m4a", "voce.flac", "lungo2h.m4a", "Perché così.wav".decomposedStringWithCanonicalMapping] {
            act("whatsapp", "", [f], limit: 600)
        }
    }

    func test3NativeCutNormalize() {
        for f in ["hd_24_96.wav", "voce_24.aiff", "mono.wav", "surround51.wav", "corto3s.wav", "voce_vbr.mp3", "voce.m4a"] {
            for (id, p) in [("cut", "1.000|3.000"), ("normalize", ""), ("cut", "5.000|8.000"), ("to:m4a", "")] {
                let r = act(id, p, [f])
                if r.ok, let o = r.outs.first {
                    let s = Self.streamInfo(Self.fx.appendingPathComponent(f)), d = Self.streamInfo(o)
                    Self.line("  confronto \(id) \(f): prima \(s.rate) Hz \(s.ch) can. \(s.bits) bit → dopo \(d.rate) Hz \(d.ch) can. \(d.bits) bit, durata \(String(format: "%.3f", Self.duration(o)))")
                }
            }
        }
        act("cut", "3600.000|3630.000", ["lungo2h.m4a"])
        act("normalize", "", ["lungo2h.m4a"], limit: 600)
    }

    func test4Merge() {
        act("amerge", "", ["voce_it.wav", "hd_24_96.flac", "surround51.m4a", "mono.wav"])
        act("amerge", "", ["voce_vbr.mp3", "voce.ogg"])
    }

    // MARK: Trascrizione di macOS (senza Whisper)

    func test5TranscribeNative() {
        let st = SFSpeechRecognizer.authorizationStatus()
        let it = SFSpeechRecognizer(locale: Locale(identifier: "it-IT"))
        let en = SFSpeechRecognizer(locale: Locale(identifier: "en-US"))
        Self.line("  riconoscimento: permesso=\(st.rawValue) it.disponibile=\(it?.isAvailable ?? false) it.sulMac=\(it?.supportsOnDeviceRecognition ?? false) en.sulMac=\(en?.supportsOnDeviceRecognition ?? false)")
        guard st == .authorized else {
            Self.line("  trascrizione nativa: permesso non dato su questo Mac (stato \(st.rawValue)), salto per non aprire richieste")
            return
        }
        for f in ["voce_it.wav", "voce_en.wav", "pause.wav", "tutto_muto.wav"] {
            let r = act("transcribe", "", [f], limit: 180)
            for o in r.outs where o.pathExtension == "txt" {
                Self.line("  testo \(f): " + ((try? String(contentsOf: o, encoding: .utf8)) ?? "?").replacingOccurrences(of: "\n", with: " "))
            }
        }
    }
}
