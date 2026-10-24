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
            KeyGroup(title: "Aprire il menu", symbol: "circle.circle", rows: [
                Row(keys: ["⌥", "⌘", "C"], text: "Sui file selezionati nel Finder"),
                Row(keys: ["Clic destro"], text: "Nel Finder → OrbitLR (o in Servizi)"),
                Row(keys: ["Trascina"], text: "Nella finestra o sull’icona nel Dock"),
            ]),
            KeyGroup(title: "Nel menu a torta", symbol: "chart.pie.fill", rows: [
                Row(keys: ["1", "…", "8"], text: "Sceglie lo spicchio"),
                Row(keys: ["↩"], text: "Ripete l’ultima scelta (o quella consigliata)"),
                Row(keys: ["esc"], text: "Torna indietro o chiude"),
                Row(keys: ["Spazio"], text: "Anteprima del file"),
                Row(keys: ["a", "…", "z"], text: "Scrivi per cercare un’azione, ↑↓ e ↩ per sceglierla"),
            ]),
            KeyGroup(title: "Manopole", symbol: "dial.medium", rows: [
                Row(keys: ["←", "→"], text: "Posizione precedente / successiva"),
                Row(keys: ["Rotellina"], text: "Gira la manopola"),
                Row(keys: ["Clic"], text: "Passa alla posizione successiva"),
            ]),
            // 3.4.8 · Il montaggio dalla tastiera
            KeyGroup(title: "Montaggio video", symbol: "film", rows: [
                Row(keys: ["Spazio"], text: "Riproduci / pausa"),
                Row(keys: ["J", "K", "L"], text: "Indietro di un secondo · pausa · riproduci"),
                Row(keys: ["←", "→"], text: "Un fotogramma indietro / avanti"),
                Row(keys: ["⇧", "←", "→"], text: "Un secondo indietro / avanti"),
                Row(keys: ["↖", "↘"], text: "Inizio / fine del montaggio (fn ← / fn →)"),
                Row(keys: ["S"], text: "Dividi la clip"),
                Row(keys: ["T"], text: "Aggiungi un testo"),
                Row(keys: ["⌫"], text: "Togli la clip scelta"),
                Row(keys: ["⌘", "↩"], text: "Applica le modifiche"),
                Row(keys: ["⌘", "E"], text: "Esporta"),
            ]),
            KeyGroup(title: "Finestra", symbol: "macwindow", rows: [
                Row(keys: ["⌘", "/"], text: "Questo elenco"),
                Row(keys: ["⌘", ","], text: "Opzioni"),
            ]),
        ]
        let assigned = presets.presets.filter { $0.hotkey != nil }.sorted { ($0.hotkey ?? 0) < ($1.hotkey ?? 0) }
        list.insert(KeyGroup(title: "Le mie azioni", symbol: "star.circle.fill", rows: assigned.isEmpty
            ? [Row(keys: ["⌃", "⌥", "1…9"], text: "Nessuna ancora: si assegnano nella pagina «Le mie azioni»")]
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
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(Theme.ivory))
            .overlay(RoundedRectangle(cornerRadius: 5, style: .continuous).strokeBorder(Theme.ink.opacity(0.18)))
            .shadow(color: Theme.shadow.opacity(0.12), radius: 0, y: 1)
    }
}
