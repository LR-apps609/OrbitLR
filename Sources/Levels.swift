import SwiftUI

// ════════════════════════════════════════════════════════════════════
//  5.0 · Quanto vedere in ogni sezione: «Semplice» (le 6 cose che si fanno di più, in grande),
//  «Completo» (tutto, in gruppi che si aprono uno alla volta) e, dove c'è, l'editor della sezione.
//  Ogni sezione si apre in Semplice e si ricorda l'ultima scelta.
// ════════════════════════════════════════════════════════════════════

enum ViewLevel: String, CaseIterable, Identifiable {
    case simple, complete, editor
    var id: String { rawValue }
}

enum Levels {
    /// La chiave delle preferenze per la sezione.
    static func key(_ k: Kind) -> String { "level.\(k.rawValue)" }

    /// Le 6 azioni di «Semplice», nell'ordine in cui si vedono. «convert» è il riquadro «Cambia formato».
    static func simpleIDs(_ k: Kind) -> [String] {
        switch k {
        case .img: return ["icompress", "convert", "removebg", "aienhance", "resize", "vector"]
        case .video: return ["vcompress", "cut", "social", "to:mp3", "transcribe", "gifcut"]
        case .pdf: return ["pdfcompress", "merge", "extract", "protect", "pdfedit", "to:docx"]
        default: return ["convert"]
        }
    }

    /// Il nome dell'editor della sezione (nil: la sezione non ne ha uno).
    static func editorTitle(_ k: Kind) -> String? {
        switch k {
        case .video: return String(localized: "level.montage", defaultValue: "Montaggio")
        case .pdf: return String(localized: "Editor PDF")
        default: return nil
        }
    }
}

/// L'interruttore in alto: Semplice · Completo · (Editor).
struct LevelPicker: View {
    @Binding var level: ViewLevel
    let editorTitle: String?

    var body: some View {
        Picker("Quanto vedere", selection: $level) {
            Text("Semplice").tag(ViewLevel.simple)
            Text("Completo").tag(ViewLevel.complete)
            if let e = editorTitle { Text(e).tag(ViewLevel.editor) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(.small)
        .fixedSize()
        .help("Semplice: le cose che si fanno di più. Completo: tutte le funzioni, divise in gruppi.")
    }
}

/// «Semplice»: le azioni più usate in riquadri grandi, con il risultato previsto quando si conosce.
struct SimplePanel: View {
    @ObservedObject var m: KindTabModel
    let kind: Kind
    let tint: Color
    let showAll: () -> Void

    private let columns = [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)]

    /// Le azioni di Semplice che ci sono davvero per questi file (le altre si saltano), e quante ne restano fuori.
    /// (Le azioni si calcolano una volta sola per disegno: sono la parte costosa.)
    private func compute() -> (items: [SimpleItem], hidden: Int) {
        let all = m.actions
        let formats = all.filter { $0.id.hasPrefix("to:") }
        let tools = all.filter { !$0.id.hasPrefix("to:") }
        var out: [SimpleItem] = []
        for id in Levels.simpleIDs(m.kind ?? kind) {
            if id == "convert" {
                if !formats.isEmpty { out.append(.formats(formats)) }
            } else if let a = all.first(where: { $0.id == id }) {
                out.append(.action(a))
            }
            if out.count == 6 { break }
        }
        // I file di un tipo senza una lista sua (documenti, fogli…): le prime azioni, in ordine
        if out.count < 4 {
            for a in tools where !out.contains(where: { $0.id == a.id }) {
                out.append(.action(a))
                if out.count == 6 { break }
            }
        }
        return (out, max(0, tools.count + (formats.isEmpty ? 0 : 1) - out.count))
    }

    var body: some View {
        let (items, hidden) = compute()
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text("Cosa vuoi fare?").font(.system(size: 15, weight: .bold))
                LazyVGrid(columns: columns, spacing: 10) {
                    ForEach(items) { it in tile(it) }
                }
                if hidden > 0 {
                    Button(action: showAll) {
                        HStack(spacing: 6) {
                            Text(hidden == 1 ? String(localized: "1 altra funzione in Completo") : String(localized: "Altre \(hidden) funzioni in Completo"))
                            Image(systemName: "arrow.right")
                        }
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(Theme.brass)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(16)
        }
        .background(Theme.card.opacity(0.5))
        .disabled(m.files.isEmpty)
        .opacity(m.files.isEmpty ? 0.55 : 1)
    }

    @ViewBuilder private func tile(_ it: SimpleItem) -> some View {
        switch it {
        case .formats(let formats):
            Menu {
                ForEach(formats) { a in
                    Button {
                        m.run(a)
                    } label: {
                        if let b = m.estimates[a.id] { Text("\(a.short) · \(SizeEstimate.label(b))") } else { Text(a.short) }
                    }
                }
            } label: {
                tileLabel(symbol: "arrow.left.arrow.right", title: String(localized: "Cambia formato"),
                          hint: formats.prefix(4).map(\.short).joined(separator: ", "))
            }
            .menuStyle(.button)
            .buttonStyle(.plain)
            .menuIndicator(.hidden)
        case .action(let a):
            Button { m.run(a) } label: {
                tileLabel(symbol: a.symbol, title: a.title, hint: a.hint)
            }
            .buttonStyle(Pressable())
            .help(a.title + (a.hint.isEmpty ? "" : " · " + a.hint))
        }
    }

    private func tileLabel(symbol: String, title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Image(systemName: symbol).font(.system(size: 15, weight: .semibold)).foregroundStyle(tint)
                .frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 9).fill(tint.opacity(0.14)))
            Text(title).font(.system(size: 13.5, weight: .bold)).lineLimit(2).multilineTextAlignment(.leading)
            if !hint.isEmpty {
                Text(hint).font(.system(size: 11.5)).foregroundStyle(.secondary).lineLimit(3)
                    .multilineTextAlignment(.leading).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 13).fill(Theme.card))
        .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(tint.opacity(0.3)))
        .contentShape(RoundedRectangle(cornerRadius: 13))
    }
}

enum SimpleItem: Identifiable {
    case formats([Action])
    case action(Action)
    var id: String {
        switch self {
        case .formats: return "convert"
        case .action(let a): return a.id
        }
    }
}

/// 5.0 · In Immagini e in PDF e documenti: i due Downloader sempre in vista, sotto il titolo.
/// Il video scaricato arriva in Video, l'audio in Audio.
struct DownloadersRow: View {
    @State private var showVideo = false
    @State private var showAudio = false
    @State private var link = ""

    var body: some View {
        HStack(spacing: 10) {
            DownloaderBar(video: true) { t in link = t; showVideo = true }
            DownloaderBar(video: false) { t in link = t; showAudio = true }
            Spacer(minLength: 0)
        }
        .sheet(isPresented: $showVideo) {
            LinkSheet(video: true, initial: link, onDone: { file in
                let app = AppState.shared
                app.videoMode = .tools
                app.videoTools.add([file])
                app.selection = .video
            }, close: { showVideo = false })
        }
        .sheet(isPresented: $showAudio) {
            LinkSheet(initial: link, onDone: { file in
                let app = AppState.shared
                app.audioTab.load([file])
                app.selection = .audio
            }, close: { showAudio = false })
        }
    }
}
