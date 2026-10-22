import Foundation

// ════════════════════════════════════════════════════════════════════
//  Account — prima base, NON ancora collegata all'interfaccia.
//
//  Piano:
//   1. «Accedi con Apple» (AuthenticationServices): niente password da gestire.
//      Richiede l'Apple Developer Program per firmare l'app con questa capacità.
//   2. Sincronizzazione di preset, scorciatoie e cronologia tra i propri Mac (CloudKit).
//   3. Eventuale piano «Pro» per funzioni avanzate, se un giorno l'app verrà distribuita.
//
//  Le conversioni restano sempre sul Mac: l'account non riceve mai i file.
// ════════════════════════════════════════════════════════════════════

struct UserAccount: Codable, Equatable {
    enum Plan: String, Codable { case free, pro }
    let id: String
    var name: String
    var email: String?
    var plan: Plan
    var createdAt: Date
}

protocol AuthProvider {
    func restore() async -> UserAccount?
    func signIn() async throws -> UserAccount
    func signOut() async
}

final class AccountStore: ObservableObject {
    /// Interruttore generale: finché è falso, l'app non mostra nulla che riguardi gli account.
    static let isEnabled = false

    @Published private(set) var user: UserAccount?
    @Published private(set) var busy = false
    private let provider: AuthProvider

    init(provider: AuthProvider = LocalAuthProvider()) {
        self.provider = provider
    }

    var isSignedIn: Bool { user != nil }

    @MainActor func restore() async {
        guard Self.isEnabled else { return }
        user = await provider.restore()
    }

    @MainActor func signIn() async throws {
        guard Self.isEnabled else { return }
        busy = true
        defer { busy = false }
        user = try await provider.signIn()
    }

    @MainActor func signOut() async {
        await provider.signOut()
        user = nil
    }
}

/// Provvisorio, solo per lo sviluppo: un account locale salvato su questo Mac.
/// Verrà sostituito da «Accedi con Apple».
final class LocalAuthProvider: AuthProvider {
    private let key = "lr.account.local"

    func restore() async -> UserAccount? {
        guard let d = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(UserAccount.self, from: d)
    }

    func signIn() async throws -> UserAccount {
        let u = UserAccount(id: UUID().uuidString, name: NSFullUserName(), email: nil, plan: .free, createdAt: Date())
        if let d = try? JSONEncoder().encode(u) { UserDefaults.standard.set(d, forKey: key) }
        return u
    }

    func signOut() async {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
