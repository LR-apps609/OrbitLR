import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  4.0 · «Suggerisci un'idea»: tre faccine e una riga di testo, mandate per email (anonime: solo la
//  versione di OrbitLR e di macOS). Dopo qualche lavoro riuscito OrbitLR lo chiede una volta sola,
//  con discrezione, nella nuvoletta del risultato.
// ════════════════════════════════════════════════════════════════════

enum Feedback {
    static let askedKey = "feedbackAsked"
    /// Dopo quanti lavori riusciti si chiede (una volta sola).
    static let threshold = 10

    static let faces: [(id: String, emoji: String, name: String)] = [("meh", "😕", "Così così"), ("ok", "🙂", "Bene"), ("love", "😍", "Benissimo")]

    /// Si può chiedere adesso? Solo una volta, e solo dopo un po' di lavori riusciti.
    static func shouldAsk(successes: Int, asked: Bool) -> Bool { !asked && successes >= threshold }

    static var successes: Int { QueueStore.shared.history.filter { !$0.undone && !$0.outputs.isEmpty }.count }

    static var shouldAskNow: Bool { shouldAsk(successes: successes, asked: UserDefaults.standard.bool(forKey: askedKey)) }

    static func markAsked() { UserDefaults.standard.set(true, forKey: askedKey) }

    /// L'email già pronta: oggetto e testo, senza nomi di file né percorsi.
    static func mail(face: String?, text: String) -> URL? {
        let f = faces.first { $0.id == face }
        let subject = "[OrbitLR \(BugReport.version)] Idea" + (f.map { " · \($0.name)" } ?? "")
        let body = """
        \(f.map { "Come mi trovo: \($0.emoji) \($0.name)\n\n" } ?? "")\(text.isEmpty ? "(scrivi qui la tua idea)" : text)

        ---
        OrbitLR \(BugReport.version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString)
        """
        var c = URLComponents()
        c.scheme = "mailto"
        c.path = BugReport.recipient
        c.queryItems = [URLQueryItem(name: "subject", value: subject), URLQueryItem(name: "body", value: body)]
        // Gli spazi come %20 (alcuni programmi di posta non capiscono «+»)
        return c.url.flatMap { URL(string: $0.absoluteString.replacingOccurrences(of: "+", with: "%2B")) }
    }

    @MainActor static func show(face: String? = nil) {
        markAsked()
        FeedbackWindow.shared.show(face: face)
    }
}

@MainActor
final class FeedbackWindow: NSObject, NSWindowDelegate {
    static let shared = FeedbackWindow()
    private var window: NSWindow?

    /// 5.1 · Il ✕ della finestra: con del testo scritto si chiede prima (il testo è già nella bozza).
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard ReportDraft.hasWork(text: ReportDraft.load(ReportDraft.ideaKey)) else { return true }
        guard DiscardAsk.confirm(String(localized: "Buttare l’idea?"), keep: String(localized: "Continua a scrivere")) else { return false }
        ReportDraft.clear(ReportDraft.ideaKey)
        return true
    }

    func show(face: String?) {
        let view = FeedbackView(face: face) { [weak self] in self?.window?.close() }
        if let w = window {
            w.contentViewController = NSHostingController(rootView: view)
        } else {
            let w = NSWindow(contentViewController: NSHostingController(rootView: view))
            w.title = String(localized: "Suggerisci un’idea")
            w.styleMask = [.titled, .closable]
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.center()
            window = w
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }
}

struct FeedbackView: View {
    @State var face: String?
    let close: () -> Void
    @State private var text = ReportDraft.load(ReportDraft.ideaKey)     // 5.1 · la bozza dell'ultima volta
    @State private var message: String? = nil

    private var canSend: Bool { face != nil || !ReportDraft.isBlank(text) }

    /// 5.1 · Esc e «Annulla»: con del testo si chiede prima di buttarlo.
    private func cancel() {
        if ReportDraft.hasWork(text: text) {
            guard DiscardAsk.confirm(String(localized: "Buttare l’idea?"), keep: String(localized: "Continua a scrivere")) else { return }
        }
        ReportDraft.clear(ReportDraft.ideaKey)
        close()
    }

    /// 5.1 · Se l'email non si apre, lo dici e la finestra resta aperta con il testo.
    private func send() {
        guard let u = Feedback.mail(face: face, text: text), NSWorkspace.shared.open(u) else {
            message = String(localized: "Non riesco ad aprire l’email. Scrivimi a \(BugReport.recipient).")
            return
        }
        ReportDraft.clear(ReportDraft.ideaKey)
        close()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Come ti trovi con OrbitLR?").font(.system(size: 17, weight: .bold, design: .rounded))
            HStack(spacing: 12) {
                ForEach(Feedback.faces, id: \.id) { f in
                    Button { face = f.id } label: {
                        VStack(spacing: 4) {
                            Text(f.emoji).font(.system(size: 30))
                            Text(String(localized: String.LocalizationValue(f.name))).font(.system(size: 11.5, weight: .semibold))
                        }
                        .frame(width: 96, height: 72)
                        .background(RoundedRectangle(cornerRadius: 12).fill(face == f.id ? Theme.accent.opacity(0.18) : Theme.ink.opacity(0.05)))
                        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(face == f.id ? Theme.accent : .clear, lineWidth: 2))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(String(localized: String.LocalizationValue(f.name)))
                }
            }
            Text("Un’idea, una cosa che manca, una che non ti piace:").font(.system(size: 12.5)).foregroundStyle(.secondary)
            TextEditor(text: $text)
                .font(.system(size: 13))
                .frame(height: 110)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 8).fill(Theme.ink.opacity(0.05)))
                .onChange(of: text) { _, v in ReportDraft.save(v, key: ReportDraft.ideaKey) }
            Text("Si apre un’email già pronta: contiene solo quello che scrivi e la versione di OrbitLR, niente nomi di file.")
                .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if let message {
                Label(message, systemImage: "exclamationmark.triangle.fill").font(.system(size: 12))
                    .foregroundStyle(Theme.color(.pdf)).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("Annulla") { cancel() }.keyboardShortcut(.cancelAction)
                Button("Scrivi l’email") { send() }
                .buttonStyle(.borderedProminent).tint(Theme.accent)
                .disabled(!canSend)
                .help(canSend ? String(localized: "Si apre un’email già pronta.") : String(localized: "Scegli una faccina o scrivi prima qualcosa."))
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
