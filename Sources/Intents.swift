import AppIntents
import Foundation
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Comandi Rapidi e Siri (punto 3)
//  • «Converti con OrbitLR»: file in entrata, file in uscita, da usare nei Comandi Rapidi e nelle automazioni.
//  • «Usa un preset di OrbitLR»: lo stesso, con uno dei tuoi preset.
//  • «OrbitLR sulla selezione del Finder»: per Siri, «Converti in JPG con OrbitLR».
//  Le conversioni avvengono come sempre sul Mac, nella Coda di OrbitLR.
// ════════════════════════════════════════════════════════════════════

/// Le azioni disponibili nei Comandi Rapidi e con Siri.
enum OrbitAction: String, AppEnum {
    case toJPG, toPNG, toHEIC, toPDF, toMP3, toM4A, toMP4, compressVideo, compressPDF, resize, stripMetadata, extractText,
         searchable, removeBackground, straighten, upscale, aiEnhance

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Azione di OrbitLR"
    static var caseDisplayRepresentations: [OrbitAction: DisplayRepresentation] = [
        .toJPG: DisplayRepresentation(title: "Converti in JPG", image: .init(systemName: "photo")),
        .toPNG: DisplayRepresentation(title: "Converti in PNG", image: .init(systemName: "photo")),
        .toHEIC: DisplayRepresentation(title: "Converti in HEIC", image: .init(systemName: "photo")),
        .toPDF: DisplayRepresentation(title: "Converti in PDF", image: .init(systemName: "doc.richtext")),
        .toMP3: DisplayRepresentation(title: "Converti in MP3", image: .init(systemName: "waveform")),
        .toM4A: DisplayRepresentation(title: "Converti in M4A", image: .init(systemName: "waveform")),
        .toMP4: DisplayRepresentation(title: "Converti in MP4", image: .init(systemName: "film")),
        .compressVideo: DisplayRepresentation(title: "Comprimi il video", image: .init(systemName: "arrow.down.right.and.arrow.up.left")),
        .compressPDF: DisplayRepresentation(title: "Comprimi il PDF", image: .init(systemName: "arrow.down.right.and.arrow.up.left")),
        .resize: DisplayRepresentation(title: "Ridimensiona le foto", image: .init(systemName: "arrow.up.left.and.arrow.down.right")),
        .stripMetadata: DisplayRepresentation(title: "Rimuovi i metadati", image: .init(systemName: "eye.slash")),
        .extractText: DisplayRepresentation(title: "Estrai il testo", image: .init(systemName: "text.viewfinder")),
        .searchable: DisplayRepresentation(title: "Rendi ricercabile", image: .init(systemName: "doc.text.magnifyingglass")),
        .removeBackground: DisplayRepresentation(title: "Rimuovi lo sfondo", image: .init(systemName: "person.and.background.dotted")),
        .straighten: DisplayRepresentation(title: "Raddrizza il documento", image: .init(systemName: "doc.viewfinder")),
        .upscale: DisplayRepresentation(title: "Ingrandisci", image: .init(systemName: "plus.magnifyingglass")),
        .aiEnhance: DisplayRepresentation(title: "Migliora con IA", image: .init(systemName: "sparkles")),
    ]

    /// Identificativo dell'azione per un tipo di file (nil se non vale per quel tipo).
    func actionId(for kind: Kind) -> String? {
        switch self {
        case .toJPG: return [.img, .pdf].contains(kind) ? "to:jpg" : nil
        case .toPNG: return [.img, .pdf].contains(kind) ? "to:png" : nil
        case .toHEIC: return kind == .img ? "to:heic" : nil
        case .toPDF: return [.img, .doc, .sheet, .slide, .text].contains(kind) ? "to:pdf" : nil
        case .toMP3: return [.audio, .video].contains(kind) ? "to:mp3" : nil
        case .toM4A: return [.audio, .video].contains(kind) ? "to:m4a" : nil
        case .toMP4: return kind == .video ? "to:mp4" : nil
        case .compressVideo: return kind == .video ? "vcompress" : nil
        case .compressPDF: return kind == .pdf ? "pdfcompress" : nil
        case .resize: return kind == .img ? "resize" : nil
        case .stripMetadata: return [.img, .video].contains(kind) ? "strip" : nil
        case .extractText: return kind == .img ? "ocr" : (kind == .pdf ? "pdftext" : nil)
        case .searchable: return [.img, .pdf].contains(kind) ? "searchable" : nil
        case .removeBackground: return kind == .img ? "removebg" : nil
        case .straighten: return kind == .img ? "straighten" : nil
        case .upscale: return kind == .img ? "upscale" : nil
        case .aiEnhance: return kind == .img ? "aienhance" : nil
        }
    }

    /// Opzione predefinita per le azioni che ne hanno una (quando non la si sceglie nel Comando Rapido).
    var defaultParam: String {
        switch self {
        case .compressVideo: return "25"
        case .resize: return "1920"
        case .compressPDF: return "medium"
        case .removeBackground: return "transparent"
        case .straighten: return "color-jpg"
        case .upscale: return "2"
        case .aiEnhance: return "b0-2"
        default: return ""
        }
    }
}

enum ResizeChoice: String, AppEnum {
    case web, s1280, s1920, s3840, half
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Dimensione"
    static var caseDisplayRepresentations: [ResizeChoice: DisplayRepresentation] = [
        .web: "Per il web (1600 px)", .s1280: "Lato lungo 1280 px", .s1920: "Lato lungo 1920 px",
        .s3840: "Lato lungo 3840 px (4K)", .half: "Metà (50%)",
    ]
    var param: String {
        switch self {
        case .web: return "web"
        case .s1280: return "1280"
        case .s1920: return "1920"
        case .s3840: return "3840"
        case .half: return "half"
        }
    }
}

enum PDFLevel: String, AppEnum {
    case light, medium, strong
    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Compressione"
    static var caseDisplayRepresentations: [PDFLevel: DisplayRepresentation] = [
        .light: "Leggera (qualità di stampa)", .medium: "Media (consigliata)", .strong: "Forte",
    ]
}

struct OrbitIntentError: Error, CustomLocalizedStringResourceConvertible {
    let message: String
    var localizedStringResource: LocalizedStringResource { LocalizedStringResource(stringLiteral: message) }
}

// MARK: - Il motore comune

enum IntentRunner {
    /// Dove finiscono i file arrivati dai Comandi Rapidi senza un percorso (es. foto da Foto): Download/OrbitLR.
    static var inbox: URL {
        // Direttamente in Download: nessuna cartella nuova creata senza chiedere (punto 24)
        return FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? Paths.home
    }

    /// File veri sul disco: se il Comando Rapido passa solo i dati, li salvo in Download/OrbitLR.
    static func materialize(_ files: [IntentFile]) throws -> [URL] {
        var out: [URL] = []
        for f in files {
            if let u = f.fileURL, FileManager.default.fileExists(atPath: u.path) {
                _ = u.startAccessingSecurityScopedResource()
                out.append(u)
                continue
            }
            try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
            let name = f.filename.isEmpty ? "File" : f.filename
            let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
            let dest = Destination.unique(inbox, base: base, ext: ext.isEmpty ? "dat" : ext)
            try f.data.write(to: dest)
            out.append(dest)
        }
        return out
    }

    /// Mette in Coda i file (raggruppati per tipo), aspetta la fine e restituisce i file creati.
    @MainActor
    static func run(_ urls: [URL], pick: (Kind) -> (Action, String)?) async throws -> [URL] {
        WelcomeController.shared.skipNextSplash = true
        var byKind: [Kind: [URL]] = [:]
        for u in PieController.expand(urls) {
            guard let k = Catalog.kind(of: u), k != .sub else { continue }
            byKind[k, default: []].append(u)
        }
        guard !byKind.isEmpty else { throw OrbitIntentError(message: "Nessun file che OrbitLR sappia aprire.") }

        var jobs: [Job] = []
        var skipped: [String] = []
        for (k, files) in byKind {
            if let r = pick(k) {
                jobs.append(QueueStore.shared.enqueue(files: files, action: r.0, param: r.1))
            } else {
                skipped.append(k.name)
            }
        }
        guard !jobs.isEmpty else {
            throw OrbitIntentError(message: "Questa azione non vale per " + skipped.joined(separator: " e ") + ".")
        }

        // Aspetta che tutti i lavori finiscano (al massimo 2 ore)
        let limit = Date().addingTimeInterval(7200)
        while jobs.contains(where: { $0.state == .waiting || $0.state == .running }) && Date() < limit {
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        let outputs = jobs.flatMap { $0.outputs }
        if outputs.isEmpty {
            let why = jobs.compactMap { $0.failures.first }.first ?? jobs.first?.status ?? "Non riuscito"
            throw OrbitIntentError(message: why)
        }
        return outputs
    }
}

// MARK: - Converti con OrbitLR

struct ConvertFilesIntent: AppIntent {
    static var title: LocalizedStringResource = "Converti con OrbitLR"
    static var description = IntentDescription("Converte, comprime o ridimensiona i file con OrbitLR e restituisce i file creati.",
                                               categoryName: "File")

    @Parameter(title: "File", supportedTypeIdentifiers: ["public.item"])
    var files: [IntentFile]

    @Parameter(title: "Azione", default: .toJPG)
    var action: OrbitAction

    @Parameter(title: "Peso massimo del video (MB)", default: 25, inclusiveRange: (1, 4000))
    var maxMB: Int

    @Parameter(title: "Dimensione delle foto", default: .s1920)
    var size: ResizeChoice

    @Parameter(title: "Compressione del PDF", default: .medium)
    var pdfLevel: PDFLevel

    static var parameterSummary: some ParameterSummary {
        Switch(\.$action) {
            Case(.compressVideo) { Summary("\(\.$action) \(\.$files) sotto \(\.$maxMB) MB") }
            Case(.resize) { Summary("\(\.$action) \(\.$files) a \(\.$size)") }
            Case(.compressPDF) { Summary("\(\.$action) \(\.$files), compressione \(\.$pdfLevel)") }
            DefaultCase { Summary("\(\.$action) \(\.$files) con OrbitLR") }
        }
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let urls = try IntentRunner.materialize(files)
        let act = action, mb = maxMB, sz = size, lvl = pdfLevel
        let outs = try await IntentRunner.run(urls) { kind in
            guard let id = act.actionId(for: kind), let a = Catalog.action(id: id, kind: kind) else { return nil }
            switch act {
            case .compressVideo: return (a, String(mb))
            case .resize: return (a, sz.param)
            case .compressPDF: return (a, lvl.rawValue)
            default: return (a, act.defaultParam)
            }
        }
        return .result(value: outs.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) })
    }
}

// MARK: - Preset

struct PresetEntity: AppEntity {
    let id: UUID
    let name: String
    let detail: String

    static var typeDisplayRepresentation: TypeDisplayRepresentation = "Preset di OrbitLR"
    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", subtitle: "\(detail)", image: .init(systemName: "star.circle.fill"))
    }
    static var defaultQuery = PresetQuery()

    init(_ p: Preset) {
        id = p.id
        name = p.name
        detail = PresetStore.describe(actionId: p.actionId, param: p.param, kind: Kind(rawValue: p.kind))
    }
}

struct PresetQuery: EntityQuery {
    func entities(for identifiers: [UUID]) async throws -> [PresetEntity] {
        await MainActor.run { PresetStore.shared.presets.filter { identifiers.contains($0.id) }.map(PresetEntity.init) }
    }
    func suggestedEntities() async throws -> [PresetEntity] {
        await MainActor.run { PresetStore.shared.presets.map(PresetEntity.init) }
    }
}

struct RunPresetIntent: AppIntent {
    static var title: LocalizedStringResource = "Usa un preset di OrbitLR"
    static var description = IntentDescription("Applica uno dei tuoi preset ai file e restituisce i file creati.", categoryName: "File")

    @Parameter(title: "File", supportedTypeIdentifiers: ["public.item"])
    var files: [IntentFile]

    @Parameter(title: "Preset")
    var preset: PresetEntity

    static var parameterSummary: some ParameterSummary {
        Summary("Applica \(\.$preset) a \(\.$files)")
    }

    func perform() async throws -> some IntentResult & ReturnsValue<[IntentFile]> {
        let urls = try IntentRunner.materialize(files)
        let pid = preset.id
        let outs = try await IntentRunner.run(urls) { kind in
            guard let p = PresetStore.shared.presets.first(where: { $0.id == pid }), p.kind == kind.rawValue,
                  let a = Catalog.action(id: p.actionId, kind: kind) else { return nil }
            return (a, p.param)
        }
        return .result(value: outs.map { IntentFile(fileURL: $0, filename: $0.lastPathComponent) })
    }
}

// MARK: - Selezione del Finder (per Siri)

struct FinderSelectionIntent: AppIntent {
    static var title: LocalizedStringResource = "OrbitLR sulla selezione del Finder"
    static var description = IntentDescription("Applica un'azione ai file selezionati nel Finder. Con Siri: «Converti in JPG con OrbitLR».",
                                               categoryName: "File")

    @Parameter(title: "Azione", default: .toJPG)
    var action: OrbitAction

    static var parameterSummary: some ParameterSummary {
        Summary("\(\.$action) i file selezionati nel Finder")
    }

    func perform() async throws -> some IntentResult & ProvidesDialog {
        let files = await MainActor.run { FinderSelection.current() }
        guard !files.isEmpty else { throw OrbitIntentError(message: "Nel Finder non c’è nessun file selezionato.") }
        let act = action
        let outs = try await IntentRunner.run(files) { kind in
            guard let id = act.actionId(for: kind), let a = Catalog.action(id: id, kind: kind) else { return nil }
            return (a, act.defaultParam)
        }
        let msg = outs.count == 1 ? "Fatto: «\(outs[0].lastPathComponent)»." : "Fatto: \(outs.count) file pronti."
        return .result(dialog: IntentDialog(stringLiteral: msg))
    }
}

// MARK: - Frasi per Siri e Spotlight

struct OrbitShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: FinderSelectionIntent(),
                    phrases: ["\(\.$action) con \(.applicationName)",
                              "Usa \(.applicationName) sulla selezione",
                              "\(.applicationName) sui file selezionati"],
                    shortTitle: "Sulla selezione del Finder",
                    systemImageName: "cursorarrow.click.2")
        AppShortcut(intent: ConvertFilesIntent(),
                    phrases: ["Converti con \(.applicationName)", "Comprimi con \(.applicationName)"],
                    shortTitle: "Converti file",
                    systemImageName: "arrow.triangle.2.circlepath")
        AppShortcut(intent: RunPresetIntent(),
                    phrases: ["Usa un preset di \(.applicationName)"],
                    shortTitle: "Usa un preset",
                    systemImageName: "star.circle.fill")
    }
}
