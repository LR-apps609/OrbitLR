import SwiftUI
import AppKit
import PDFKit

// ════════════════════════════════════════════════════════════════════
//  «Modifica PDF» (punto 9): compilare i moduli, firmare, aggiungere data e testo,
//  oscurare per davvero. L'originale non si tocca: si salva sempre una copia.
// ════════════════════════════════════════════════════════════════════

/// La firma disegnata una volta e ricordata (PNG trasparente nella cartella di OrbitLR).
enum SignatureStore {
    /// 5.1 · La cartella si può cambiare solo nei test (mai toccare la firma vera).
    static var folder: URL = Paths.support
    static var url: URL { folder.appendingPathComponent("firma.png") }
    /// 5.1 · La firma di prima, tenuta a parte quando la cambi.
    static var previousURL: URL { folder.appendingPathComponent("firma-precedente.png") }
    static func load() -> NSImage? { NSImage(contentsOf: url) }
    static func data() -> Data? { try? Data(contentsOf: url) }
    static func png(_ img: NSImage) -> Data? {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .png, properties: [:])
    }
    static func save(_ img: NSImage) {
        if let d = png(img) { write(d) }
    }
    /// 5.1 · Scrive la firma (nil = la toglie). Quella che c'era resta in firma-precedente.png.
    static func write(_ d: Data?) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let old = data() { try? old.write(to: previousURL, options: .atomic) }
        if let d { try? d.write(to: url, options: .atomic) } else { try? FileManager.default.removeItem(at: url) }
    }
}

/// Un'immagine (la firma) appoggiata sulla pagina.
final class ImageStampAnnotation: PDFAnnotation {
    var image: NSImage

    init(image: NSImage, bounds: CGRect) {
        self.image = image
        super.init(bounds: bounds, forType: .stamp, withProperties: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
        context.saveGState()
        context.interpolationQuality = .high
        context.draw(cg, in: bounds)
        context.restoreGState()
    }
}

enum EditorTool: String, CaseIterable, Identifiable {
    case select, signature, date, text, redact
    var id: String { rawValue }
    var title: String {
        switch self {
        case .select: return String(localized: "Compila")
        case .signature: return String(localized: "Firma")
        case .date: return String(localized: "Data")
        case .text: return String(localized: "Testo")
        case .redact: return String(localized: "Oscura")
        }
    }
    var symbol: String {
        switch self {
        case .select: return "cursorarrow"
        case .signature: return "signature"
        case .date: return "calendar"
        case .text: return "textformat"
        case .redact: return "rectangle.inset.filled"
        }
    }
    var hint: String {
        switch self {
        case .select: return String(localized: "Scrivi nei campi del modulo. Trascina firme e testi per spostarli, l’angolo in basso a destra per ridimensionare; ⌫ elimina, ⌘Z annulla.")
        case .signature: return String(localized: "Clicca sulla pagina dove vuoi la firma.")
        case .date: return String(localized: "Clicca dove vuoi la data di oggi.")
        case .text: return String(localized: "Scrivi il testo qui sopra, poi clicca sulla pagina.")
        case .redact: return String(localized: "Trascina un rettangolo sopra ciò che vuoi nascondere.")
        }
    }
}

final class PDFEditorModel: ObservableObject, @unchecked Sendable {
    let source: URL
    let document: PDFDocument
    @Published var tool: EditorTool
    @Published var selected: PDFAnnotation? = nil
    @Published var freeText = String(localized: "Letto e approvato")
    @Published var findText = ""
    @Published var message: String? = nil
    @Published var flattenForms = false
    @Published var ocrAfterRedaction = true
    @Published var signatureSize: CGFloat = 160
    @Published var showSignaturePad = false
    @Published var saving = false
    /// Le annotazioni aggiunte qui (le uniche che si possono spostare o eliminare).
    private(set) var added: [ObjectIdentifier: PDFAnnotation] = [:]
    var redactions: [PDFAnnotation] = []
    weak var view: PDFView?
    /// Chiude la finestra senza domande (dopo il salvataggio).
    var close: () -> Void = {}
    /// 5.1 · «Annulla» ed Esc: chiude, ma chiede prima se ci sono modifiche.
    var requestClose: () -> Void = {}
    /// 5.1 · ⌘Z / ⇧⌘Z: la finestra lo usa come suo UndoManager (vedi PDFEditorWindowGuard).
    let undo = UndoManager()
    /// 5.1 · Chiede se sostituire la firma salvata (nei test si risponde da soli).
    var confirmReplaceSignature: () -> Bool = {
        EditorAlert.confirm(String(localized: "Sostituire la firma salvata?"),
                            info: String(localized: "Potrai tornare a quella vecchia con ⌘Z."),
                            ok: String(localized: "Sostituisci"), cancel: String(localized: "Annulla"))
    }
    /// 5.1 · I valori dei campi del modulo all'apertura, per capire se li hai cambiati.
    private var formBaseline: [(PDFAnnotation, String)] = []
    private var saved = false

    init(source: URL, document: PDFDocument, tool: EditorTool) {
        self.source = source
        self.document = document
        self.tool = tool
        formBaseline = Self.formFields(document).map { ($0, Self.formValue($0)) }
    }

    func isMine(_ a: PDFAnnotation) -> Bool { added[ObjectIdentifier(a)] != nil }

    // MARK: 5.1 · Modifiche e annulla

    /// Ci sono firme, testi, oscuramenti o campi compilati non ancora salvati.
    var hasChanges: Bool {
        if saved { return false }
        return !added.isEmpty || formBaseline.contains { Self.formValue($0.0) != $0.1 }
    }

    static func formFields(_ doc: PDFDocument) -> [PDFAnnotation] {
        var out: [PDFAnnotation] = []
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            // PDFKit scrive il tipo senza «/» («Widget»): si accettano tutte e due le forme
            out += page.annotations.filter { ($0.type ?? "").replacingOccurrences(of: "/", with: "") == "Widget" }
        }
        return out
    }

    static func formValue(_ a: PDFAnnotation) -> String {
        "\(a.widgetStringValue ?? "")|\(a.buttonWidgetState.rawValue)"
    }

    /// Un gesto = un solo ⌘Z.
    private func step(_ body: () -> Void) {
        undo.beginUndoGrouping()
        body()
        undo.endUndoGrouping()
    }

    private func attach(_ a: PDFAnnotation, to page: PDFPage, redaction: Bool, register: Bool = true) {
        page.addAnnotation(a)
        added[ObjectIdentifier(a)] = a
        if redaction, !redactions.contains(where: { $0 === a }) { redactions.append(a) }
        saved = false
        view?.annotationsChanged(on: page)
        if register { undo.registerUndo(withTarget: self) { $0.detach(a, from: page, redaction: redaction) } }
    }

    private func detach(_ a: PDFAnnotation, from page: PDFPage, redaction: Bool, register: Bool = true) {
        page.removeAnnotation(a)
        added[ObjectIdentifier(a)] = nil
        redactions.removeAll { $0 === a }
        if selected === a { selected = nil }
        saved = false
        view?.annotationsChanged(on: page)
        if register { undo.registerUndo(withTarget: self) { $0.attach(a, to: page, redaction: redaction) } }
    }

    private func isRedaction(_ a: PDFAnnotation) -> Bool { redactions.contains { $0 === a } }

    private func add(_ a: PDFAnnotation, to page: PDFPage) {
        step { attach(a, to: page, redaction: false) }
    }

    /// Elimina un elemento aggiunto qui (si riprende con ⌘Z).
    func remove(_ a: PDFAnnotation) {
        guard let page = a.page, isMine(a) else { return }
        let r = isRedaction(a)
        step { detach(a, from: page, redaction: r) }
    }

    private func setBounds(_ a: PDFAnnotation, _ r: CGRect) {
        let now = a.bounds
        a.bounds = r
        saved = false
        if let page = a.page { view?.annotationsChanged(on: page) }
        undo.registerUndo(withTarget: self) { $0.setBounds(a, now) }
    }

    /// Fine di uno spostamento o di un ridimensionamento: un solo annulla per tutto il trascinamento.
    func commitBounds(_ a: PDFAnnotation, from old: CGRect) {
        guard a.bounds != old, isMine(a) else { return }
        saved = false
        step { undo.registerUndo(withTarget: self) { $0.setBounds(a, old) } }
    }

    /// Si possono ridimensionare firme e oscuramenti (i testi si spostano soltanto).
    func canResize(_ a: PDFAnnotation) -> Bool { isMine(a) && (a is ImageStampAnnotation || isRedaction(a)) }

    /// L'elemento con l'angolo in basso a destra sotto il puntatore (entro `tolerance` punti della pagina).
    func resizeHandle(on page: PDFPage, at p: CGPoint, tolerance: CGFloat) -> PDFAnnotation? {
        page.annotations.reversed().first { a in
            canResize(a) && hypot(p.x - a.bounds.maxX, p.y - a.bounds.minY) <= tolerance
        }
    }

    /// Il rettangolo tirato dall'angolo in basso a destra: quello in alto a sinistra resta fermo.
    static func resized(_ r: CGRect, to p: CGPoint, keepRatio: Bool, minSide: CGFloat = 8) -> CGRect {
        let w = max(minSide, p.x - r.minX)
        var h = max(minSide, r.maxY - p.y)
        if keepRatio, r.width > 0 { h = max(minSide, w * r.height / r.width) }
        return CGRect(x: r.minX, y: r.maxY - h, width: w, height: h)
    }

    // MARK: 5.1 · Firma salvata, con annulla

    /// Usa la firma appena disegnata. false = hai scelto «Annulla» (il disegno resta nel riquadro).
    func useSignature(_ img: NSImage) -> Bool {
        guard let png = SignatureStore.png(img) else { return true }
        if SignatureStore.data() != nil {
            guard confirmReplaceSignature() else { return false }
            step { setSignatureData(png) }
        } else {
            SignatureStore.write(png)          // la prima firma: niente da ripristinare
        }
        tool = .signature
        return true
    }

    private func setSignatureData(_ d: Data?) {
        let before = SignatureStore.data()
        SignatureStore.write(d)
        undo.registerUndo(withTarget: self) { $0.setSignatureData(before) }
    }

    // MARK: Firma, data, testo

    func placeSignature(on page: PDFPage, at p: CGPoint) {
        guard let img = SignatureStore.load() else { showSignaturePad = true; return }
        let ratio = img.size.height / max(img.size.width, 1)
        let w = signatureSize, h = signatureSize * ratio
        let a = ImageStampAnnotation(image: img, bounds: CGRect(x: p.x - w / 2, y: p.y - h / 2, width: w, height: h))
        add(a, to: page)
        selected = a
        tool = .select
    }

    func placeText(_ text: String, on page: PDFPage, at p: CGPoint) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { message = String(localized: "Scrivi prima il testo."); return }
        let font = NSFont(name: "Helvetica", size: 12) ?? .systemFont(ofSize: 12)
        let size = (t as NSString).size(withAttributes: [.font: font])
        let a = PDFAnnotation(bounds: CGRect(x: p.x, y: p.y - size.height / 2, width: size.width + 8, height: size.height + 4),
                              forType: .freeText, withProperties: nil)
        a.contents = t
        a.font = font
        a.fontColor = .black
        a.color = .clear
        let border = PDFBorder()
        border.lineWidth = 0
        a.border = border
        add(a, to: page)
        selected = a
        tool = .select
    }

    static var today: String {
        let f = DateFormatter()
        f.dateFormat = "dd/MM/yyyy"
        return f.string(from: Date())
    }

    // MARK: Oscuramento

    private static func redactionBox(_ rect: CGRect) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        a.color = .black
        a.interiorColor = .black
        let border = PDFBorder()
        border.lineWidth = 0
        a.border = border
        return a
    }

    @discardableResult
    func addRedaction(on page: PDFPage, rect: CGRect) -> PDFAnnotation {
        let a = Self.redactionBox(rect)
        step { attach(a, to: page, redaction: true) }
        return a
    }

    /// 5.1 · Il rettangolo che stai trascinando: entra nell'annulla solo quando lasci il mouse.
    func beginDraftRedaction(on page: PDFPage, at p: CGPoint) -> PDFAnnotation {
        let a = Self.redactionBox(CGRect(origin: p, size: CGSize(width: 1, height: 1)))
        attach(a, to: page, redaction: true, register: false)
        return a
    }

    func finishDraftRedaction(_ a: PDFAnnotation) {
        guard let page = a.page else { return }
        if a.bounds.width < 4 || a.bounds.height < 4 {
            detach(a, from: page, redaction: true, register: false)   // un clic senza trascinare non lascia rettangoli minuscoli
        } else {
            step { undo.registerUndo(withTarget: self) { $0.detach(a, from: page, redaction: true) } }
        }
    }

    /// «Trova e oscura»: ogni volta che compare la parola (o il numero) cercata.
    func redactMatches(of term: String) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var n = 0
        step {          // 5.1 · tutti i punti trovati si tolgono con un solo ⌘Z
            for sel in document.findString(t, withOptions: [.caseInsensitive]) {
                for page in sel.pages {
                    addRedaction(on: page, rect: sel.bounds(for: page).insetBy(dx: -1.5, dy: -1.5))
                    n += 1
                }
            }
        }
        message = n == 0 ? String(localized: "«\(t)» non compare nel documento.") : String(localized: "Oscurati \(n) punti con «\(t)».")
    }

    enum Pattern: String, CaseIterable, Identifiable {
        case email = "Email", phone = "Telefono", iban = "IBAN", fiscal = "Codice fiscale"
        var id: String { rawValue }
        var regex: String {
            switch self {
            case .email: return #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#
            case .phone: return #"(?:\+\d{1,3}[\s.-]?)?(?:\d[\s.-]?){8,12}\d"#
            case .iban: return #"\b[A-Z]{2}\d{2}(?:\s?[A-Z0-9]){11,30}\b"#
            case .fiscal: return #"\b[A-Z]{6}\d{2}[A-EHLMPR-T]\d{2}[A-Z]\d{3}[A-Z]\b"#
            }
        }
    }

    /// Oscura tutto ciò che somiglia a email, telefoni, IBAN o codici fiscali.
    func redactPattern(_ p: Pattern) {
        guard let re = try? NSRegularExpression(pattern: p.regex, options: [.caseInsensitive]) else { return }
        var n = 0
        step {          // 5.1 · un solo ⌘Z per tutta la ricerca
            for i in 0..<document.pageCount {
                guard let page = document.page(at: i), let text = page.string else { continue }
                let ns = text as NSString
                for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                    guard let sel = page.selection(for: m.range) else { continue }
                    addRedaction(on: page, rect: sel.bounds(for: page).insetBy(dx: -1.5, dy: -1.5))
                    n += 1
                }
            }
        }
        let name = String(localized: String.LocalizationValue(p.rawValue)).lowercased()
        message = n == 0 ? String(localized: "Nessun \(name) trovato.") : String(localized: "Oscurati \(n) \(name).")
    }

    // MARK: Salvataggio

    var outputSuffix: String {
        if !redactions.isEmpty { return "oscurato" }
        if added.values.contains(where: { $0 is ImageStampAnnotation }) { return "firmato" }
        return "compilato"
    }

    /// Salva una copia. Con oscuramenti, firme o «non modificabile» la copia viene «appiattita»:
    /// le pagine con parti oscurate diventano immagini (il testo sotto il nero sparisce davvero),
    /// le altre restano vettoriali con campi e firme fissati sulla pagina.
    func save() {
        guard !saving else { return }       // 5.1 · mai due salvataggi insieme
        let dir = Destination.dir(for: source)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = Destination.unique(dir, base: source.deletingPathExtension().lastPathComponent + " (\(FileTag.t(outputSuffix)))", ext: "pdf")
        let flatten = flattenForms || !redactions.isEmpty || added.values.contains(where: { $0 is ImageStampAnnotation })
        saving = true
        message = nil
        if !flatten {
            let ok = document.write(to: out)
            finishSave(ok ? out : nil)
            return
        }
        // Pagine con oscuramenti: quali rettangoli, pagina per pagina
        var boxes: [Int: [CGRect]] = [:]
        for a in redactions {
            guard let p = a.page else { continue }
            boxes[document.index(for: p), default: []].append(a.bounds)
        }
        let doc = document, ocr = ocrAfterRedaction
        DispatchQueue.global(qos: .userInitiated).async {
            let ok = Self.writeFlattened(doc, boxes: boxes, ocr: ocr, to: out)
            DispatchQueue.main.async { self.finishSave(ok ? out : nil) }
        }
    }

    private func finishSave(_ out: URL?) {
        saving = false
        guard let out else { message = String(localized: "Non sono riuscito a salvare il PDF."); return }
        QueueStore.shared.record(title: source.lastPathComponent, action: outputSuffix == "oscurato" ? String(localized: "Oscura") : String(localized: "Editor PDF"),
                                 outputs: [out], kind: .pdf, before: Job.size(of: source))
        NSWorkspace.shared.activateFileViewerSelecting([out])
        saved = true                        // 5.1 · salvato: si chiude senza domande
        close()
    }

    static func writeFlattened(_ doc: PDFDocument, boxes: [Int: [CGRect]], ocr: Bool, to out: URL) -> Bool {
        guard let ctx = CGContext(out as CFURL, mediaBox: nil, nil) else { return false }
        for i in 0..<doc.pageCount {
            guard let page = doc.page(at: i) else { continue }
            let size = Tools.visibleSize(page)
            var box = CGRect(origin: .zero, size: size)
            ctx.beginPage(mediaBox: &box)
            if let rects = boxes[i], !rects.isEmpty {
                // Oscurata: diventa un'immagine con i rettangoli neri «dentro». Il testo originale non c'è più.
                let img = Tools.render(page, dpi: 220) { c in
                    c.setFillColor(CGColor(gray: 0, alpha: 1))
                    for r in rects { c.fill(r) }
                }
                if let img {
                    ctx.draw(img, in: box)
                    if ocr, let lines = try? Tools.recognize(img) { Tools.drawInvisibleText(lines, in: ctx, size: size) }
                }
            } else {
                page.draw(with: .cropBox, to: ctx)        // vettoriale, con campi compilati e firme
            }
            ctx.endPage()
        }
        ctx.closePDF()
        return PDFDocument(url: out) != nil
    }
}

/// Azioni che non vanno in Coda ma aprono una finestra.
enum Interactive {
    static func handles(_ id: String) -> Bool { id == "pdfedit" || id == "redact" }

    static func open(_ action: Action, files: [URL]) {
        guard let pdf = files.first(where: { Catalog.kind(of: $0) == .pdf }) else {
            // 5.1 · non solo un «bip»: si dice cosa fare
            NSApp.activate()
            let a = NSAlert()
            a.messageText = String(localized: "Scegli prima un PDF.")
            a.informativeText = String(localized: "Seleziona un file PDF, poi riprova.")
            a.runModal()
            return
        }
        PDFEditorController.shared.open(pdf, tool: action.id == "redact" ? .redact : .select)
    }
}

// MARK: - Vista PDF con gli strumenti

final class EditorPDFView: PDFView {
    weak var model: PDFEditorModel?
    /// 5.1 · Cosa sta facendo il trascinamento (l'annulla si registra solo al rilascio).
    private enum Drag {
        case move(PDFAnnotation, from: CGRect, start: CGPoint)
        case resize(PDFAnnotation, from: CGRect)
        case draw(PDFAnnotation, start: CGPoint)
    }
    private var drag: Drag?

    override var acceptsFirstResponder: Bool { true }

    private func pagePoint(_ e: NSEvent) -> (PDFPage, CGPoint)? {
        let p = convert(e.locationInWindow, from: nil)
        guard let page = page(for: p, nearest: true) else { return nil }
        return (page, convert(p, to: page))
    }

    override func mouseDown(with e: NSEvent) {
        guard let m = model, let hit = pagePoint(e) else { super.mouseDown(with: e); return }
        let page = hit.0, pp = hit.1
        window?.makeFirstResponder(self)
        switch m.tool {
        case .select:
            // 5.1 · l'angolo in basso a destra di firme e oscuramenti li ridimensiona
            if let a = m.resizeHandle(on: page, at: pp, tolerance: 10 / max(scaleFactor, 0.1)) {
                m.selected = a
                drag = .resize(a, from: a.bounds)
            } else if let a = page.annotation(at: pp), m.isMine(a) {
                m.selected = a
                drag = .move(a, from: a.bounds, start: pp)
            } else {
                m.selected = nil
                super.mouseDown(with: e)        // campi del modulo, selezione del testo
            }
        case .signature:
            m.placeSignature(on: page, at: pp)
        case .date:
            m.placeText(PDFEditorModel.today, on: page, at: pp)
        case .text:
            m.placeText(m.freeText, on: page, at: pp)
        case .redact:
            drag = .draw(m.beginDraftRedaction(on: page, at: pp), start: pp)
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let d = drag else { super.mouseDragged(with: e); return }
        let a: PDFAnnotation
        switch d {
        case .move(let x, _, _), .resize(let x, _), .draw(let x, _): a = x
        }
        guard let page = a.page else { return }
        let p = convert(convert(e.locationInWindow, from: nil), to: page)
        switch d {
        case .move(_, let from, let start):
            var b = from
            b.origin = CGPoint(x: from.origin.x + p.x - start.x, y: from.origin.y + p.y - start.y)
            a.bounds = b
        case .resize(_, let from):
            a.bounds = PDFEditorModel.resized(from, to: p, keepRatio: a is ImageStampAnnotation)
        case .draw(_, let start):
            a.bounds = CGRect(x: min(start.x, p.x), y: min(start.y, p.y),
                              width: abs(p.x - start.x), height: abs(p.y - start.y))
        }
        annotationsChanged(on: page)
    }

    override func mouseUp(with e: NSEvent) {
        if let m = model, let d = drag {
            switch d {
            case .move(let a, let from, _): m.commitBounds(a, from: from)
            case .resize(let a, let from): m.commitBounds(a, from: from)
            case .draw(let a, _): m.finishDraftRedaction(a)
            }
        }
        drag = nil
        super.mouseUp(with: e)
    }

    override func keyDown(with e: NSEvent) {
        if let m = model, let a = m.selected, e.keyCode == 51 || e.keyCode == 117 {   // ⌫ o canc
            m.remove(a)
            return
        }
        // 5.1 · ⌘Z / ⇧⌘Z anche se il menu Modifica non li prende
        let flags = e.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if let m = model, flags.contains(.command), e.charactersIgnoringModifiers?.lowercased() == "z" {
            if flags.contains(.shift) {
                if m.undo.canRedo { m.undo.redo() } else { NSSound.beep() }
            } else {
                if m.undo.canUndo { m.undo.undo() } else { NSSound.beep() }
            }
            return
        }
        super.keyDown(with: e)
    }
}

struct PDFKitView: NSViewRepresentable {
    let model: PDFEditorModel

    func makeNSView(context: Context) -> EditorPDFView {
        let v = EditorPDFView()
        v.document = model.document
        v.autoScales = true
        v.displayMode = .singlePageContinuous
        v.displaysPageBreaks = true
        v.backgroundColor = NSColor(Theme.parchment.opacity(0.5))
        v.model = model
        model.view = v
        return v
    }

    func updateNSView(_ v: EditorPDFView, context: Context) {}
}

// MARK: - Finestra

/// 5.1 · Avvisi dell'Editor PDF (come gli altri del file: NSAlert).
enum EditorAlert {
    /// true = il primo pulsante (↩); il secondo risponde a Esc.
    static func confirm(_ title: String, info: String? = nil, ok: String, cancel: String, destructive: Bool = false) -> Bool {
        let a = NSAlert()
        a.messageText = title
        if let info { a.informativeText = info }
        let okButton = a.addButton(withTitle: ok)
        okButton.hasDestructiveAction = destructive
        a.addButton(withTitle: cancel).keyEquivalent = "\u{1b}"
        return a.runModal() == .alertFirstButtonReturn
    }
}

/// 5.1 · Delegato della finestra: chiede prima di buttare le modifiche e dà alla finestra l'annulla del modello.
@MainActor
final class PDFEditorWindowGuard: NSObject, NSWindowDelegate {
    let model: PDFEditorModel

    init(model: PDFEditorModel) {
        self.model = model
    }

    func windowWillReturnUndoManager(_ window: NSWindow) -> UndoManager? { model.undo }

    /// ✕ e ⌘W.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        if model.saving { return false }            // il salvataggio chiude da solo quando ha finito
        guard model.hasChanges else { return true }
        ask(sender)
        return false
    }

    /// «Annulla» ed Esc nella finestra.
    func requestClose(_ w: NSWindow) {
        if windowShouldClose(w) { w.close() }
    }

    private func ask(_ w: NSWindow) {
        guard w.attachedSheet == nil else { return }
        let a = NSAlert()
        a.messageText = String(localized: "Salvare una copia con le modifiche prima di chiudere?")
        a.informativeText = String(localized: "Se non la salvi, firme, testi e oscuramenti che hai aggiunto vanno persi.")
        a.addButton(withTitle: String(localized: "Salva una copia…"))                       // ↩
        a.addButton(withTitle: String(localized: "Annulla")).keyEquivalent = "\u{1b}"       // Esc
        let dont = a.addButton(withTitle: String(localized: "Non salvare"))
        dont.hasDestructiveAction = true
        dont.keyEquivalent = "d"
        dont.keyEquivalentModifierMask = [.command]
        a.beginSheetModal(for: w) { [weak self, weak w] r in
            guard let self, let w else { return }
            switch r {
            case .alertFirstButtonReturn: self.model.save()      // se va bene, chiude da solo
            case .alertThirdButtonReturn: w.close()
            default: break
            }
        }
    }
}

final class PDFEditorController: @unchecked Sendable {
    static let shared = PDFEditorController()
    private struct Entry {
        let window: NSWindow
        let model: PDFEditorModel
        let guardian: PDFEditorWindowGuard       // il delegato è «weak»: lo tiene vivo questa lista
    }
    private var entries: [Entry] = []

    /// 5.1 · Almeno una finestra dell'Editor PDF ha modifiche non salvate (per ⌘Q).
    static var hasUnsavedChanges: Bool { shared.entries.contains { $0.model.hasChanges } }

    /// 5.1 · Porta davanti la prima finestra con modifiche non salvate.
    static func reviewUnsaved() {
        guard let e = shared.entries.first(where: { $0.model.hasChanges }) else { return }
        shared.bringFront(e.window)
    }

    /// 5.1 · Lo stesso file anche se scritto in modo diverso (.., link simbolici).
    static func sameFile(_ a: URL, _ b: URL) -> Bool {
        if a.standardizedFileURL.resolvingSymlinksInPath().path == b.standardizedFileURL.resolvingSymlinksInPath().path { return true }
        let key: Set<URLResourceKey> = [.fileResourceIdentifierKey]
        guard let x = try? a.resourceValues(forKeys: key).fileResourceIdentifier,
              let y = try? b.resourceValues(forKeys: key).fileResourceIdentifier else { return false }
        return x.isEqual(y)
    }

    private func bringFront(_ w: NSWindow) {
        NSApp.activate()
        if w.isMiniaturized { w.deminiaturize(nil) }
        w.makeKeyAndOrderFront(nil)
    }

    func open(_ url: URL, tool: EditorTool) {
        // 5.1 · già aperto: si riporta davanti quella finestra, niente doppioni
        if let e = entries.first(where: { Self.sameFile($0.model.source, url) }) {
            bringFront(e.window)
            return
        }
        guard let doc = PDFDocument(url: url) else {
            let a = NSAlert()
            a.messageText = String(localized: "Non riesco ad aprire questo PDF.")
            a.runModal()
            return
        }
        if doc.isLocked {
            // 5.1 · non solo un avviso: si può togliere la password da qui
            let remove = EditorAlert.confirm(String(localized: "Questo PDF è protetto da una password."),
                                             info: String(localized: "Ne faccio una copia senza password: poi apri quella."),
                                             ok: String(localized: "Rimuovi la password…"), cancel: String(localized: "Annulla"))
            if remove { Self.unprotect(url) }
            return
        }
        let model = PDFEditorModel(source: url, document: doc, tool: tool)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 780),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        let fileName = url.lastPathComponent
        w.title = tool == .redact ? String(localized: "Oscura · \(fileName)") : String(localized: "Editor PDF · \(fileName)")
        w.contentView = NSHostingView(rootView: PDFEditorView(model: model))
        w.contentMinSize = NSSize(width: 760, height: 520)
        w.isReleasedWhenClosed = false
        w.center()
        // NSWindowDelegate rende il delegato @MainActor: qui si è già sul main thread
        let guardian = MainActor.assumeIsolated { PDFEditorWindowGuard(model: model) }
        w.delegate = guardian
        model.close = { [weak w] in w?.close() }
        model.requestClose = { [weak w, weak guardian] in
            guard let w, let guardian else { return }
            MainActor.assumeIsolated { guardian.requestClose(w) }
        }
        WindowClose.once(w) { [weak self] in
            self?.entries.removeAll { $0.window === w }
            model.undo.removeAllActions()            // 5.1 · l'annulla non tiene vivo il documento chiuso
        }
        entries.append(Entry(window: w, model: model, guardian: guardian))
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    /// 5.1 · L'azione «Rimuovi la password» in Coda, come dal menu: prima chiede la password.
    private static func unprotect(_ url: URL) {
        guard let a = Catalog.action(id: "unprotect", kind: .pdf) else { return }
        ParamController.shared.ask(.unlock, action: a, files: [url], at: NSEvent.mouseLocation) { v in
            if let v { QueueStore.shared.enqueue(files: [url], action: a, param: v) }
        }
    }
}

struct PDFEditorView: View {
    @ObservedObject var model: PDFEditorModel

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.ivory)
            Divider()
            PDFKitView(model: model)
            Divider()
            footer
                .padding(.horizontal, 16).padding(.vertical, 10)
                .background(Theme.ivory)
        }
        .background(Theme.cream)
        .foregroundStyle(Theme.ink)
        .sheet(isPresented: $model.showSignaturePad) {
            SignaturePad { img in
                // 5.1 · se sostituisci la firma salvata si chiede, e la vecchia torna con ⌘Z
                if let img, !model.useSignature(img) { return }      // «Annulla»: il disegno resta
                model.showSignaturePad = false
            }
        }
    }

    private var toolbar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Picker("Strumento", selection: $model.tool) {
                    ForEach(EditorTool.allCases) { t in
                        Label(t.title, systemImage: t.symbol).tag(t)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 430)

                if model.tool == .text {
                    TextField("Testo da aggiungere", text: $model.freeText)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 200)
                }
                if model.tool == .signature || model.selected is ImageStampAnnotation {
                    Button { model.showSignaturePad = true } label: {
                        Label(SignatureStore.load() == nil ? String(localized: "Disegna la firma") : String(localized: "Cambia firma"), systemImage: "pencil.and.scribble")
                    }
                }
                Spacer()
                if let sel = model.selected {
                    Button(role: .destructive) { model.remove(sel) } label: { Label("Elimina", systemImage: "trash") }
                        .help("Elimina l’elemento selezionato (⌫)")
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "rectangle.inset.filled").foregroundStyle(.secondary)
                TextField("Trova e oscura: un nome, una parola, un numero…", text: $model.findText)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 280)
                    .onSubmit { model.redactMatches(of: model.findText) }
                Button("Oscura tutto") { model.redactMatches(of: model.findText) }
                    .disabled(model.findText.trimmingCharacters(in: .whitespaces).isEmpty)
                Menu("Oscura in automatico") {
                    ForEach(PDFEditorModel.Pattern.allCases) { p in
                        Button(String(localized: String.LocalizationValue(p.rawValue))) { model.redactPattern(p) }
                    }
                }
                .fixedSize()
                Spacer()
            }
            Text(model.tool.hint).font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private var footer: some View {
        HStack(spacing: 14) {
            Toggle("Rendi il modulo non modificabile", isOn: $model.flattenForms)
                .help("I valori scritti nei campi diventano parte della pagina")
            Toggle("Dopo l’oscuramento, testo ricercabile", isOn: $model.ocrAfterRedaction)
                .help("Le pagine oscurate diventano immagini: con questa opzione il resto del testo si può ancora cercare e copiare")
            if let msg = model.message {
                Label(msg, systemImage: "info.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.brass)
                    .lineLimit(1)
            }
            Spacer()
            if model.saving { ProgressView().controlSize(.small) }
            Button("Annulla") { model.requestClose() }.keyboardShortcut(.cancelAction)   // 5.1 · chiede se ci sono modifiche
            Button { model.save() } label: { Label("Salva una copia", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("s", modifiers: .command)
                .primaryButton()
                .disabled(model.saving)
        }
        .font(.system(size: 12))
    }
}

// MARK: - Firma disegnata

struct SignaturePad: View {
    let done: (NSImage?) -> Void
    @State private var strokes: [[CGPoint]] = []
    @State private var current: [CGPoint] = []
    private let size = CGSize(width: 520, height: 200)
    private let ink = Color(hex: 0x1D2A5B)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Disegna la tua firma").font(.system(size: 15, weight: .bold))
            Text("Con il mouse o con un dito sul trackpad (tieni premuto mentre disegni). OrbitLR la ricorda per le prossime volte.")
                .font(.system(size: 12)).foregroundStyle(.secondary)
            ZStack {
                RoundedRectangle(cornerRadius: Radius.l).fill(Color.white)
                Rectangle().fill(Color.gray.opacity(0.35)).frame(height: 1).offset(y: 50).padding(.horizontal, 30)
                Canvas { ctx, _ in
                    for s in strokes + [current] where s.count > 1 {
                        ctx.stroke(path(s), with: .color(ink), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay(RoundedRectangle(cornerRadius: Radius.l).strokeBorder(Theme.stroke))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in current.append(v.location) }
                .onEnded { _ in if current.count > 1 { strokes.append(current) }; current = [] })
            HStack {
                Button("Cancella") { strokes = []; current = [] }
                Spacer()
                Button("Annulla") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Usa questa firma") { done(render()) }
                    .keyboardShortcut(.defaultAction)
                    .primaryButton()
                    .disabled(strokes.isEmpty)
            }
        }
        .padding(22)
        .background(Theme.cream)
    }

    /// 5.1 · Con un disegno iniziato, Esc e «Annulla» chiedono prima di buttarlo.
    private func cancel() {
        if strokes.isEmpty && current.isEmpty { done(nil); return }
        let discard = EditorAlert.confirm(String(localized: "Buttare la firma disegnata?"),
                                          ok: String(localized: "Butta"), cancel: String(localized: "Continua a disegnare"),
                                          destructive: true)
        if discard { done(nil) }
    }

    private func path(_ pts: [CGPoint]) -> Path {
        var p = Path()
        guard let first = pts.first else { return p }
        p.move(to: first)
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            p.addQuadCurve(to: mid, control: pts[i - 1])
        }
        if let last = pts.last { p.addLine(to: last) }
        return p
    }

    /// La firma come immagine trasparente, ritagliata attorno al tratto, a doppia risoluzione.
    private func render() -> NSImage? {
        let all = strokes.flatMap { $0 }
        guard let minX = all.map(\.x).min(), let maxX = all.map(\.x).max(),
              let minY = all.map(\.y).min(), let maxY = all.map(\.y).max() else { return nil }
        let pad: CGFloat = 6
        let crop = CGRect(x: minX - pad, y: minY - pad, width: maxX - minX + pad * 2, height: maxY - minY + pad * 2)
        let content = Canvas { ctx, _ in
            ctx.translateBy(x: -crop.minX, y: -crop.minY)
            for s in strokes where s.count > 1 {
                ctx.stroke(path(s), with: .color(ink), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
            }
        }
        .frame(width: crop.width, height: crop.height)
        let r = ImageRenderer(content: content)
        r.scale = 3
        return r.nsImage
    }
}
