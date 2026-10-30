import AppKit
import SwiftUI
import AVFoundation

final class ParamController: @unchecked Sendable {
    static let shared = ParamController()
    private var panel: NSPanel?
    private var callback: ((String?) -> Void)?
    /// 4.1.4 · Una richiesta arrivata mentre un pannello è aperto (per esempio la password di un PDF in coda)
    /// aspetta il suo turno invece di annullare quella aperta.
    private var waiting: [(ParamKind, Action, [URL], NSPoint, (String?) -> Void)] = []
    /// 5.1 · Il ✕ del pannello chiede alla vista prima di chiudere (il delegato della finestra è debole: lo teniamo qui)
    private var closeGuard: CloseGuard?
    /// 5.1 · Per ⌘Q: il pannello aperto (Taglia, Nascondi un logo, opzioni) può chiedere prima di buttare.
    var openGuard: CloseGuard? { panel == nil ? nil : closeGuard }

    func ask(_ kind: ParamKind, action: Action, files: [URL], at point: NSPoint, done: @escaping (String?) -> Void) {
        if panel != nil {
            waiting.append((kind, action, files, point, done))
            return
        }
        callback = done
        let isTrim = kind == .cut || kind == .gifcut || kind == .ringtone
        let view: AnyView
        let guardian = CloseGuard()
        closeGuard = guardian
        if kind == .hidemark, let url = files.first {
            view = AnyView(HideMarkEditor(url: url, onDone: { [weak self] v in self?.close(v) }, closeGuard: guardian))
        } else if isTrim, let url = files.first(where: { Catalog.kind(of: $0) != .sub }) {
            view = AnyView(TrimEditorView(url: url, mode: kind, onDone: { [weak self] v in self?.close(v) }, closeGuard: guardian))
        } else {
            view = AnyView(ParamView(kind: kind, action: action, files: files,
                                     onDone: { [weak self] v in self?.close(v) }, closeGuard: guardian))
        }
        let host = NSHostingView(rootView: view.background(Theme.cream))
        host.frame.size = host.fittingSize
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
        p.titleVisibility = .hidden
        p.titlebarAppearsTransparent = true
        p.isMovableByWindowBackground = true
        p.level = .floating
        p.contentView = host
        p.setContentSize(host.fittingSize)
        var origin = NSPoint(x: point.x - p.frame.width / 2, y: point.y - p.frame.height / 2)
        if let vf = (NSScreen.screens.first { $0.frame.contains(point) } ?? NSScreen.main)?.visibleFrame {
            origin.x = min(max(origin.x, vf.minX), vf.maxX - p.frame.width)
            origin.y = min(max(origin.y, vf.minY), vf.maxY - p.frame.height)
        }
        p.setFrameOrigin(origin)
        if isTrim || kind == .hidemark { p.center() }
        p.isReleasedWhenClosed = false
        p.delegate = guardian
        WindowClose.once(p) { [weak self, weak p] in
            guard let self, let p, self.panel === p else { return }
            self.panel = nil
            self.closeGuard = nil
            let cb = self.callback
            self.callback = nil
            cb?(nil)
            self.showNextWaiting()
        }
        panel = p
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
    }

    private func close(_ value: String?) {
        let cb = callback
        callback = nil
        let p = panel
        panel = nil
        closeGuard = nil
        // 4.1.4 · Chiusa davvero (non solo nascosta): la finestra e quello che contiene (anche il lettore del taglio) se ne vanno
        p?.close()
        cb?(value)
        showNextWaiting()
    }

    private func showNextWaiting() {
        guard panel == nil, !waiting.isEmpty else { return }
        let (k, a, f, pt, d) = waiting.removeFirst()
        DispatchQueue.main.async { self.ask(k, action: a, files: f, at: pt, done: d) }
    }
}

// MARK: - 5.1 · «Buttare …?» prima di chiudere con del lavoro dentro

/// Avviso con «Continua» predefinito (Invio ed Esc) e «Butta» in rosso, mai predefinito.
/// `true` = l'hai scelto tu: si butta.
enum DiscardAsk {
    static var keepEditing: String {
        String(localized: "discard.keepEditing", defaultValue: "Continua", comment: "Avviso: resta nella finestra senza buttare niente")
    }

    static func confirm(_ title: String, keep: String = DiscardAsk.keepEditing) -> Bool {
        let a = NSAlert()
        a.alertStyle = .warning
        a.messageText = title
        let k = a.addButton(withTitle: keep)          // il primo: predefinito, risponde a Invio
        k.keyEquivalent = "\r"
        let d = a.addButton(withTitle: String(localized: "Butta"))
        d.keyEquivalent = ""
        d.hasDestructiveAction = true
        // 5.1 · Esc = Continua (macOS lo dà da solo solo a un pulsante che si chiama «Cancel»)
        let esc = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { e in
            guard e.keyCode == 53, e.window === a.window else { return e }
            k.performClick(nil)
            return nil
        }
        defer { if let esc { NSEvent.removeMonitor(esc) } }
        return a.runModal() == .alertSecondButtonReturn
    }
}

/// 5.1 · Il ✕ della finestra chiede prima alla vista (che risponde con `DiscardAsk`). Senza domanda si chiude.
final class CloseGuard: NSObject {
    var ask: (() -> Bool)?
}

// 5.1 · Conformità in un'estensione: CloseGuard() resta creabile anche dove il thread principale non è dichiarato
extension CloseGuard: NSWindowDelegate {
    func windowShouldClose(_ sender: NSWindow) -> Bool { ask?() ?? true }
}

/// "45", "1:30", "1:02:30,5" → secondi
func parseTime(_ s: String) -> Double? {
    let t = s.replacingOccurrences(of: " ", with: "").replacingOccurrences(of: ",", with: ".")
    guard !t.isEmpty else { return nil }
    let parts = t.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count <= 3 else { return nil }
    var total = 0.0
    for p in parts {
        guard let v = Double(p), v >= 0 else { return nil }
        total = total * 60 + v
    }
    return total
}

struct ParamView: View {
    let kind: ParamKind
    let action: Action
    let files: [URL]
    let onDone: (String?) -> Void
    var closeGuard: CloseGuard? = nil

    @State var resize = "1920"
    @State var level = "medium"
    @State var mb = "best"            // 3.6 · prima la qualità
    @State var customMB = ""
    @State var start = "0:00"
    @State var end = ""
    @State var pages = "1"
    @State var vres = "1080"
    @State var speed = "1.5"
    @State var degrees = "90"
    @State var order = ""
    @State var password = ""
    @State var password2 = ""
    @State var baseName = ""
    @State var startNumber = "1"
    @State var digits = 3
    @State var error = ""
    @State var savePreset = false
    @State var choice = ""          // manopole delle azioni della 2.5 (sfondo, raddrizza, ingrandisci, scatti)
    @State var aiSize = "2"         // Migliora con IA: dimensione
    @State var aiStrength = "0"     // Migliora con IA: quanto «Più nitido» mescolare (0 = tutto Fedele)
    @State var presetName = ""
    @State var follow = true        // Formato social: segui il soggetto
    @State var videoSeconds: Double? = nil   // 2.7.5 · per il peso previsto di Comprimi e Formato social
    @State var baseline: [String]? = nil     // 5.1 · le scelte com'erano all'apertura

    /// 5.1 · Tutte le scelte del pannello, per capire se hai cambiato qualcosa.
    private var snapshot: [String] {
        [resize, level, mb, customMB, start, end, pages, vres, speed, degrees, order, password, password2,
         baseName, startNumber, String(digits), String(savePreset), choice, aiSize, aiStrength, presetName, String(follow)]
    }

    /// 5.1 · Ci sono modifiche? Prima che il pannello sia pronto (baseline nil) no.
    static func changed(_ now: [String], from base: [String]?) -> Bool {
        guard let base else { return false }
        return now != base
    }

    /// 5.1 · `true` = si può chiudere (niente cambiato, oppure hai scelto «Butta»).
    private func mayDiscard() -> Bool {
        guard Self.changed(snapshot, from: baseline) else { return true }
        return DiscardAsk.confirm(String(localized: "Buttare le scelte fatte?"))
    }

    private var presetable: Bool { [.resize, .icompress, .pdfcompress, .vcompress, .vresize, .speed, .rotate, .removebg, .straighten, .upscale, .aienhance, .stack, .social, .vector].contains(kind) }

    private var fileKind: Kind? { files.first.flatMap { Catalog.kind(of: $0) } }
    private var tint: Color { Theme.color(fileKind) }

    var body: some View {
        // 2.9.4 · Nascondi filigrana: si disegna sull'immagine, ha il suo riquadro
        if kind == .hidemark, let url = files.first {
            HideMarkEditor(url: url, onDone: onDone, closeGuard: closeGuard)
        } else {
            standard
        }
    }

    private var standard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                KindBadge(kind: fileKind, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(action.title).font(.system(size: 15, weight: .bold)).foregroundStyle(Theme.ink)
                    Text(files.count == 1 ? files[0].lastPathComponent : String(localized: "\(files.count) file"))
                        .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            content
            if presetable {
                if UserDefaults.standard.string(forKey: "controlStyle") == "knob" {
                    note(String(localized: "Gira la manopola trascinandola, con la rotellina o con le frecce. Un clic passa alla posizione successiva."))
                        .frame(maxWidth: .infinity, alignment: .center)
                        .multilineTextAlignment(.center)
                }
            }
            if presetable {
                VStack(alignment: .leading, spacing: 6) {
                    Toggle("Salva tra le mie azioni", isOn: $savePreset)
                    if savePreset {
                        TextField("Nome dell’azione, per esempio «Instagram»", text: $presetName)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.parchment.opacity(0.4)))
            }
            if !error.isEmpty {
                Label(error, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12)).foregroundStyle(Theme.color(.pdf))
            }
            HStack {
                Spacer()
                Button("Annulla") { if mayDiscard() { onDone(nil) } }.keyboardShortcut(.cancelAction)
                Button(confirmTitle) { confirm() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent).tint(tint)
            }
        }
        .padding(20)
        .padding(.top, 8)
        .frame(width: 380)
        .onAppear {
            if kind == .gifcut { end = "0:05" }
            if kind == .rename { baseName = Self.suggestedBase(files) }
            if [.removebg, .straighten, .upscale, .stack, .social, .vector].contains(kind) { choice = ParamChoices.defaultValue(for: kind) }
            closeGuard?.ask = { mayDiscard() }
            // 5.1 · Le scelte di partenza, dopo che i valori iniziali si sono assestati
            DispatchQueue.main.async { if baseline == nil { baseline = snapshot } }
        }
    }

    private var toolTitle: String {
        switch kind {
        case .removebg: return String(localized: "Risultato")
        case .straighten: return String(localized: "Come salvarlo")
        case .stack: return String(localized: "Risultato")
        case .vector: return String(localized: "Che cosa è")
        default: return String(localized: "Quanto")
        }
    }

    private var toolNote: String {
        switch kind {
        case .removebg: return String(localized: "Funziona meglio con persone, animali e oggetti ben distinti dallo sfondo.")
        case .straighten: return String(localized: "OrbitLR trova il foglio nella foto, corregge la prospettiva e lo pulisce come una scansione.")
        case .vector: return String(localized: "Rende al meglio con loghi, icone, disegni e firme. «Precisione massima» ricalca ogni curva sul bordo vero, punto per punto: più lento, il risultato più fedele. Tutto sul Mac.")
        case .stack: return String(localized: "Seleziona 3–10 foto della stessa scena (una raffica va benissimo) oppure un video breve: OrbitLR le allinea e le unisce. I dettagli vengono dagli scatti veri.")
        default: return String(localized: "Contorni nitidi con la tecnologia di Apple. Non inventa dettagli che non ci sono.")
        }
    }

    private var confirmTitle: String {
        switch kind {
        case .resize: return String(localized: "Ridimensiona")
        case .pdfcompress, .vcompress, .icompress: return String(localized: "Comprimi")
        case .cut: return String(localized: "Taglia")
        case .gifcut: return String(localized: "Crea la GIF")
        case .extract: return String(localized: "Estrai")
        case .vresize: return String(localized: "Converti")
        case .speed: return String(localized: "Cambia velocità")
        case .rotate: return String(localized: "Ruota")
        case .reorder: return String(localized: "Riordina")
        case .password: return String(localized: "Proteggi")
        case .unlock: return String(localized: "Sblocca")
        case .rename: return String(localized: "Rinomina")
        case .removebg: return String(localized: "Rimuovi lo sfondo")
        case .straighten: return String(localized: "Raddrizza")
        case .upscale: return String(localized: "Ingrandisci")
        case .aienhance: return String(localized: "Migliora")
        case .stack: return String(localized: "Unisci")
        case .social: return String(localized: "Esporta")
        case .ringtone: return String(localized: "Crea la suoneria")
        case .hidemark: return String(localized: "Crea")
        case .vector: return String(localized: "Crea l’SVG")
        }
    }

    /// 2.7.5 · Il peso che avrà il risultato, prima di confermare.
    private func estimateLine(_ t: String) -> some View {
        Label(t, systemImage: "scalemass").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.green)
    }

    /// 4.1.4 · La durata dei video per la stima di «Formato social» (prima non partiva mai: era attaccata
    /// alla riga che compare solo dopo averla calcolata).
    private func loadVideoSeconds() async {
        guard kind == .social, videoSeconds == nil else { return }
        var s = 0.0
        for f in files.prefix(20) {
            let d = (try? await AVURLAsset(url: f).load(.duration).seconds) ?? 0
            if d.isFinite { s += max(0, d) }
        }
        if s > 0 { videoSeconds = s }
    }

    private func note(_ t: String) -> some View {
        Text(t).font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        switch kind {
        case .resize:
            Knob(title: String(localized: "Nuova dimensione"), options: [
                KnobOption(value: "web", short: "Web", label: String(localized: "Per il web (1600 px, JPG leggero)")),
                KnobOption(value: "1280", short: "1280", label: String(localized: "Lato lungo 1280 px")),
                KnobOption(value: "1920", short: "1920", label: String(localized: "Lato lungo 1920 px")),
                KnobOption(value: "3840", short: "4K", label: String(localized: "Lato lungo 3840 px (4K)")),
                KnobOption(value: "half", short: "50%", label: String(localized: "Metà (50%)")),
            ], selection: $resize, tint: tint)
            note(String(localized: "Le foto più piccole della misura scelta non vengono ingrandite."))
        case .pdfcompress:
            Knob(title: String(localized: "Compressione"), options: [
                KnobOption(value: "light", short: String(localized: "Leggera"), label: String(localized: "Leggera (qualità di stampa)")),
                KnobOption(value: "medium", short: String(localized: "Media"), label: String(localized: "Media (consigliata)")),
                KnobOption(value: "strong", short: String(localized: "Forte"), label: String(localized: "Forte (file più piccolo possibile)")),
            ], selection: $level, tint: tint)
        case .vcompress:
            // 3.6 · Prima la qualità: «Stessa qualità» non rovina niente; i pesi servono per i limiti delle app
            Knob(title: String(localized: "Come"), options: (ParamChoices.options(for: .vcompress) ?? []) + [
                KnobOption(value: "custom", short: String(localized: "param.custom", defaultValue: "Altro", comment: "Un valore scelto a mano"), label: String(localized: "Un altro peso massimo, a scelta")),
            ], selection: $mb, tint: tint)
            if mb == "custom" {
                HStack {
                    TextField("MB", text: $customMB).frame(width: 80)
                    Text("MB").foregroundStyle(.secondary)
                }
            }
            if mb == "best" {
                note(String(localized: "Stessa misura e stessa qualità a occhio, con il formato moderno dei video (HEVC): di solito pesa la metà. Funziona anche con film lunghi."))
            } else {
                note(String(localized: "Prima si tengono qualità e misura; la risoluzione scende solo se il peso scelto non basta."))
                estimateLine(SizeEstimate.compressText(current: files.reduce(Int64(0)) { $0 + Job.size(of: $1) },
                                                       targetMB: Int(mb == "custom" ? customMB : mb), files: files.count))
            }
        case .icompress:
            Knob(title: String(localized: "Come"), options: (ParamChoices.options(for: .icompress) ?? []) + [
                KnobOption(value: "custom", short: String(localized: "param.custom", defaultValue: "Altro", comment: "Un valore scelto a mano"), label: String(localized: "Un altro peso massimo, a scelta")),
            ], selection: $mb, tint: tint)
            if mb == "custom" {
                HStack {
                    TextField("KB", text: $customMB).frame(width: 80)
                    Text("KB").foregroundStyle(.secondary)
                }
            }
            note(mb == "best" ? String(localized: "A occhio resta identica, ma pesa meno. JPEG e HEIC restano nel loro formato.")
                              : String(localized: "Si cerca la qualità più alta che sta nel peso; la foto si rimpicciolisce solo se serve. Esce in JPG, senza dati personali (va bene per moduli e siti)."))
        case .hidemark:
            EmptyView()
        case .social:
            Knob(title: String(localized: "Formato"), options: ParamChoices.options(for: .social) ?? [], selection: $choice, tint: tint)
                .task(id: files) { await loadVideoSeconds() }
            Toggle("Inquadra le persone", isOn: $follow)
            if let sec = videoSeconds {
                let predicted: String = SizeEstimate.label(SizeEstimate.socialBytes(seconds: sec, aspect: choice.isEmpty ? "9x16" : choice))
                let current: String = Fmt.bytes(files.reduce(Int64(0)) { $0 + Job.size(of: $1) })
                estimateLine(String(localized: "\(predicted) · ora \(current)"))
            }
            note(String(localized: "L’inquadratura segue le persone (o ciò che si muove in primo piano) con calma, senza scatti. Con scene affollate resta al centro."))
        case .cut, .gifcut, .ringtone:
            HStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Inizio").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("0:00", text: $start).frame(width: 90)
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Fine").font(.system(size: 11)).foregroundStyle(.secondary)
                    TextField("fino alla fine", text: $end).frame(width: 110)
                }
            }
        case .extract:
            TextField("1-3, 5, 8-", text: $pages)
            note(String(localized: "Esempi: 2 · 1-3 · 1,4,7-9 · 5- (dalla 5 alla fine)"))
        case .vresize:
            Knob(title: String(localized: "Risoluzione"), options: [
                KnobOption(value: "480", short: "480p", label: String(localized: "480p (leggero)")),
                KnobOption(value: "720", short: "720p", label: "720p (HD)"),
                KnobOption(value: "1080", short: "1080p", label: "1080p (Full HD)"),
                KnobOption(value: "hevc", short: "HEVC", label: String(localized: "HEVC: stessa risoluzione, file più piccolo")),
            ], selection: $vres, tint: tint)
            note(String(localized: "Vale anche per i video verticali. I video più piccoli non vengono ingranditi."))
        case .speed:
            Knob(title: String(localized: "Velocità"), options: [
                KnobOption(value: "0.5", short: String(localized: "0,5×"), label: String(localized: "0,5× (metà)")),
                KnobOption(value: "0.75", short: String(localized: "0,75×"), label: String(localized: "0,75×")),
                KnobOption(value: "1.25", short: String(localized: "1,25×"), label: String(localized: "1,25×")),
                KnobOption(value: "1.5", short: String(localized: "1,5×"), label: String(localized: "1,5×")),
                KnobOption(value: "2", short: "2×", label: String(localized: "2× (doppia)")),
            ], selection: $speed, tint: tint)
            note(String(localized: "La voce mantiene il suo tono, anche più veloce o più lenta."))
        case .rotate:
            Knob(title: String(localized: "Ruota tutte le pagine"), options: [
                KnobOption(value: "270", short: "↺ 90°", label: String(localized: "90° a sinistra")),
                KnobOption(value: "180", short: "180°", label: "180°"),
                KnobOption(value: "90", short: "↻ 90°", label: String(localized: "90° a destra")),
            ], selection: $degrees, tint: tint)
        case .reorder:
            HStack {
                TextField("es. 3,1,2 oppure 5-1", text: $order)
                Button("Al contrario") { onDone("reverse") }
            }
            note(String(localized: "Le pagine non indicate restano in fondo, nel loro ordine."))
        case .password:
            SecureField("Password", text: $password)
            SecureField("Ripeti la password", text: $password2)
            note(String(localized: "Senza questa password il PDF non si potrà aprire: conservala bene."))
        case .unlock:
            SecureField("Password attuale", text: $password)
        case .aienhance:
            // Con le manopole stanno affiancate; come elenco, una sotto l'altra (altrimenti le scritte si tagliano)
            if UserDefaults.standard.string(forKey: "controlStyle") == "knob" {
                HStack(alignment: .top, spacing: 8) {

                    Knob(title: String(localized: "Dimensione"), options: [
                        KnobOption(value: "1", short: "1×", label: String(localized: "Stessa dimensione")),
                        KnobOption(value: "2", short: "2×", label: String(localized: "Il doppio")),
                        KnobOption(value: "4", short: "4×", label: String(localized: "Quattro volte")),
                    ], selection: $aiSize, tint: tint, size: 86)
                    Knob(title: String(localized: "Intensità"), options: [
                        KnobOption(value: "0", short: "0", label: String(localized: "Fedele: non inventa")),
                        KnobOption(value: "25", short: "25", label: String(localized: "Fedele, un po’ più incisivo")),
                        KnobOption(value: "50", short: "50", label: String(localized: "Metà e metà")),
                        KnobOption(value: "75", short: "75", label: String(localized: "Quasi tutto Più nitido")),
                        KnobOption(value: "100", short: "100", label: String(localized: "Più nitido: ricostruisce texture")),
                    ], selection: $aiStrength, tint: tint, size: 86)
                }
            } else {
                VStack(alignment: .leading, spacing: 12) {

                    Knob(title: String(localized: "Dimensione"), options: [
                        KnobOption(value: "1", short: "1×", label: String(localized: "Stessa dimensione")),
                        KnobOption(value: "2", short: "2×", label: String(localized: "Il doppio")),
                        KnobOption(value: "4", short: "4×", label: String(localized: "Quattro volte")),
                    ], selection: $aiSize, tint: tint, size: 86)
                    Knob(title: String(localized: "Intensità"), options: [
                        KnobOption(value: "0", short: "0", label: String(localized: "Fedele: non inventa")),
                        KnobOption(value: "25", short: "25", label: String(localized: "Fedele, un po’ più incisivo")),
                        KnobOption(value: "50", short: "50", label: String(localized: "Metà e metà")),
                        KnobOption(value: "75", short: "75", label: String(localized: "Quasi tutto Più nitido")),
                        KnobOption(value: "100", short: "100", label: String(localized: "Più nitido: ricostruisce texture")),
                    ], selection: $aiStrength, tint: tint, size: 86)
                }
            }
            note(String(localized: "Intensità 0 = Fedele: pulisce e rende nitido senza inventare. Più sali, più il risultato è incisivo, ma il modello ricostruisce texture che nella foto non c’erano. Tra 1 e 99 si usano tutti e due i modelli (tempo doppio)."))
        case .removebg, .straighten, .upscale, .stack, .vector:
            Knob(title: toolTitle, options: ParamChoices.options(for: kind) ?? [], selection: $choice, tint: tint)
            note(toolNote)
        case .rename:
            TextField("Nome", text: $baseName)
            HStack(spacing: 12) {
                HStack(spacing: 6) {
                    Text("Da").foregroundStyle(.secondary)
                    TextField("1", text: $startNumber).frame(width: 56)
                }
                Picker("Cifre", selection: $digits) {
                    Text("1").tag(1); Text("01").tag(2); Text("001").tag(3); Text("0001").tag(4)
                }
                .frame(width: 140)
            }
            VStack(alignment: .leading, spacing: 3) {
                ForEach(previewNames, id: \.self) { n in
                    Text(n).font(.system(size: 12, design: .monospaced)).foregroundStyle(Theme.ink)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(Theme.parchment.opacity(0.5)))
            note(String(localized: "I file vengono rinominati in ordine di nome. Si può tornare indietro da Attività."))
        }
    }

    private var previewNames: [String] {
        let sorted = files.filter { Catalog.kind(of: $0) != .sub }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        let n0 = Int(startNumber) ?? 1
        let base = baseName.trimmingCharacters(in: .whitespaces).isEmpty ? "File" : baseName.trimmingCharacters(in: .whitespaces)
        var out = sorted.prefix(3).enumerated().map { i, f in
            "\(f.lastPathComponent)  →  \(base) \(String(format: "%0\(digits)d", n0 + i))" + (f.pathExtension.isEmpty ? "" : ".\(f.pathExtension)")
        }
        if sorted.count > 3 { out.append(String(localized: "… e altri \(sorted.count - 3)")) }
        return out
    }

    static func suggestedBase(_ files: [URL]) -> String {
        guard let f = files.first else { return "" }
        var b = f.deletingPathExtension().lastPathComponent
        while let last = b.last, last.isNumber || last == " " || last == "_" || last == "-" { b.removeLast() }
        return b.isEmpty ? "File" : b
    }

    private func confirm() {
        error = ""
        switch kind {
        case .resize: finish(resize)
        case .pdfcompress: finish(level)
        case .vcompress:
            if mb == "custom" {
                let v = customMB.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "mb", with: "")
                guard let n = Int(v), n >= 1 else { error = String(localized: "Scrivi un numero intero, ad esempio 25."); return }
                finish(String(n))
            } else { finish(mb) }
        case .icompress:
            if mb == "custom" {
                let v = customMB.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "kb", with: "")
                guard let n = Int(v), n >= 5 else { error = String(localized: "Scrivi un numero intero di KB, ad esempio 200."); return }
                finish(String(n))
            } else { finish(mb) }
        case .hidemark:
            break
        case .social:
            finish("\(choice.isEmpty ? "9x16" : choice)|\(follow ? 1 : 0)")
        case .cut, .gifcut, .ringtone:
            guard let s = parseTime(start) else { error = String(localized: "Inizio non valido. Esempi: 45 · 1:30"); return }
            if end.trimmingCharacters(in: .whitespaces).isEmpty {
                finish(String(format: "%.3f|", s))
            } else {
                guard let e = parseTime(end), e > s else { error = String(localized: "La fine deve essere dopo l’inizio."); return }
                finish(String(format: "%.3f|%.3f", s, e))
            }
        case .extract:
            let v = pages.replacingOccurrences(of: " ", with: "")
            guard v.range(of: #"^[0-9]+(-[0-9]*)?(,[0-9]+(-[0-9]*)?)*$"#, options: .regularExpression) != nil else {
                error = String(localized: "Formato non valido. Esempi: 2 · 1-3 · 1,4,7-9"); return
            }
            finish(v)
        case .vresize: finish(vres)
        case .speed: finish(speed)
        case .rotate: finish(degrees)
        case .reorder:
            let v = order.replacingOccurrences(of: " ", with: "")
            if v == "reverse" { finish(v); return }
            guard v.range(of: #"^[0-9]+(-[0-9]+)?(,[0-9]+(-[0-9]+)?)*$"#, options: .regularExpression) != nil else {
                error = String(localized: "Formato non valido. Esempi: 3,1,2 · 5-1"); return
            }
            finish(v)
        case .password:
            guard !password.isEmpty else { error = String(localized: "Scrivi una password."); return }
            guard password == password2 else { error = String(localized: "Le due password non coincidono."); return }
            finish(password)
        case .unlock:
            guard !password.isEmpty else { error = String(localized: "Scrivi la password del PDF."); return }
            finish(password)
        case .aienhance:
            finish("b\(aiStrength)-\(aiSize)")
        case .removebg, .straighten, .upscale, .stack, .vector:
            finish(choice.isEmpty ? ParamChoices.defaultValue(for: kind) : choice)
        case .rename:
            let base = baseName.trimmingCharacters(in: .whitespaces)
            guard !base.isEmpty, !base.contains("/"), !base.contains(":") else { error = String(localized: "Scrivi un nome valido (senza / o :)."); return }
            guard let n = Int(startNumber), n >= 0 else { error = String(localized: "Il numero iniziale deve essere un numero intero."); return }
            finish("\(base)|\(n)|\(digits)")
        }
    }

    /// Conferma: se richiesto salva anche il preset, poi avvia.
    private func finish(_ value: String?) {
        if let v = value, savePreset, presetable, let k = fileKind {
            PresetStore.shared.add(name: presetName, kind: k, action: action, param: v)
        }
        onDone(value)
    }
}
