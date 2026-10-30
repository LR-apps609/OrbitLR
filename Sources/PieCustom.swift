import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  «Personalizza il menu»: per ogni tipo di file scegli l'ordine delle azioni.
//  Le prime 7 formano l'anello principale; le altre finiscono in «Altro».
// ════════════════════════════════════════════════════════════════════

enum PieCustom {
    private static func key(_ k: Kind) -> String { "pieOrder." + k.rawValue }

    static func order(for k: Kind) -> [String]? { UserDefaults.standard.stringArray(forKey: key(k)) }
    static func set(_ ids: [String], for k: Kind) { UserDefaults.standard.set(ids, forKey: key(k)) }
    static func reset(_ k: Kind) { UserDefaults.standard.removeObject(forKey: key(k)) }

    /// Mette prima le azioni nell'ordine scelto; quelle nuove (o mai ordinate) seguono nell'ordine di sempre.
    static func apply(_ actions: [Action], kind: Kind) -> [Action] {
        guard let pref = order(for: kind), !pref.isEmpty else { return actions }
        var out: [Action] = []
        for id in pref { if let a = actions.first(where: { $0.id == id }) { out.append(a) } }
        for a in actions where !out.contains(where: { $0.id == a.id }) { out.append(a) }
        return out
    }
}

struct PieCustomizeView: View {
    let done: () -> Void
    @State private var kind: Kind = .img
    @State private var actions: [Action] = []

    private let kinds: [Kind] = [.img, .pdf, .video, .audio, .doc, .sheet, .slide, .text]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "chart.pie.fill").font(.system(size: 20)).foregroundStyle(Theme.accent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Personalizza il menu a torta").font(.system(size: 16, weight: .bold))
                    Text("Trascina le azioni per ordinarle. Le prime 7 sono nell’anello principale, le altre in «Altro».")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            Picker("Tipo di file", selection: $kind) {
                ForEach(kinds, id: \.self) { k in Text(k.label).tag(k) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            List {
                ForEach(Array(actions.enumerated()), id: \.element.id) { i, a in
                    HStack(spacing: 10) {
                        Text("\(i + 1)").font(.system(size: 11, weight: .bold, design: .rounded)).monospacedDigit()
                            .foregroundStyle(i < 7 ? Theme.ivory : Color.secondary)
                            .frame(width: 22, height: 22)
                            .background(Circle().fill(i < 7 ? AnyShapeStyle(Theme.color(kind).gradient) : AnyShapeStyle(Theme.ink.opacity(0.08))))
                        Image(systemName: a.symbol).frame(width: 18).foregroundStyle(Theme.color(kind))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.title).font(.system(size: 13, weight: i < 7 ? .semibold : .regular))
                            Text(a.hint).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if i == 6 {
                            Text("fine anello principale").font(.system(size: 10)).foregroundStyle(.tertiary)
                        }
                        Image(systemName: "line.3.horizontal").foregroundStyle(.tertiary)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { from, to in
                    actions.move(fromOffsets: from, toOffset: to)
                    PieCustom.set(actions.map { $0.id }, for: kind)
                }
            }
            .frame(height: 380)
            .clipShape(RoundedRectangle(cornerRadius: 10))

            UndoToastBar(place: .pieOrder)          // 5.1

            HStack {
                Button("Ripristina l’ordine di partenza") {
                    // 5.1 · L'ordine scelto non si perde: «Annulla» o ⌘Z lo rimettono
                    let k = kind
                    if let old = PieCustom.order(for: k), !old.isEmpty {
                        PieCustom.reset(k)
                        UndoToast.shared.post(String(localized: "Ordine di partenza ripristinato."), at: .pieOrder) {
                            PieCustom.set(old, for: k)
                            reload()
                        }
                    } else {
                        PieCustom.reset(k)
                    }
                    reload()
                }
                Spacer()
                Button("Fatto") { done() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
            }
        }
        .padding(22)
        .frame(width: 600)
        .background(Theme.cream)
        .onAppear(perform: reload)
        .onChange(of: kind) { _, _ in reload() }
    }

    private func reload() {
        // Tutte le azioni possibili per quel tipo (anche quelle che compaiono solo con più file)
        actions = Catalog.actions(for: kind, exts: [], mergeable: 2)
    }
}
