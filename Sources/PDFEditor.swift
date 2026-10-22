import SwiftUI
import AppKit
import PDFKit

// ════════════════════════════════════════════════════════════════════
//  «Modifica PDF» (punto 9): compilare i moduli, firmare, aggiungere data e testo,
//  oscurare per davvero. L'originale non si tocca: si salva sempre una copia.
// ════════════════════════════════════════════════════════════════════

/// La firma disegnata una volta e ricordata (PNG trasparente nella cartella di OrbitLR).
enum SignatureStore {
    static var url: URL { Paths.support.appendingPathComponent("firma.png") }
    static func load() -> NSImage? { NSImage(contentsOf: url) }
    static func save(_ img: NSImage) {
        guard let tiff = img.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return }
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? png.write(to: url, options: .atomic)
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
        case .select: return "Compila"
        case .signature: return "Firma"
        case .date: return "Data"
        case .text: return "Testo"
        case .redact: return "Oscura"
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
        case .select: return "Scrivi nei campi del modulo. Trascina firme e testi per spostarli; ⌫ per eliminarli."
        case .signature: return "Clicca sulla pagina dove vuoi la firma."
        case .date: return "Clicca dove vuoi la data di oggi."
        case .text: return "Scrivi il testo qui sopra, poi clicca sulla pagina."
        case .redact: return "Trascina un rettangolo sopra ciò che vuoi nascondere."
        }
    }
}

final class PDFEditorModel: ObservableObject, @unchecked Sendable {
    let source: URL
    let document: PDFDocument
    @Published var tool: EditorTool
    @Published var selected: PDFAnnotation? = nil
    @Published var freeText = "Letto e approvato"
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
    var close: () -> Void = {}

    init(source: URL, document: PDFDocument, tool: EditorTool) {
        self.source = source
        self.document = document
        self.tool = tool
    }

    func isMine(_ a: PDFAnnotation) -> Bool { added[ObjectIdentifier(a)] != nil }

    private func add(_ a: PDFAnnotation, to page: PDFPage) {
        page.addAnnotation(a)
        added[ObjectIdentifier(a)] = a
        view?.annotationsChanged(on: page)
    }

    func remove(_ a: PDFAnnotation) {
        guard let page = a.page else { return }
        page.removeAnnotation(a)
        added[ObjectIdentifier(a)] = nil
        redactions.removeAll { $0 === a }
        if selected === a { selected = nil }
        view?.annotationsChanged(on: page)
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
        guard !t.isEmpty else { message = "Scrivi prima il testo."; return }
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

    @discardableResult
    func addRedaction(on page: PDFPage, rect: CGRect) -> PDFAnnotation {
        let a = PDFAnnotation(bounds: rect, forType: .square, withProperties: nil)
        a.color = .black
        a.interiorColor = .black
        let border = PDFBorder()
        border.lineWidth = 0
        a.border = border
        add(a, to: page)
        redactions.append(a)
        return a
    }

    /// «Trova e oscura»: ogni volta che compare la parola (o il numero) cercata.
    func redactMatches(of term: String) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        var n = 0
        for sel in document.findString(t, withOptions: [.caseInsensitive]) {
            for page in sel.pages {
                addRedaction(on: page, rect: sel.bounds(for: page).insetBy(dx: -1.5, dy: -1.5))
                n += 1
            }
        }
        message = n == 0 ? "«\(t)» non compare nel documento." : "Oscurati \(n) punti con «\(t)»."
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
        for i in 0..<document.pageCount {
            guard let page = document.page(at: i), let text = page.string else { continue }
            let ns = text as NSString
            for m in re.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                guard let sel = page.selection(for: m.range) else { continue }
                addRedaction(on: page, rect: sel.bounds(for: page).insetBy(dx: -1.5, dy: -1.5))
                n += 1
            }
        }
        message = n == 0 ? "Nessun \(p.rawValue.lowercased()) trovato." : "Oscurati \(n) \(p.rawValue.lowercased())."
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
        let dir = Destination.dir(for: source)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = Destination.unique(dir, base: source.deletingPathExtension().lastPathComponent + " (\(outputSuffix))", ext: "pdf")
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
        guard let out else { message = "Non sono riuscito a salvare il PDF."; return }
        QueueStore.shared.record(title: source.lastPathComponent, action: outputSuffix == "oscurato" ? "Oscura" : "Compila e firma",
                                 outputs: [out], kind: .pdf, before: Job.size(of: source))
        NSWorkspace.shared.activateFileViewerSelecting([out])
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
                page.draw(with: .mediaBox, to: ctx)       // vettoriale, con campi compilati e firme
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
        guard let pdf = files.first(where: { Catalog.kind(of: $0) == .pdf }) else { NSSound.beep(); return }
        PDFEditorController.shared.open(pdf, tool: action.id == "redact" ? .redact : .select)
    }
}

// MARK: - Vista PDF con gli strumenti

final class EditorPDFView: PDFView {
    weak var model: PDFEditorModel?
    private var dragging: PDFAnnotation?
    private var dragStart: CGPoint = .zero
    private var originStart: CGPoint = .zero
    private var redactStart: CGPoint = .zero
    private var redactPage: PDFPage?

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
            if let a = page.annotation(at: pp), m.isMine(a) {
                m.selected = a
                dragging = a
                dragStart = pp
                originStart = a.bounds.origin
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
            redactStart = pp
            redactPage = page
            dragging = m.addRedaction(on: page, rect: CGRect(origin: pp, size: CGSize(width: 1, height: 1)))
        }
    }

    override func mouseDragged(with e: NSEvent) {
        guard let m = model, let a = dragging, let page = a.page else { super.mouseDragged(with: e); return }
        let p = convert(convert(e.locationInWindow, from: nil), to: page)
        if m.tool == .redact {
            a.bounds = CGRect(x: min(redactStart.x, p.x), y: min(redactStart.y, p.y),
                              width: abs(p.x - redactStart.x), height: abs(p.y - redactStart.y))
        } else {
            var b = a.bounds
            b.origin = CGPoint(x: originStart.x + p.x - dragStart.x, y: originStart.y + p.y - dragStart.y)
            a.bounds = b
        }
        annotationsChanged(on: page)
    }

    override func mouseUp(with e: NSEvent) {
        if let m = model, m.tool == .redact, let a = dragging, a.bounds.width < 4 || a.bounds.height < 4 {
            m.remove(a)                         // un clic senza trascinare non lascia rettangoli minuscoli
        }
        dragging = nil
        redactPage = nil
        super.mouseUp(with: e)
    }

    override func keyDown(with e: NSEvent) {
        if let m = model, let a = m.selected, e.keyCode == 51 || e.keyCode == 117 {   // ⌫ o canc
            m.remove(a)
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

final class PDFEditorController: @unchecked Sendable {
    static let shared = PDFEditorController()
    private var windows: [NSWindow] = []

    func open(_ url: URL, tool: EditorTool) {
        guard let doc = PDFDocument(url: url) else {
            let a = NSAlert()
            a.messageText = "Non riesco ad aprire questo PDF."
            a.runModal()
            return
        }
        if doc.isLocked {
            let a = NSAlert()
            a.messageText = "Il PDF è protetto da password."
            a.informativeText = "Toglila prima con «Togli la password», poi riprova."
            a.runModal()
            return
        }
        let model = PDFEditorModel(source: url, document: doc, tool: tool)
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 780),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = (tool == .redact ? "Oscura · " : "Compila e firma · ") + url.lastPathComponent
        w.contentView = NSHostingView(rootView: PDFEditorView(model: model))
        w.contentMinSize = NSSize(width: 760, height: 520)
        w.isReleasedWhenClosed = false
        w.center()
        model.close = { [weak w] in w?.close() }
        WindowClose.once(w) { [weak self] in
            self?.windows.removeAll { $0 === w }
        }
        windows.append(w)
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
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
                if let img { SignatureStore.save(img); model.tool = .signature }
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
                        Label(SignatureStore.load() == nil ? "Disegna la firma" : "Cambia firma", systemImage: "pencil.and.scribble")
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
                        Button(p.rawValue) { model.redactPattern(p) }
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
            Button("Annulla") { model.close() }.keyboardShortcut(.cancelAction)
            Button { model.save() } label: { Label("Salva una copia", systemImage: "square.and.arrow.down") }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent).tint(Theme.accent)
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
                RoundedRectangle(cornerRadius: 12).fill(Color.white)
                Rectangle().fill(Color.gray.opacity(0.35)).frame(height: 1).offset(y: 50).padding(.horizontal, 30)
                Canvas { ctx, _ in
                    for s in strokes + [current] where s.count > 1 {
                        ctx.stroke(path(s), with: .color(ink), style: StrokeStyle(lineWidth: 2.6, lineCap: .round, lineJoin: .round))
                    }
                }
            }
            .frame(width: size.width, height: size.height)
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.stroke))
            .gesture(DragGesture(minimumDistance: 0)
                .onChanged { v in current.append(v.location) }
                .onEnded { _ in if current.count > 1 { strokes.append(current) }; current = [] })
            HStack {
                Button("Cancella") { strokes = []; current = [] }
                Spacer()
                Button("Annulla") { done(nil) }.keyboardShortcut(.cancelAction)
                Button("Usa questa firma") { done(render()) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(strokes.isEmpty)
            }
        }
        .padding(22)
        .background(Theme.cream)
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
