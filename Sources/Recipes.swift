import Foundation
import SwiftUI

// ════════════════════════════════════════════════════════════════════
//  3.2 · Ricette: più passi in fila, rifatti con un clic.
//  OrbitLR si accorge da sola quando un file creato viene lavorato di
//  nuovo (converti in MP3 → taglia → suoneria) e propone di salvare i
//  passi come ricetta. La ricetta compare nel menu a torta del suo tipo
//  di file e nella pagina Scorciatoie; ogni passo parte dal risultato
//  del passo prima.
// ════════════════════════════════════════════════════════════════════

struct RecipeStep: Codable, Equatable, Sendable {
    var actionId: String
    var param: String
    var title: String
}

struct Recipe: Codable, Equatable, Identifiable, Sendable {
    var id = UUID()
    var name: String
    /// Il tipo di file da cui parte (quello del primo passo).
    var kind: String
    var steps: [RecipeStep]

    /// «MP3 → Taglia → Suoneria iPhone»
    var summary: String { steps.map(\.title).joined(separator: " → ") }
}

final class RecipeStore: ObservableObject, @unchecked Sendable {
    static let shared = RecipeStore()
    static let maxSteps = 5

    @Published private(set) var recipes: [Recipe] = []
    private let url: URL

    init(url: URL = Paths.support.appendingPathComponent("ricette.json")) {
        self.url = url
        if let d = try? Data(contentsOf: url), let r = try? JSONDecoder().decode([Recipe].self, from: d) { recipes = r }
    }

    private func save() {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(recipes) { try? d.write(to: url, options: .atomic) }
    }

    // MARK: Trovare i passi

    /// I passi che hanno portato a questa voce della cronologia: si risale finché il file di partenza
    /// è stato creato da OrbitLR. Dal primo all'ultimo; vuoto se c'è un passo solo.
    static func chain(endingAt entry: HistoryEntry, in history: [HistoryEntry]) -> [HistoryEntry] {
        var out = [entry]
        var current = entry
        while out.count < maxSteps, let input = current.inputs?.first,
              let prev = history.first(where: { $0.id != current.id && !$0.undone && $0.date <= current.date && $0.outputs.contains(input) }),
              prev.actionId != nil {
            out.insert(prev, at: 0)
            current = prev
        }
        guard out.count >= 2, out.allSatisfy({ $0.actionId != nil }) else { return [] }
        return out
    }

    /// Una ricetta dai passi trovati (senza salvarla).
    static func recipe(from chain: [HistoryEntry]) -> Recipe? {
        guard chain.count >= 2, let first = chain.first, let kind = first.kind ?? first.inputs?.first.flatMap({ Catalog.kind(of: URL(fileURLWithPath: $0))?.rawValue }) else { return nil }
        let steps = chain.compactMap { e in e.actionId.map { RecipeStep(actionId: $0, param: e.param ?? "", title: shortTitle($0, e.action)) } }
        guard steps.count == chain.count else { return nil }
        // 3.5.2 · Una password non si salva mai in una ricetta: i passi con password restano a mano
        guard !steps.contains(where: { Job.secretActions.contains($0.actionId) }) else { return nil }
        return Recipe(name: steps.map(\.title).joined(separator: " → "), kind: kind, steps: steps)
    }

    /// Il nome breve di un passo: il formato per le conversioni, il titolo per il resto.
    static func shortTitle(_ id: String, _ title: String) -> String {
        if id.hasPrefix("to:") {
            let t = String(id.dropFirst(3))
            return ["docx": "Word", "xlsx": "Excel", "pptx": "PowerPoint"][t] ?? t.uppercased()
        }
        return title
    }

    func isSaved(_ r: Recipe) -> Bool { recipes.contains { $0.kind == r.kind && $0.steps.map(\.actionId) == r.steps.map(\.actionId) && $0.steps.map(\.param) == r.steps.map(\.param) } }

    func add(_ r: Recipe) {
        guard !isSaved(r) else { return }
        recipes.insert(r, at: 0)
        save()
    }

    func delete(_ r: Recipe) { recipes.removeAll { $0.id == r.id }; save() }

    /// 5.1 · Elimina con «Annulla» e ⌘Z.
    func deleteUndoably(_ r: Recipe) {
        guard let i = recipes.firstIndex(where: { $0.id == r.id }) else { return }
        let old = recipes[i]
        delete(old)
        UndoToast.shared.post(String(localized: "Eliminata «\(old.name)»."), at: .shortcuts) { [weak self] in self?.restore(old, at: i) }
    }

    /// 5.1 · Rimette una ricetta eliminata al suo posto (una volta sola).
    func restore(_ r: Recipe, at index: Int) {
        guard !recipes.contains(where: { $0.id == r.id }) else { return }
        recipes.insert(r, at: min(max(0, index), recipes.count))
        save()
    }

    func rename(_ r: Recipe, to name: String) {
        guard let i = recipes.firstIndex(where: { $0.id == r.id }) else { return }
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        recipes[i].name = clean.isEmpty ? r.summary : clean
        save()
    }

    func recipes(for kind: Kind) -> [Recipe] { recipes.filter { $0.kind == kind.rawValue } }

    // MARK: Nel menu a torta

    func action(for r: Recipe) -> Action {
        Action(id: "recipe:" + r.id.uuidString, short: r.name.count > 14 ? String(localized: "Ricetta") : r.name, title: r.name,
               hint: r.summary, symbol: "arrow.triangle.turn.up.right.circle.fill")
    }

    func recipe(for a: Action) -> Recipe? {
        guard a.id.hasPrefix("recipe:"), let u = UUID(uuidString: String(a.id.dropFirst(7))) else { return nil }
        return recipes.first { $0.id == u }
    }

    /// Le azioni del menu con le ricette in fondo al primo anello (le posizioni abituali non cambiano).
    func merged(_ base: [Action], kind: Kind) -> [Action] {
        let extra = recipes(for: kind).map { action(for: $0) }
        guard !extra.isEmpty else { return base }
        var out = base
        out.insert(contentsOf: extra, at: min(7, out.count))
        return out
    }

    // MARK: Eseguire

    /// Mette in coda il primo passo; ogni passo, finito bene, avvia il successivo sul suo risultato.
    @discardableResult
    func run(_ r: Recipe, files: [URL], store: QueueStore = .shared) -> Job? {
        Self.runSteps(r.steps[...], files: files, store: store)
    }

    private static func runSteps(_ steps: ArraySlice<RecipeStep>, files: [URL], store: QueueStore) -> Job? {
        guard let step = steps.first, !files.isEmpty,
              let kind = Catalog.kind(of: files[0]), let action = Catalog.action(id: step.actionId, kind: kind) else { return nil }
        let job = store.enqueue(files: files, action: action, param: step.param)
        let rest = steps.dropFirst()
        if !rest.isEmpty {
            job.then = { done in _ = runSteps(rest, files: done.outputs, store: store) }
        }
        return job
    }
}

// MARK: - Nella pagina Scorciatoie

struct RecipesSection: View {
    @ObservedObject var store = RecipeStore.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionLabel(text: String(localized: "Ricette"))
            if store.recipes.isEmpty {
                Text("Quando lavori un file appena creato (per esempio converti in MP3, poi tagli), in Attività compare «Salva come ricetta»: la prossima volta fai tutti i passi con un clic, dal menu a torta.")
                    .font(.system(size: 12.5)).foregroundStyle(.secondary).lineLimit(4)
            } else {
                ForEach(store.recipes) { r in RecipeRow(recipe: r) }
            }
        }
    }
}

private struct RecipeRow: View {
    let recipe: Recipe
    @State private var name = ""

    var body: some View {
        HStack(spacing: 12) {
            KindBadge(kind: Kind(rawValue: recipe.kind), size: 38)
            VStack(alignment: .leading, spacing: 3) {
                TextField("Nome", text: $name, onCommit: { RecipeStore.shared.rename(recipe, to: name) })
                    .textFieldStyle(.plain).font(.system(size: 13, weight: .semibold))
                Text(recipe.summary).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("\(recipe.steps.count) passi").font(.system(size: 12)).foregroundStyle(.secondary)
            Button(role: .destructive) { RecipeStore.shared.deleteUndoably(recipe) } label: { Image(systemName: "trash") }
                .help("Elimina la ricetta (i file non vengono toccati)")
        }
        .padding(12)
        .card(radius: 12)
        .onAppear { name = recipe.name }
    }
}

/// In Attività, sotto un lavoro fatto su un file appena creato: «Salva come ricetta».
struct SaveRecipeChip: View {
    let entry: HistoryEntry
    let history: [HistoryEntry]
    @ObservedObject private var store = RecipeStore.shared

    var body: some View {
        let chain = RecipeStore.chain(endingAt: entry, in: history)
        if let r = RecipeStore.recipe(from: chain) {
            if store.isSaved(r) {
                Label("Ricetta salvata", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 11.5, weight: .semibold)).foregroundStyle(Theme.green)
            } else {
                Button { withAnimation(Motion.quick) { store.add(r) } } label: {
                    Label("Salva come ricetta · \(r.summary)", systemImage: "arrow.triangle.turn.up.right.circle")
                        .font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                }
                .buttonStyle(.borderless).foregroundStyle(Theme.accent)
                .help("La prossima volta fai tutti questi passi con un clic, dal menu a torta")
            }
        }
    }
}
