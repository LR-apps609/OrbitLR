import Foundation
import AppKit
import SwiftUI

// ════════════════════════════════════════════════════════════════════
//  3.0 · Il Cassetto: ogni file creato dall'app è a portata di mano.
//  Si trascina su una scheda (o sulla sua riga nella barra laterale)
//  oppure si manda con «Usa in…»: Video, musica, Audio, Immagini, File,
//  Conversione, Finder. Così le schede lavorano insieme:
//  converti → taglia in Audio → musica nel Video, senza passare dal Finder.
// ════════════════════════════════════════════════════════════════════

/// Dove si può mandare un file.
enum DrawerTarget: String, CaseIterable, Identifiable {
    case video, music, videoTools, audio, images, files, convert, finder
    var id: String { rawValue }

    var title: String {
        switch self {
        case .video: return "Aggiungi al Video"
        case .music: return "Usa come musica nel Video"
        case .videoTools: return "Comprimi, taglia e altro (Video)"
        case .audio: return "Apri in Audio"
        case .images: return "Apri in Immagini"
        case .files: return "Apri in File"
        case .convert: return "Converti…"
        case .finder: return "Mostra nel Finder"
        }
    }

    var symbol: String {
        switch self {
        case .video: return "film"
        case .music: return "music.note"
        case .videoTools: return "slider.horizontal.3"
        case .audio: return "waveform"
        case .images: return "photo"
        case .files: return "doc.richtext"
        case .convert: return "chart.pie"
        case .finder: return "folder"
        }
    }

    /// La scheda della barra laterale che fa da bersaglio quando ci si trascina sopra un file.
    static func forSidebar(_ item: SidebarItem) -> DrawerTarget? {
        switch item {
        case .video: return .video
        case .audio: return .audio
        case .images: return .images
        case .files: return .files
        case .workspace: return .convert
        default: return nil
        }
    }
}

final class Drawer: ObservableObject, @unchecked Sendable {
    static let shared = Drawer()
    private static let hiddenKey = "drawerHidden"

    /// File tolti dal Cassetto (restano dove sono, sul disco).
    @Published private(set) var hidden: Set<String> = Set(UserDefaults.standard.stringArray(forKey: Drawer.hiddenKey) ?? [])

    /// I file del Cassetto: quelli creati di recente che esistono ancora, il più nuovo per primo, ognuno una volta.
    static func items(from history: [HistoryEntry], hidden: Set<String> = [], limit: Int = 40,
                      exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> [URL] {
        var seen = Set<String>(), out: [URL] = []
        for e in history where !e.undone {
            for p in e.outputs where !hidden.contains(p) && seen.insert(p).inserted && exists(p) {
                out.append(URL(fileURLWithPath: p))
                if out.count >= limit { return out }
            }
        }
        return out
    }

    func hide(_ url: URL) {
        hidden.insert(url.path)
        UserDefaults.standard.set(Array(hidden.suffix(500)), forKey: Self.hiddenKey)
    }

    /// Dove ha senso mandare questo file (la prima voce è la più probabile).
    static func targets(for url: URL) -> [DrawerTarget] {
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return [.finder] }
        switch Catalog.kind(of: url) {
        case .video?: return [.video, .videoTools, .music, .audio, .convert, .finder]
        case .audio?: return [.music, .audio, .convert, .finder]
        case .img?: return [.images, .convert, .finder]
        case .pdf?, .doc?, .sheet?, .slide?, .text?: return [.files, .convert, .finder]
        default: return [.convert, .finder]
        }
    }

    /// Manda i file dove serve e apre quella scheda.
    @MainActor
    static func send(_ urls: [URL], to target: DrawerTarget) {
        let urls = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !urls.isEmpty else { NSSound.beep(); return }
        let app = AppState.shared
        switch target {
        case .video:
            let s = VideoProjectStore.shared
            if s.currentID == nil { s.newProject(nil) }
            s.add(urls, undo: nil)
            app.videoMode = .montage
            app.selection = .video
        case .music:
            let s = VideoProjectStore.shared
            if s.currentID == nil { s.newProject(nil) }
            app.videoMode = .montage
            app.selection = .video
            Task { @MainActor in await s.setMusic(urls[0], undo: nil) }
        case .videoTools:
            app.videoTools.add(urls)
            app.videoMode = .tools
            app.selection = .video
        case .audio:
            app.audioTab.load(urls)
            app.selection = .audio
        case .images:
            app.imagesTab.add(urls)
            app.selection = .images
        case .files:
            app.filesTab.add(urls)
            app.selection = .files
        case .convert:
            app.workspace.load(urls)
            app.selection = .workspace
        case .finder:
            NSWorkspace.shared.activateFileViewerSelecting(urls)
        }
    }
}

// MARK: - «Usa in…»

/// Il menu «Usa in…» per un file (sotto i risultati e su ogni file del Cassetto).
struct UseInMenu: View {
    let url: URL
    var compact = false

    var body: some View {
        Menu {
            ForEach(Drawer.targets(for: url)) { t in
                Button { Drawer.send([url], to: t) } label: { Label(t.title, systemImage: t.symbol) }
            }
        } label: {
            if compact {
                Image(systemName: "arrow.turn.up.right")
            } else {
                Label("Usa in…", systemImage: "arrow.turn.up.right")
            }
        }
        .menuStyle(.button)
        .fixedSize()
        .help("Usa questo file in un’altra scheda, senza passare dal Finder")
        .accessibilityLabel("Usa \(url.lastPathComponent) in un’altra scheda")
    }
}

// MARK: - Il Cassetto nella barra laterale

struct DrawerSidebar: View {
    @EnvironmentObject var store: QueueStore
    @ObservedObject private var drawer = Drawer.shared
    @State private var showAll = false

    private var items: [URL] { Drawer.items(from: store.history, hidden: drawer.hidden) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Cassetto", systemImage: "tray.2.fill").font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.ink.opacity(0.75))
                Spacer()
                if items.count > 4 {
                    Button("Tutti (\(items.count))") { showAll = true }
                        .buttonStyle(.plain).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.accent)
                        .popover(isPresented: $showAll, arrowEdge: .trailing) { DrawerAll(items: items) }
                }
            }
            if items.isEmpty {
                Text("I file che crei finiscono qui: trascinali su una scheda o usa «Usa in…».")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(items.prefix(4), id: \.self) { u in DrawerRow(url: u) }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(radius: 12)
    }
}

/// Un file del Cassetto: si trascina, clic destro o «⋯» per mandarlo altrove.
struct DrawerRow: View {
    let url: URL
    @State private var hover = false

    var body: some View {
        HStack(spacing: 7) {
            FileThumb(url: url, kind: Catalog.kind(of: url), size: 26)
            Text(url.lastPathComponent).font(.system(size: 11)).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            UseInMenu(url: url, compact: true)
                .opacity(hover ? 1 : 0.55)
        }
        .padding(.vertical, 2).padding(.horizontal, 3)
        .background(RoundedRectangle(cornerRadius: 6).fill(hover ? Theme.ink.opacity(0.06) : .clear))
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .onDrag { NSItemProvider(contentsOf: url) ?? NSItemProvider() }
        .onTapGesture(count: 2) { NSWorkspace.shared.open(url) }
        .contextMenu {
            ForEach(Drawer.targets(for: url)) { t in
                Button { Drawer.send([url], to: t) } label: { Label(t.title, systemImage: t.symbol) }
            }
            Divider()
            Button("Togli dal Cassetto") { Drawer.shared.hide(url) }
        }
        .help("\(url.lastPathComponent) · trascinalo su una scheda, oppure «Usa in…» · doppio clic per aprirlo")
    }
}

/// Tutti i file del Cassetto, in griglia.
private struct DrawerAll: View {
    let items: [URL]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Cassetto").font(.headline)
            Text("Gli ultimi file creati con OrbitLR. Trascinali su una scheda, oppure clic destro per mandarli altrove.")
                .font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 104), spacing: 10)], spacing: 10) {
                    ForEach(items, id: \.self) { u in
                        VStack(spacing: 4) {
                            FileThumb(url: u, kind: Catalog.kind(of: u), size: 64)
                            Text(u.lastPathComponent).font(.system(size: 10.5)).lineLimit(2).multilineTextAlignment(.center)
                                .truncationMode(.middle).frame(width: 100)
                            UseInMenu(url: u)
                                .controlSize(.small)
                        }
                        .onDrag { NSItemProvider(contentsOf: u) ?? NSItemProvider() }
                        .contextMenu {
                            ForEach(Drawer.targets(for: u)) { t in
                                Button { Drawer.send([u], to: t) } label: { Label(t.title, systemImage: t.symbol) }
                            }
                            Divider()
                            Button("Togli dal Cassetto") { Drawer.shared.hide(u) }
                        }
                    }
                }
                .padding(2)
            }
            .frame(height: 340)
        }
        .padding(14)
        .frame(width: 400)
    }
}
