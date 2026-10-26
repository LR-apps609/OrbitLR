import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  4.2 · La lingua di OrbitLR: di base quella del Mac (italiano o inglese), oppure scelta a mano nelle Opzioni.
//  macOS sceglie la lingua all'avvio: dopo il cambio OrbitLR si riapre da solo.
// ════════════════════════════════════════════════════════════════════

enum AppLanguage {
    static let key = "appLanguage"            // auto | it | en

    static var current: String { UserDefaults.standard.string(forKey: key) ?? "auto" }

    /// La lingua in cui OrbitLR sta parlando adesso ("it" o "en").
    /// Solo l'app vera ha i testi inglesi: nei test (e se mancassero) si resta in italiano.
    static let active: String = {
        let l = Bundle.main.preferredLocalizations.first ?? "it"
        guard l.hasPrefix("en"), Bundle.main.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: "en") != nil
        else { return "it" }
        return "en"
    }()

    static func set(_ value: String) {
        UserDefaults.standard.set(value, forKey: key)
        if value == "auto" {
            UserDefaults.standard.removeObject(forKey: "AppleLanguages")
        } else {
            UserDefaults.standard.set([value], forKey: "AppleLanguages")
        }
        UserDefaults.standard.synchronize()
    }

    /// Riapre OrbitLR, così la nuova lingua vale ovunque.
    @MainActor static func relaunch() {
        let path = Bundle.main.bundleURL.path
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", path]
        do { try p.run() } catch { return }
        NSApp.terminate(nil)
    }
}

/// La riga delle Opzioni: «Lingua · Language».
struct LanguagePicker: View {
    @State private var value = AppLanguage.current
    @State private var askRestart = false

    var body: some View {
        Picker("Lingua · Language", selection: $value) {
            Text("Come il Mac").tag("auto")
            Text(verbatim: "Italiano").tag("it")
            Text(verbatim: "English").tag("en")
        }
        .onChange(of: value) { _, v in
            guard v != AppLanguage.current else { return }
            AppLanguage.set(v)
            askRestart = true
        }
        .alert("Riaprire OrbitLR adesso?", isPresented: $askRestart) {
            Button("Riapri") { AppLanguage.relaunch() }
            Button("Più tardi", role: .cancel) {}
        } message: {
            Text("La nuova lingua vale dalla prossima apertura.")
        }
    }
}
