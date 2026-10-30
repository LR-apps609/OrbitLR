import SwiftUI

import AppKit

extension View {
    /// 5.2 · Area di clic di almeno 24 × 24 pt, anche quando il disegno resta piccolo.
    func hitArea(_ side: CGFloat = 24) -> some View {
        frame(minWidth: side, minHeight: side).contentShape(Rectangle())
    }
}

/// Colori e stili condivisi: ogni tipo di file ha il suo colore, usato in menu, coda e cronologia.
extension Color {
    /// Colore da codice esadecimale, es. Color(hex: 0xA9C5A0)
    init(hex: UInt32, opacity: Double = 1) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255, opacity: opacity)
    }
}

extension Color {
    /// Colore che cambia da solo tra modalità chiara e scura.
    init(light: UInt32, dark: UInt32, lightOpacity: Double = 1, darkOpacity: Double = 1) {
        func ns(_ hex: UInt32, _ a: Double) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: CGFloat(a))
        }
        let l = ns(light, lightOpacity), d = ns(dark, darkOpacity)
        self.init(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? d : l
        })
    }
}

/// Tema di colori (punto 39): la stessa radio d'epoca in tre tinte.
enum Palette: String, CaseIterable, Identifiable {
    case sage, sky, terracotta
    var id: String { rawValue }

    var name: String {
        switch self {
        case .sage: return String(localized: "Salvia (la radio classica)")
        case .sky: return String(localized: "Crema e celeste")
        case .terracotta: return String(localized: "Crema e terracotta")
        }
    }

    /// Il tema in uso. Si aggiorna dalle Opzioni; i colori lo leggono ogni volta che vengono disegnati.
    static var current: Palette = Palette(rawValue: UserDefaults.standard.string(forKey: "palette") ?? "") ?? .sage
}

extension Color {
    /// Colore che dipende dal tema e dalla modalità chiara/scura: (chiaro, scuro) per salvia, celeste e terracotta.
    init(themed sage: (UInt32, UInt32), sky: (UInt32, UInt32), terracotta: (UInt32, UInt32)) {
        func ns(_ hex: UInt32) -> NSColor {
            NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                    blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
        }
        let table: [Palette: (NSColor, NSColor)] = [
            .sage: (ns(sage.0), ns(sage.1)),
            .sky: (ns(sky.0), ns(sky.1)),
            .terracotta: (ns(terracotta.0), ns(terracotta.1)),
        ]
        self.init(nsColor: NSColor(name: nil) { appearance in
            let pair = table[Palette.current] ?? table[.sage]!
            return appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? pair.1 : pair.0
        })
    }
}

/// Aspetto scelto nelle Opzioni: Automatico (come il Mac), Chiaro o Scuro.
enum Appearance {
    static var current: String { UserDefaults.standard.string(forKey: "appearance") ?? "auto" }

    static func apply(_ value: String = current) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

/// Palette ispirata alla radio d'epoca: verde salvia, crema della griglia, avorio delle manopole, ottone.
/// Di notte («radio di notte»): salvia scuro, ottone più caldo, crema attenuato.
/// Ogni tipo di file ha il suo colore, in tinte «vintage» che stanno bene insieme.
enum Theme {
    // Base
    // Corpo della radio, pulsanti e selezioni: cambiano con il tema (salvia, celeste, terracotta)
    static let sage = Color(themed: (0xA9C5A0, 0x3C5243), sky: (0xA9C8DA, 0x34505F), terracotta: (0xDDA98F, 0x5C3B2F))
    static let sageLight = Color(themed: (0xC9DCC2, 0x4A6351), sky: (0xCCE0EB, 0x415F6E), terracotta: (0xEFD0C0, 0x6E483A))
    static let sageDeep = Color(themed: (0x557E5F, 0x8FBE98), sky: (0x4B7C98, 0x8EC2DC), terracotta: (0xB35F3E, 0xE59C79))
    static let cream = Color(themed: (0xF3EDDF, 0x1E221F), sky: (0xF3EFE4, 0x1C2125), terracotta: (0xF4ECDF, 0x241E1C)) // sfondo
    static let parchment = Color(light: 0xE6D8B8, dark: 0x4A4333)   // griglia dell'altoparlante
    static let parchmentDeep = Color(light: 0xDCCCA6, dark: 0x3B3528)
    static let ivory = Color(themed: (0xFBF8F0, 0x2C302C), sky: (0xFBF9F3, 0x2A2F33), terracotta: (0xFCF8F1, 0x322B28)) // manopole e schede
    static let brass = Color(light: 0xB8925A, dark: 0xD6AA62)       // finiture in ottone
    static let ink = Color(light: 0x3A3126, dark: 0xECE4D2)         // testo

    // Nomi usati nel resto dell'app
    static let accent = sageDeep
    static let orange = brass
    static let green = Color(light: 0x5E9A55, dark: 0x82BE76)
    static let background = cream
    static let card = ivory
    static let cardHover = Color(themed: (0xF6F0E2, 0x343933), sky: (0xF4F1E8, 0x32383D), terracotta: (0xF7EEE2, 0x3B3330))
    static let stroke = Color(light: 0x3A3126, dark: 0xECE4D2, lightOpacity: 0.11, darkOpacity: 0.12)
    /// Ombre: inchiostro di giorno, nero di notte (un'ombra chiara sembrerebbe un alone).
    static let shadow = Color(light: 0x3A3126, dark: 0x000000)

    static func color(_ k: Kind?) -> Color {
        switch k {
        case .pdf?:   return Color(hex: 0xC8654F)   // terracotta
        case .img?:   return Color(hex: 0x4E9A92)   // verde acqua
        case .audio?: return Color(hex: 0xC99134)   // senape
        case .video?: return Color(hex: 0x8A6BA6)   // prugna
        case .doc?:   return Color(hex: 0x5B7FAA)   // azzurro polvere
        case .sheet?: return Color(hex: 0x6E9A52)   // oliva
        case .slide?: return Color(hex: 0xD29F45)   // ambra
        case .text?:  return Color(hex: 0x7B83A8)   // ardesia
        default:      return accent
        }
    }

    static func symbol(_ k: Kind?) -> String {
        switch k {
        case .pdf?:   return "doc.richtext.fill"
        case .img?:   return "photo.fill"
        case .audio?: return "waveform"
        case .video?: return "film.fill"
        case .doc?:   return "doc.text.fill"
        case .sheet?: return "tablecells.fill"
        case .slide?: return "rectangle.on.rectangle"
        case .text?:  return "doc.plaintext.fill"
        default:      return "doc.fill"
        }
    }
}

struct CardStyle: ViewModifier {
    var radius: CGFloat = 14
    /// 2.7.7 · «Aumenta contrasto» di macOS: bordi più marcati, le schede si distinguono meglio dallo sfondo
    @Environment(\.colorSchemeContrast) private var contrast
    func body(content: Content) -> some View {
        let high = contrast == .increased
        content
            .background(RoundedRectangle(cornerRadius: radius, style: .continuous).fill(Theme.card)
                .shadow(color: Theme.shadow.opacity(high ? 0 : 0.08), radius: 6, y: 2))
            .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                .strokeBorder(high ? Theme.ink.opacity(0.55) : Theme.stroke, lineWidth: high ? 1.5 : 1))
    }
}

extension View {
    func card(radius: CGFloat = 14) -> some View { modifier(CardStyle(radius: radius)) }
}

/// Riquadro colorato con il simbolo del tipo di file.
struct KindBadge: View {
    let kind: Kind?
    var size: CGFloat = 40
    var body: some View {
        RoundedRectangle(cornerRadius: size * 0.26, style: .continuous)
            .fill(Theme.color(kind).gradient)
            .frame(width: size, height: size)
            .overlay(Image(systemName: Theme.symbol(kind)).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(.white))
            .shadow(color: Theme.color(kind).opacity(0.30), radius: 5, y: 2)
    }
}

/// Bagliore colorato di sfondo, nel colore del tipo di file aperto.
struct GlowBackground: View {
    let tint: Color
    var body: some View {
        ZStack {
            Theme.background
            RadialGradient(colors: [tint.opacity(0.20), Theme.sage.opacity(0.10), .clear], center: .center, startRadius: 20, endRadius: 560)
        }
        .ignoresSafeArea()
    }
}

/// Barra di avanzamento sottile e colorata.
struct ProgressBar: View {
    let value: Double      // 0…1, o negativo per «in corso»
    let tint: Color
    var height: CGFloat = 6
    @State var phase: CGFloat = 0
    var body: some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(tint.opacity(0.18))
                if value >= 0 {
                    Capsule().fill(tint.gradient).frame(width: max(6, g.size.width * value))
                        .animation(.easeOut(duration: 0.25), value: value)
                } else {
                    Capsule().fill(tint.gradient).frame(width: g.size.width * 0.3)
                        .offset(x: phase * g.size.width * 0.7)
                        .onAppear {
                            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) { phase = 1 }
                        }
                }
            }
        }
        .frame(height: height)
        .clipShape(Capsule())
    }
}

// MARK: - 2.7.7 · Movimento

/// Le «molle» dell'app, ma con «Riduci movimento» attivo in macOS diventano una dissolvenza breve e ferma.
enum Motion {
    static var reduced: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    static func spring(_ response: Double, _ damping: Double) -> Animation {
        reduced ? .easeOut(duration: 0.12) : .spring(response: response, dampingFraction: damping)
    }

    /// 3.1 · Un solo modo di muoversi in tutta l'app.
    /// Piccole cose che compaiono o spariscono (un pulsante, una riga, una voce): rapido e morbido.
    static var quick: Animation { reduced ? .easeOut(duration: 0.08) : .snappy(duration: 0.2, extraBounce: 0) }
    /// Un pannello o una pagina che cambia: un po' più lento, si posa senza rimbalzo.
    static var page: Animation { reduced ? .easeOut(duration: 0.1) : .smooth(duration: 0.28) }
}

/// 3.5 · Vero se la scheda è quella davanti (le schede vive ma nascoste fermano le loro animazioni)
private struct FrontTabKey: EnvironmentKey { static let defaultValue = true }
extension EnvironmentValues {
    var isFrontTab: Bool {
        get { self[FrontTabKey.self] }
        set { self[FrontTabKey.self] = newValue }
    }
}

/// 3.5 · Un movimento continuo che gira solo quando si vede: scheda davanti e finestra attiva.
struct LoopDriver: ViewModifier {
    @Binding var on: Bool
    let animation: Animation
    @Environment(\.isFrontTab) private var front
    @Environment(\.controlActiveState) private var active
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var running: Bool { front && active != .inactive && !reduceMotion }

    func body(content: Content) -> some View {
        content
            .onAppear { update(running) }
            .onChange(of: running) { _, r in update(r) }
    }

    private func update(_ r: Bool) {
        if r {
            withAnimation(animation) { on = true }
        } else {
            var t = Transaction()
            t.disablesAnimations = true
            withTransaction(t) { on = false }
        }
    }
}

/// 3.4.9 · Il tocco di tutti i pulsanti «disegnati a mano» (strumenti, formati, pastiglie):
/// al clic si abbassano appena e tornano su, sempre allo stesso modo.
struct Pressable: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !Motion.reduced ? 0.965 : 1)
            .brightness(configuration.isPressed ? -0.03 : 0)
            .animation(Motion.quick, value: configuration.isPressed)
    }
}
