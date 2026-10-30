import Foundation
import AppKit
import SwiftUI
import CoreImage

// ════════════════════════════════════════════════════════════════════
//  2.9.9 · Testi animati nel montaggio.
//  Ogni testo ha un inizio e una fine sulla sequenza, una posizione
//  (si trascina sull'anteprima), un modello e un'animazione d'entrata
//  e d'uscita. Si disegnano sopra il video, fotogramma per fotogramma.
// ════════════════════════════════════════════════════════════════════

struct VPText: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var text = String(localized: "Il tuo testo")
    /// «title» Titolo, «subtitle» Sottotitolo, «caption» Didascalia, «big» Grande
    var style = "title"
    var start = 0.0
    var end = 3.0
    /// Centro del testo, in proporzione (0…1), origine in alto a sinistra
    var x = 0.5
    var y = 0.5
    /// «fade», «slide», «pop», «type» (macchina da scrivere)
    var anim = "fade"
    /// «white», «black», «brass», «sage»
    var color = "white"
    /// 4.0 · «Parola per parola»: quando inizia ogni parola, in secondi dall'inizio del testo
    /// (dai sottotitoli automatici). Senza tempi, le parole si accendono a intervalli uguali.
    var wordTimes: [Double]? = nil
    /// 3.9 · Come si accende la parola detta: «color» (colorata), «box» (evidenziata), «big» (più grande),
    /// «under» (sottolineata). nil = colorata, come nella 3.8.
    var wordStyle: String? = nil

    static let wordStyles: [(id: String, name: String)] = [("color", String(localized: "Colorata")), ("box", String(localized: "Evidenziata")), ("big", String(localized: "Più grande")), ("under", String(localized: "Sottolineata"))]

    static let styles: [(id: String, name: String)] = [("title", String(localized: "Titolo")), ("subtitle", String(localized: "Sottotitolo")), ("caption", String(localized: "Didascalia")), ("big", String(localized: "Grande"))]
    static let anims: [(id: String, name: String)] = [("fade", String(localized: "Dissolvenza")), ("slide", String(localized: "Scorrimento")), ("pop", String(localized: "Pop")),
                                                       ("type", String(localized: "Macchina da scrivere")), ("word", String(localized: "Parola per parola"))]

    /// 4.0 · La parola accesa in un certo momento (per «Parola per parola»).
    func wordIndex(at time: Double) -> Int {
        let n = Self.wordCount(text)
        guard n > 0 else { return 0 }
        let local = time - start
        if let w = wordTimes, w.count == n {
            return max(0, (w.lastIndex { $0 <= local + 0.001 }) ?? 0)
        }
        let d = max(0.1, end - start)
        return min(n - 1, max(0, Int(local / d * Double(n))))
    }
    /// 4.0 · Le parole di un testo: pezzi separati da spazi («l’acqua,» è una parola sola).
    /// Un solo modo di contarle, per l'indice, il disegno e i sottotitoli automatici.
    static func wordRanges(_ text: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        var i = text.startIndex
        while i < text.endIndex {
            while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
            guard i < text.endIndex else { break }
            var j = i
            while j < text.endIndex, !text[j].isWhitespace { j = text.index(after: j) }
            out.append(i..<j); i = j
        }
        return out
    }
    static func wordCount(_ text: String) -> Int { wordRanges(text).count }

    static let colors: [(id: String, name: String, rgb: (Double, Double, Double))] = [
        ("white", String(localized: "Bianco"), (1, 1, 1)), ("black", String(localized: "Nero"), (0.08, 0.08, 0.08)),
        ("brass", String(localized: "Ottone"), (0.85, 0.67, 0.38)), ("sage", String(localized: "Salvia"), (0.62, 0.78, 0.63)),
    ]

    /// Posizione di partenza adatta al modello.
    static func defaultY(_ style: String) -> Double {
        switch style {
        case "caption": return 0.85
        case "subtitle": return 0.75
        default: return 0.5
        }
    }
}

enum TextRender {
    /// 4.0 · Con «Parola per parola» ogni riga ha un disegno per parola: la memoria ha un tetto (circa 300 MB)
    private static let cache: NSCache<NSString, CGImage> = {
        let c = NSCache<NSString, CGImage>()
        c.countLimit = 600
        c.totalCostLimit = 300 * 1024 * 1024
        return c
    }()

    /// Durata dell'entrata e dell'uscita.
    static let inTime = 0.45, outTime = 0.35

    /// Il testo pronto da sovrapporre al fotogramma (coordinate di Core Image), o nil se in quel momento non si vede.
    static func image(_ t: VPText, canvas: CGSize, at time: Double) -> CIImage? {
        guard time >= t.start, time <= t.end, !t.text.isEmpty, canvas.width > 0 else { return nil }
        let pin = min(1, max(0, (time - t.start) / inTime))
        let pout = min(1, max(0, (t.end - time) / outTime))
        func ease(_ v: Double) -> Double { 1 - pow(1 - v, 3) }
        var shown = t.text
        if t.anim == "type" {
            // Macchina da scrivere: una lettera ogni 0,05 s (almeno 0,6 s in tutto)
            let total = max(0.6, Double(t.text.count) * 0.05)
            let n = Int((Double(t.text.count) * min(1, (time - t.start) / total)).rounded(.up))
            shown = String(t.text.prefix(max(1, n)))
        }
        let lit = t.anim == "word" ? t.wordIndex(at: time) : nil
        guard let cg = bitmap(shown, style: t.style, color: t.color, canvas: canvas, highlight: lit, wordStyle: t.wordStyle) else { return nil }
        var img = CIImage(cgImage: cg)
        let w = img.extent.width, h = img.extent.height
        // Centro sulla tela (Core Image ha l'origine in basso), sempre dentro i bordi
        let cx = min(max(CGFloat(t.x) * canvas.width, w / 2), canvas.width - w / 2)
        let cy = min(max((1 - CGFloat(t.y)) * canvas.height, h / 2), canvas.height - h / 2)
        var alpha = t.anim == "type" ? ease(pout) : ease(min(pin, pout))
        var scale: CGFloat = 1
        var dy: CGFloat = 0
        switch t.anim {
        case "slide": dy = -CGFloat(1 - ease(min(pin, pout))) * canvas.height * 0.05
        case "pop":
            let p = min(pin, pout)
            // Un piccolo rimbalzo all'entrata
            let s = 1.70158
            let back = 1 + (s + 1) * pow(p - 1, 3) + s * pow(p - 1, 2)
            scale = CGFloat(0.6 + 0.4 * back)
            alpha = min(1, p * 1.6)
        default: break
        }
        img = img.transformed(by: CGAffineTransform(translationX: -w / 2, y: -h / 2)
            .concatenating(CGAffineTransform(scaleX: scale, y: scale))
            .concatenating(CGAffineTransform(translationX: cx, y: cy + dy)))
        if alpha < 0.999 {
            let a = CGFloat(max(0, alpha))
            img = img.applyingFilter("CIColorMatrix", parameters: [
                "inputRVector": CIVector(x: a, y: 0, z: 0, w: 0), "inputGVector": CIVector(x: 0, y: a, z: 0, w: 0),
                "inputBVector": CIVector(x: 0, y: 0, z: a, w: 0), "inputAVector": CIVector(x: 0, y: 0, z: 0, w: a),
            ])
        }
        return img
    }

    /// Tutti i testi visibili, uno sopra l'altro.
    static func overlay(_ texts: [VPText], on frame: CIImage, canvas: CGSize, at time: Double) -> CIImage {
        var out = frame
        for t in texts { if let img = image(t, canvas: canvas, at: time) { out = img.composited(over: out) } }
        return out.cropped(to: frame.extent)
    }

    /// Il testo disegnato (con il suo fondo, se il modello lo prevede), alla misura giusta per la tela.
    static func bitmap(_ text: String, style: String, color: String, canvas: CGSize, highlight: Int? = nil, wordStyle: String? = nil) -> CGImage? {
        let ws = highlight == nil ? "" : (wordStyle ?? "color")
        let key = "\(style)|\(color)|\(Int(canvas.width))x\(Int(canvas.height))|\(highlight ?? -1)|\(ws)|\(text)" as NSString
        if let c = cache.object(forKey: key) { return c }
        let H = min(canvas.height, canvas.width * 1.25)          // nei video verticali il testo non diventa enorme
        let size: CGFloat, weight: NSFont.Weight
        switch style {
        case "big": size = H * 0.12; weight = .heavy
        case "subtitle": size = H * 0.05; weight = .semibold
        case "caption": size = H * 0.042; weight = .medium
        default: size = H * 0.075; weight = .bold
        }
        let base = NSFont.systemFont(ofSize: max(10, size), weight: weight)
        let font = base.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: base.pointSize) } ?? base
        let rgb = VPText.colors.first { $0.id == color }?.rgb ?? (1, 1, 1)
        let fg = NSColor(srgbRed: rgb.0, green: rgb.1, blue: rgb.2, alpha: 1)
        let para = NSMutableParagraphStyle()
        para.alignment = .center
        para.lineBreakMode = .byWordWrapping
        let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: fg, .paragraphStyle: para]
        let m = NSMutableAttributedString(string: text, attributes: attrs)
        // 4.0 · La parola detta adesso si accende (ottone; sui testi già d'ottone, bianca)
        let lit = color == "brass" ? NSColor.white : NSColor(srgbRed: 0.98, green: 0.78, blue: 0.36, alpha: 1)
        var litRange: NSRange? = nil
        if let h = highlight {
            // Le parole contate come in wordIndex: pezzi separati da spazi («l’acqua,» è una parola sola)
            let all = VPText.wordRanges(text)
            if all.indices.contains(h) {
                let r = NSRange(all[h], in: text)
                litRange = r
                switch ws {
                case "box":
                    // 3.9 · Evidenziata: la parola su un riquadro colorato (disegnato sotto), scritta scura
                    m.addAttribute(.foregroundColor, value: NSColor(white: 0.08, alpha: 1), range: r)
                case "big":
                    // 3.9 · Più grande: la parola cresce e diventa più spessa
                    let bigBase = NSFont.systemFont(ofSize: font.pointSize * 1.25, weight: .black)
                    let big = bigBase.fontDescriptor.withDesign(.rounded).flatMap { NSFont(descriptor: $0, size: bigBase.pointSize) } ?? bigBase
                    m.addAttributes([.font: big, .foregroundColor: lit], range: r)
                case "under":
                    m.addAttributes([.foregroundColor: lit, .underlineStyle: NSUnderlineStyle.thick.rawValue, .underlineColor: lit], range: r)
                default:
                    m.addAttribute(.foregroundColor, value: lit, range: r)
                }
            }
        }
        let s: NSAttributedString = m
        let maxW = canvas.width * 0.88
        let box = style == "subtitle" || style == "caption"
        let padX = box ? font.pointSize * 0.55 : font.pointSize * 0.25
        let padY = box ? font.pointSize * 0.3 : font.pointSize * 0.25
        let r = s.boundingRect(with: CGSize(width: maxW - padX * 2, height: .greatestFiniteMagnitude),
                               options: [.usesLineFragmentOrigin, .usesFontLeading])
        let w = Int(ceil(r.width + padX * 2)), h = Int(ceil(r.height + padY * 2))
        guard w > 0, h > 0, let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
        if box {
            // Fondo scuro (o chiaro, se il testo è nero) con gli angoli arrotondati
            let bg = color == "black" ? NSColor(white: 1, alpha: 0.82) : NSColor(white: 0, alpha: 0.55)
            bg.setFill()
            NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: w, height: h), xRadius: font.pointSize * 0.35, yRadius: font.pointSize * 0.35).fill()
        } else {
            let sh = NSShadow()
            sh.shadowColor = color == "black" ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.55)
            sh.shadowBlurRadius = font.pointSize * 0.12
            sh.shadowOffset = NSSize(width: 0, height: -font.pointSize * 0.04)
            sh.set()
        }
        if ws == "box", let lr = litRange {
            // Dove sta la parola: la stessa impaginazione del testo, con l'origine in alto
            let storage = NSTextStorage(attributedString: s)
            let lm = NSLayoutManager()
            let tc = NSTextContainer(size: CGSize(width: CGFloat(w) - padX * 2, height: .greatestFiniteMagnitude))
            tc.lineFragmentPadding = 0
            lm.addTextContainer(tc)
            storage.addLayoutManager(lm)
            let glyphs = lm.glyphRange(forCharacterRange: lr, actualCharacterRange: nil)
            let wr = lm.boundingRect(forGlyphRange: glyphs, in: tc)
            let used = lm.usedRect(for: tc)
            // Righe centrate: lo spostamento tra il riquadro usato e la larghezza disponibile è già dentro wr
            let px = font.pointSize * 0.12, py = font.pointSize * 0.02
            let rect = NSRect(x: padX + wr.minX - px, y: padY + (max(used.height, r.height) - wr.maxY) - py,
                              width: wr.width + px * 2, height: wr.height + py * 2)
            NSShadow().set()            // il riquadro senza ombra
            lit.setFill()
            NSBezierPath(roundedRect: rect, xRadius: font.pointSize * 0.22, yRadius: font.pointSize * 0.22).fill()
            if !box {
                let sh = NSShadow()
                sh.shadowColor = color == "black" ? NSColor(white: 1, alpha: 0.5) : NSColor(white: 0, alpha: 0.55)
                sh.shadowBlurRadius = font.pointSize * 0.12
                sh.shadowOffset = NSSize(width: 0, height: -font.pointSize * 0.04)
                sh.set()
            }
        }
        s.draw(with: NSRect(x: padX, y: padY, width: CGFloat(w) - padX * 2, height: r.height),
               options: [.usesLineFragmentOrigin, .usesFontLeading])
        NSGraphicsContext.restoreGraphicsState()
        guard let img = ctx.makeImage() else { return nil }
        cache.setObject(img, forKey: key, cost: img.bytesPerRow * img.height)
        return img
    }
}

// MARK: - Lo strumento «Testi» (2.9.10: in colonna, nel pannello a destra)

struct TextOptions: View {
    @ObservedObject var s: VideoProjectStore
    let undo: UndoManager?
    let tint: Color
    let add: () -> Void
    @FocusState private var focused: Bool
    @State private var typingBefore: VideoProject? = nil
    /// 3.3 · Sottotitoli automatici in corso, e l'esito in una frase.
    @State private var listening = false
    /// 5.1 · avanzamento e annullamento dei sottotitoli automatici
    @State private var listenProgress = 0.0
    @State private var listenTask: Task<Void, Never>? = nil
    @State private var subsNote: String? = nil

    private var texts: [VPText] { s.project.texts ?? [] }
    private var current: VPText? { texts.first { $0.id == s.selectedText } }

    private func edit(_ name: String, _ f: @escaping (inout VPText) -> Void) {
        guard let id = s.selectedText else { return }
        s.change(undo, name) { p in
            guard let i = p.texts?.firstIndex(where: { $0.id == id }) else { return }
            f(&p.texts![i])
        }
    }

    /// Un testo nuovo dall'indicatore, per 3 secondi, già scelto e pronto da scrivere.
    static func addText(_ s: VideoProjectStore, undo: UndoManager?) {
        let total = s.project.duration
        guard total > 0.3 else { s.refuse(String(localized: "Aggiungi prima un video: il testo va sopra il montaggio.")); return }
        var t = VPText()
        t.start = min(max(0, s.clock.time), max(0, total - 1))
        t.end = min(total, t.start + 3)
        let id = t.id
        s.change(undo, String(localized: "Aggiungi un testo")) { p in p.texts = (p.texts ?? []) + [t] }
        s.selectedText = id
        s.seek(t.start + 0.05)
        s.focusTextPending = true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button(action: add) { Label("Aggiungi un testo", systemImage: "plus").frame(maxWidth: .infinity) }
                .primaryButton()
            // 3.3 · Le parole dette nelle clip diventano sottotitoli, al momento giusto
            if listening {
                // 5.1 · Avanzamento e Interrompi
                HStack(spacing: 8) {
                    ProgressView(value: listenProgress).controlSize(.small)
                    Text("Ascolto le clip… \(Int(listenProgress * 100))%").font(.system(size: 12)).monospacedDigit()
                    Button("Interrompi") { listenTask?.cancel() }.controlSize(.small)
                }
            } else {
                Button {
                    listening = true
                    listenProgress = 0
                    subsNote = nil
                    listenTask = Task { @MainActor in
                        subsNote = await AutoSubtitles.run(s, undo: undo) { p in listenProgress = p }
                        listening = false
                        listenTask = nil
                    }
                } label: {
                    Label("Sottotitoli automatici", systemImage: "captions.bubble").frame(maxWidth: .infinity)
                }
                .disabled(s.project.clips.isEmpty)
                .help(s.project.clips.isEmpty ? String(localized: "Aggiungi prima un video.") : String(localized: "OrbitLR ascolta le clip e scrive i sottotitoli in basso. Poi li correggi come gli altri testi; ⌘Z li toglie tutti"))
            }
            if let n = subsNote {
                Text(n).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !texts.isEmpty {
                VStack(spacing: 2) {
                    ForEach(Array(texts.enumerated()), id: \.element.id) { i, t in
                        Button {
                            s.selectedText = t.id
                            s.seek(t.start + 0.05)
                        } label: {
                            HStack {
                                Text("\(i + 1). " + (t.text.isEmpty ? String(localized: "(vuoto)") : t.text)).lineLimit(1)
                                Spacer(minLength: 4)
                                Text(formatShort(t.start)).monospacedDigit().foregroundStyle(.secondary)
                            }
                            .font(.system(size: 12))
                            .padding(.horizontal, 8).padding(.vertical, 5)
                            .background(RoundedRectangle(cornerRadius: Radius.s).fill(t.id == s.selectedText ? Theme.brass.opacity(0.3) : Color.clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if let t = current {
                Divider()
                TextField("Scrivi qui il testo", text: Binding(get: { t.text }, set: { v in
                    guard let id = s.selectedText else { return }
                    s.live { p in if let i = p.texts?.firstIndex(where: { $0.id == id }) { p.texts![i].text = v } }
                }), axis: .vertical)
                .lineLimit(1...4)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                row(String(localized: "Modello")) {
                    Picker("", selection: Binding(get: { t.style }, set: { v in edit(String(localized: "Modello del testo")) { $0.style = v; $0.y = VPText.defaultY(v) } })) {
                        ForEach(VPText.styles, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 150)
                }
                row(String(localized: "Animazione")) {
                    Picker("", selection: Binding(get: { t.anim }, set: { v in edit(String(localized: "Animazione del testo")) { $0.anim = v } })) {
                        ForEach(VPText.anims, id: \.id) { Text($0.name).tag($0.id) }
                    }
                    .labelsHidden().frame(width: 150)
                }
                if t.anim == "word" {
                    row(String(localized: "Parola detta")) {
                        Picker("", selection: Binding(get: { t.wordStyle ?? "color" }, set: { v in edit(String(localized: "Stile della parola detta")) { $0.wordStyle = v } })) {
                            ForEach(VPText.wordStyles, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        .labelsHidden().frame(width: 150)
                        .help("Come si accende la parola mentre viene detta")
                    }
                }
                row(String(localized: "Colore")) {
                    HStack(spacing: 6) {
                        ForEach(VPText.colors, id: \.id) { c in
                            Button { edit(String(localized: "Colore del testo")) { $0.color = c.id } } label: {
                                Circle().fill(Color(.sRGB, red: c.rgb.0, green: c.rgb.1, blue: c.rgb.2))
                                    .frame(width: 20, height: 20)
                                    .overlay(Circle().strokeBorder(t.color == c.id ? Theme.brass : Theme.ink.opacity(0.25), lineWidth: t.color == c.id ? 2.5 : 1))
                                    .hitArea()
                            }
                            .buttonStyle(.plain).help(c.name)
                        }
                    }
                }
                row(String(localized: "Quando")) {
                    Text("\(formatShort(t.start)) → \(formatShort(t.end))").font(.system(size: 12)).monospacedDigit()
                }
                HStack(spacing: 6) {
                    Button("Inizia qui") { let now = s.clock.time; edit(String(localized: "Inizio del testo")) { $0.start = min(now, $0.end - 0.3) } }
                        .help("Il testo comincia nel punto dell’indicatore")
                    Button("Finisci qui") { let now = s.clock.time; edit(String(localized: "Fine del testo")) { $0.end = max(now, $0.start + 0.3) } }
                        .help("Il testo finisce nel punto dell’indicatore")
                    Spacer()
                    Button(role: .destructive) { remove() } label: { Image(systemName: "trash") }
                        .help("Togli questo testo").accessibilityLabel("Togli il testo")
                }
                .controlSize(.small)
                Text("Per spostarlo, trascinalo sull’anteprima. Nella sequenza, sotto le clip, trascini il blocco o i suoi bordi.")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else if texts.isEmpty {
                Text("Il testo compare dal punto dell’indicatore per 3 secondi. Poi lo scrivi qui e lo trascini sull’anteprima.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear {
            if s.selectedText == nil { s.selectedText = texts.first?.id }
            focusIfAsked()
        }
        .onChange(of: focused) { _, f in
            s.typing = f
            // 4.1.5 · Quello che scrivi si annulla con ⌘Z (una volta, quando esci dal campo)
            if f { typingBefore = s.project } else if let b = typingBefore { s.commit(from: b, undo, String(localized: "Scrivi il testo")); typingBefore = nil }
        }
        .onChange(of: s.focusTextPending) { _, _ in focusIfAsked() }
        .onDisappear { s.typing = false }
    }

    /// Il campo nasce insieme al testo: si aspetta un attimo prima di metterci il cursore.
    private func focusIfAsked() {
        guard s.focusTextPending else { return }
        s.focusTextPending = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { focused = true }
    }

    private func row<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack {
            Text(title).font(.system(size: 12))
            Spacer(minLength: 6)
            content()
        }
    }

    private func remove() {
        guard let id = s.selectedText else { return }
        s.change(undo, String(localized: "Togli il testo")) { p in
            p.texts?.removeAll { $0.id == id }
            if p.texts?.isEmpty == true { p.texts = nil }
        }
        s.selectedText = s.project.texts?.first?.id
        focused = false
    }
}

/// Sull'anteprima: i riquadri dei testi visibili, da trascinare. Il testo vero lo disegna il video.
struct TextDragLayer: View {
    @ObservedObject var s: VideoProjectStore
    @ObservedObject var clock: PlayClock
    @Environment(\.undoManager) private var undo
    @State private var before: VideoProject? = nil

    var body: some View {
        GeometryReader { g in
            let vs = s.canvasSize.width > 0 ? s.canvasSize : CGSize(width: 16, height: 9)
            let fit = min(g.size.width / vs.width, g.size.height / vs.height)
            let vw = vs.width * fit, vh = vs.height * fit
            let vx = (g.size.width - vw) / 2, vy = (g.size.height - vh) / 2
            ForEach(s.project.texts ?? []) { t in
                if clock.time >= t.start && clock.time <= t.end {
                    let canvasPx = CGSize(width: vw, height: vh)
                    let size = Self.boxSize(t, canvas: canvasPx)
                    let cx = min(max(CGFloat(t.x) * vw, size.width / 2), vw - size.width / 2)
                    let cy = min(max(CGFloat(t.y) * vh, size.height / 2), vh - size.height / 2)
                    RoundedRectangle(cornerRadius: Radius.xs)
                        .strokeBorder(s.selectedText == t.id ? Theme.brass : Color.white.opacity(0.6),
                                      style: StrokeStyle(lineWidth: s.selectedText == t.id ? 2 : 1, dash: [4, 3]))
                        .frame(width: size.width + 8, height: size.height + 6)
                        .contentShape(Rectangle())
                        .position(x: vx + cx, y: vy + cy)
                        .gesture(DragGesture(minimumDistance: 2)
                            .onChanged { v in
                                if before == nil { before = s.project; s.selectedText = t.id }
                                let nx = min(1, max(0, (v.location.x - vx) / vw)), ny = min(1, max(0, (v.location.y - vy) / vh))
                                s.live { p in
                                    if let i = p.texts?.firstIndex(where: { $0.id == t.id }) { p.texts![i].x = nx; p.texts![i].y = ny }
                                }
                            }
                            .onEnded { _ in
                                if let b = before { s.commit(from: b, undo, String(localized: "Sposta il testo")) }
                                before = nil
                            })
                        .onTapGesture(count: 2) { s.selectedText = t.id; s.focusTextPending = true }
                        .onTapGesture { s.selectedText = t.id }
                        .help("Trascina per spostare il testo · doppio clic per scriverci")
                }
            }
        }
    }

    /// La misura del riquadro del testo sull'anteprima (la stessa proporzione del video).
    static func boxSize(_ t: VPText, canvas: CGSize) -> CGSize {
        guard let cg = TextRender.bitmap(t.text.isEmpty ? " " : t.text, style: t.style, color: t.color, canvas: canvas) else {
            return CGSize(width: 60, height: 20)
        }
        return CGSize(width: cg.width, height: cg.height)
    }
}
