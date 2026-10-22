import Foundation
import ServiceManagement

/// Le impostazioni stanno nello stesso file che usa il motore (Application Support/LRConverter/prefs),
/// così app e Azione rapida si comportano allo stesso modo.
enum ScriptPrefs {
    static func load() -> [String: String] {
        guard let s = try? String(contentsOf: Paths.prefs, encoding: .utf8) else { return [:] }
        var d: [String: String] = [:]
        for line in s.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "="), eq != line.startIndex else { continue }
            d[String(line[..<eq])] = String(line[line.index(after: eq)...])
        }
        return d
    }

    static func set(_ key: String, _ value: String) {
        var d = load()
        d[key] = value
        let text = d.keys.sorted().map { "\($0)=\(d[$0] ?? "")" }.joined(separator: "\n") + "\n"
        try? FileManager.default.createDirectory(at: Paths.support, withIntermediateDirectories: true)
        try? text.write(to: Paths.prefs, atomically: true, encoding: .utf8)
    }
}

final class SettingsModel: ObservableObject {
    @Published var dest: String { didSet { ScriptPrefs.set("dest", dest) } }                 // same | sub | fixed
    @Published var destPath: String { didSet { ScriptPrefs.set("destpath", destPath) } }
    @Published var quality: String { didSet { ScriptPrefs.set("wq", quality) } }             // small | turbo
    @Published var language: String { didSet { ScriptPrefs.set("wlang", language) } }        // auto | it | en | …
    @Published var quickActionMenu: String { didSet { ScriptPrefs.set("menu", quickActionMenu) } } // native | classic
    @Published var original: String { didSet { UserDefaults.standard.set(original, forKey: "original") } } // keep | trash
    @Published var keepDates: Bool { didSet { UserDefaults.standard.set(keepDates, forKey: "keepDates") } }
    @Published var useNative: Bool { didSet { UserDefaults.standard.set(!useNative, forKey: "disableNative") } }
    @Published var appearance: String {                                                       // auto | light | dark
        didSet { UserDefaults.standard.set(appearance, forKey: "appearance"); Appearance.apply(appearance) }
    }
    @Published var sounds: Bool { didSet { UserDefaults.standard.set(sounds, forKey: "sounds") } }
    @Published var splash: Bool { didSet { UserDefaults.standard.set(splash, forKey: "launchScreen") } }
    @Published var controlStyle: String { didSet { UserDefaults.standard.set(controlStyle, forKey: "controlStyle") } }   // list | knob
    @Published var tips: Bool { didSet { UserDefaults.standard.set(tips, forKey: "tips") } }
    @Published var palette: String {                                                          // sage | sky | terracotta
        didSet {
            Palette.current = Palette(rawValue: palette) ?? .sage
            UserDefaults.standard.set(palette, forKey: "palette")
        }
    }
    @Published var hotkey: Bool {
        didSet {
            UserDefaults.standard.set(hotkey, forKey: "hotkey")
            if hotkey { Hotkey.shared.register() } else { Hotkey.shared.unregister() }
        }
    }
    @Published var launchAtLogin: Bool {
        didSet {
            do {
                if launchAtLogin { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("OrbitLR: avvio all'accesso non modificato: \(error)")
            }
        }
    }

    init() {
        let p = ScriptPrefs.load()
        dest = p["dest"] ?? "same"
        destPath = p["destpath"] ?? ""
        quality = p["wq"] ?? "small"
        language = p["wlang"] ?? "auto"
        quickActionMenu = p["menu"] ?? "native"
        original = UserDefaults.standard.string(forKey: "original") ?? "keep"
        keepDates = UserDefaults.standard.object(forKey: "keepDates") as? Bool ?? true
        useNative = !UserDefaults.standard.bool(forKey: "disableNative")
        appearance = UserDefaults.standard.string(forKey: "appearance") ?? "auto"
        sounds = UserDefaults.standard.object(forKey: "sounds") as? Bool ?? true
        palette = UserDefaults.standard.string(forKey: "palette") ?? "sage"
        splash = UserDefaults.standard.object(forKey: "launchScreen") as? Bool ?? true
        controlStyle = UserDefaults.standard.string(forKey: "controlStyle") ?? "list"
        tips = UserDefaults.standard.object(forKey: "tips") as? Bool ?? true
        hotkey = UserDefaults.standard.object(forKey: "hotkey") as? Bool ?? true
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }
}

/// Copia delle opzioni che si modifica nella finestra: diventa effettiva solo con «Applica modifiche».
struct SettingsDraft: Equatable {
    var dest = "same"
    var destPath = ""
    var original = "keep"
    var quality = "small"
    var language = "auto"
    var quickActionMenu = "native"
    var keepDates = true
    var useNative = true
    var appearance = "auto"
    var sounds = true
    var palette = "sage"
    var splash = true
    var controlStyle = "list"
    var tips = true
    var hotkey = true
    var launchAtLogin = false
}

extension SettingsModel {
    /// Rilegge le scelte che si possono cambiare anche fuori dalle Opzioni (es. «Non mostrare più»).
    func refresh() {
        let t = UserDefaults.standard.object(forKey: "tips") as? Bool ?? true
        if tips != t { tips = t }
    }

    var draft: SettingsDraft {
        SettingsDraft(dest: dest, destPath: destPath, original: original, quality: quality, language: language,
                      quickActionMenu: quickActionMenu, keepDates: keepDates, useNative: useNative,
                      appearance: appearance, sounds: sounds, palette: palette, splash: splash, controlStyle: controlStyle, tips: tips, hotkey: hotkey, launchAtLogin: launchAtLogin)
    }

    func apply(_ d: SettingsDraft) {
        if dest != d.dest { dest = d.dest }
        if destPath != d.destPath { destPath = d.destPath }
        if original != d.original { original = d.original }
        if quality != d.quality { quality = d.quality }
        if language != d.language { language = d.language }
        if quickActionMenu != d.quickActionMenu { quickActionMenu = d.quickActionMenu }
        if keepDates != d.keepDates { keepDates = d.keepDates }
        if useNative != d.useNative { useNative = d.useNative }
        if appearance != d.appearance { appearance = d.appearance }
        if sounds != d.sounds { sounds = d.sounds }
        if palette != d.palette { palette = d.palette }
        if splash != d.splash { splash = d.splash }
        if controlStyle != d.controlStyle { controlStyle = d.controlStyle }
        if tips != d.tips { tips = d.tips }
        if hotkey != d.hotkey { hotkey = d.hotkey }
        if launchAtLogin != d.launchAtLogin { launchAtLogin = d.launchAtLogin }
    }
}
