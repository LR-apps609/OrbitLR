import SwiftUI

/// Pulsante ⌘ sempre visibile in alto nella finestra: apre l'elenco di tutte le scorciatoie.
struct ShortcutsButton: View {
    @State private var showing = false

    var body: some View {
        Button { showing.toggle() } label: {
            Label("Tasti", systemImage: "command").labelStyle(.titleAndIcon)
        }
        .help("Tutti i tasti rapidi di OrbitLR")
        .keyboardShortcut("/", modifiers: .command)
        .popover(isPresented: $showing, arrowEdge: .bottom) {
            ShortcutsPanel()
        }
    }
}

struct ShortcutsPanel: View {
    @ObservedObject var presets = PresetStore.shared

    private struct Row: Identifiable {
        let keys: [String]
        let text: String
        var id: String { keys.joined() + text }
    }

    private struct KeyGroup: Identifiable {
        let title: String
        let symbol: String
        let rows: [Row]
        var id: String { title }
    }

    private var groups: [KeyGroup] {
        var list = [
            KeyGroup(title: String(localized: "Aprire il menu"), symbol: "circle.circle", rows: [
                Row(keys: ["⌥", "⌘", "C"], text: String(localized: "Sui file selezionati nel Finder")),
                Row(keys: [String(localized: "Clic destro")], text: String(localized: "Nel Finder → OrbitLR (o in Servizi)")),
                Row(keys: [String(localized: "Trascina")], text: String(localized: "Nella finestra o sull’icona nel Dock")),
            ]),
            KeyGroup(title: String(localized: "Nel menu a torta"), symbol: "chart.pie.fill", rows: [
                Row(keys: ["1", "…", "8"], text: String(localized: "Sceglie lo spicchio")),
                Row(keys: ["↩"], text: String(localized: "Ripete l’ultima scelta (o quella consigliata)")),
                Row(keys: ["esc"], text: String(localized: "Torna indietro o chiude")),
                Row(keys: [String(localized: "Spazio")], text: String(localized: "Anteprima del file (nella finestra di OrbitLR)")),
                Row(keys: ["a", "…", "z"], text: String(localized: "Scrivi per cercare un’azione, ↑↓ e ↩ per sceglierla")),
            ]),
            KeyGroup(title: String(localized: "Manopole"), symbol: "dial.medium", rows: [
                Row(keys: ["←", "→"], text: String(localized: "Posizione precedente / successiva")),
                Row(keys: [String(localized: "Rotellina")], text: String(localized: "Gira la manopola")),
                Row(keys: [String(localized: "Clic")], text: String(localized: "Passa alla posizione successiva")),
            ]),
            // 3.4.8 · Il montaggio dalla tastiera
            KeyGroup(title: String(localized: "Montaggio video"), symbol: "film", rows: [
                Row(keys: [String(localized: "Spazio")], text: String(localized: "Riproduci / pausa")),
                Row(keys: ["J", "K", "L"], text: String(localized: "Indietro di un secondo · pausa · riproduci")),
                Row(keys: ["←", "→"], text: String(localized: "1/30 di secondo indietro / avanti")),
                Row(keys: ["⇧", "←", "→"], text: String(localized: "Un secondo indietro / avanti")),
                Row(keys: ["⌥", "←", "→"], text: String(localized: "Un millisecondo indietro / avanti")),
                Row(keys: ["⌘", "+", "−"], text: String(localized: "Ingrandisci / rimpicciolisci la sequenza")),
                Row(keys: ["↖", "↘"], text: String(localized: "Inizio / fine del montaggio (fn ← / fn →)")),
                Row(keys: ["S"], text: String(localized: "Dividi la clip")),
                Row(keys: ["T"], text: String(localized: "Aggiungi un testo")),
                Row(keys: ["⌫"], text: String(localized: "Togli la clip scelta")),
                Row(keys: ["⌘", "S"], text: String(localized: "Salva progetto (si salva anche da solo)")),
                Row(keys: ["⌘", "E"], text: String(localized: "Esporta")),
                Row(keys: ["⇧", "⌘", "N"], text: String(localized: "Nuovo progetto video")),
            ]),
            KeyGroup(title: String(localized: "Finestra"), symbol: "macwindow", rows: [
                Row(keys: ["⌘", "/"], text: String(localized: "Questo elenco")),
                Row(keys: ["⌘", "1…5"], text: String(localized: "Converti, PDF e documenti, Immagini, Video, Audio")),
                Row(keys: ["⌘", "0"], text: String(localized: "Attività")),
                Row(keys: ["⌘", "O"], text: String(localized: "Apri dei file in Converti")),
                Row(keys: ["⌘", ","], text: String(localized: "Opzioni")),
            ]),
        ]
        let assigned = presets.presets.filter { $0.hotkey != nil }.sorted { ($0.hotkey ?? 0) < ($1.hotkey ?? 0) }
        list.insert(KeyGroup(title: String(localized: "Le mie azioni"), symbol: "star.circle.fill", rows: assigned.isEmpty
            ? [Row(keys: ["⌃", "⌥", "1…9"], text: String(localized: "Nessuna ancora: si assegnano nella pagina «Le mie azioni»"))]
            : assigned.map { Row(keys: ["⌃", "⌥", "\($0.hotkey ?? 0)"], text: $0.name) }), at: 2)
        return list
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 8) {
                Image(systemName: "command").font(.system(size: 14, weight: .bold)).foregroundStyle(Theme.accent)
                Text("Tasti rapidi").font(.system(size: 15, weight: .bold, design: .rounded))
            }
            ForEach(groups) { g in
                VStack(alignment: .leading, spacing: 6) {
                    Label(g.title, systemImage: g.symbol)
                        .font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.brass)
                    ForEach(g.rows) { r in
                        HStack(spacing: 10) {
                            HStack(spacing: 3) {
                                ForEach(Array(r.keys.enumerated()), id: \.offset) { _, k in keyCap(k) }
                            }
                            .frame(width: 128, alignment: .leading)
                            Text(r.text).font(.system(size: 12)).foregroundStyle(Theme.ink)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
            }
        }
        .padding(18)
        .frame(width: 400)
        .background(Theme.cream)
    }

    private func keyCap(_ k: String) -> some View {
        Text(k)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, k.count > 2 ? 7 : 5)
            .frame(minWidth: 22, minHeight: 20)
            .background(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).fill(Theme.ivory))
            .overlay(RoundedRectangle(cornerRadius: Radius.xs, style: .continuous).strokeBorder(Theme.ink.opacity(0.18)))
            .shadow(color: Theme.shadow.opacity(0.12), radius: 0, y: 1)
    }
}
