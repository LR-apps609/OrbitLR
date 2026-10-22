import SwiftUI
import AppKit

// ════════════════════════════════════════════════════════════════════
//  Animazione del marchio: un puntatore trascina un file sul logo,
//  il file «entra» e intorno al logo si apre il menu a torta.
//  Usata nella schermata di aggiornamento e nella scheda del primo avvio.
// ════════════════════════════════════════════════════════════════════

struct BrandAnimation: View {
    var size: CGSize = CGSize(width: 260, height: 170)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Durata di un giro completo dell'animazione, in secondi.
    private let cycle: Double = 5.6
    /// I file che arrivano, uno per giro: foto, PDF, video, audio.
    private let kinds: [Kind] = [.img, .pdf, .video, .audio]
    private let petalKinds: [Kind] = [.img, .pdf, .video, .audio, .doc, .sheet]

    var body: some View {
        TimelineView(.animation(minimumInterval: 1 / 60, paused: reduceMotion)) { tl in
            let elapsed = reduceMotion ? 2.6 : tl.date.timeIntervalSinceReferenceDate
            let t = elapsed.truncatingRemainder(dividingBy: cycle)
            let round = Int(elapsed / cycle) % kinds.count
            scene(t: t, kind: kinds[round])
        }
        .frame(width: size.width, height: size.height)
        .accessibilityHidden(true)
    }

    // MARK: Scena
    //  0,0–1,4 s  il puntatore trascina il file verso il logo (al centro)
    //  1,4–1,7 s  il file entra nel logo, che fa un piccolo sobbalzo
    //  1,6–2,5 s  il menu a torta si apre
    //  2,6–4,6 s  il puntatore passa sugli spicchi, che si allargano al passaggio
    //  4,6–5,3 s  il menu si richiude e il puntatore se ne va

    private func scene(t: Double, kind: Kind) -> some View {
        let w = size.width, h = size.height
        let logo = CGPoint(x: w / 2, y: h / 2)
        let start = CGPoint(x: w / 2 - min(w * 0.42, 130), y: h * 0.9)
        let logoSide = min(w, h) * 0.40
        let ringR: CGFloat = logoSide * 0.95

        // 1. Il file arriva trascinato
        let move = CGFloat(ease(seg(t, 0.3, 1.4)))
        let arc: CGFloat = CGFloat(sin(Double(move) * .pi)) * h * 0.16
        let fileX: CGFloat = start.x + (logo.x - start.x) * move
        let fileY: CGFloat = start.y + (logo.y - start.y) * move - arc
        let filePos = CGPoint(x: fileX, y: fileY)
        // 2. Il file entra nel logo
        let drop = ease(seg(t, 1.4, 1.7))
        let fileIn = seg(t, 0.0, 0.3)
        let fileOpacity = fileIn * (1 - drop)
        let fileScale = CGFloat(1 - 0.8 * drop)
        // 3. Il menu si apre, poi si richiude
        let bump = CGFloat(sin(seg(t, 1.45, 1.85) * .pi) * 0.08)
        let bloom: Double = spring(seg(t, 1.6, 2.5)) * (1 - ease(seg(t, 4.6, 5.2)))
        let ringSide: CGFloat = ringR * 2 * CGFloat(0.6 + 0.4 * bloom)

        // 4. Il puntatore: col file fino al logo, poi raggiunge l'anello e gira passando sugli spicchi
        let toRing = ease(seg(t, 2.2, 2.7))                    // dal logo al primo spicchio
        let sweep = ease(seg(t, 2.7, 4.5))                     // giro sugli spicchi
        let hoverAngle = -90 + 240 * sweep                     // gradi: parte dall'alto, senso orario
        let hoverRad: Double = hoverAngle * .pi / 180
        let ringPoint = CGPoint(x: logo.x + ringR * CGFloat(cos(hoverRad)), y: logo.y + ringR * CGFloat(sin(hoverRad)))
        let dragPoint = CGPoint(x: filePos.x + 10, y: filePos.y + 12)
        let kRing: CGFloat = CGFloat(toRing)
        let fromX: CGFloat = logo.x + 10, fromY: CGFloat = logo.y + 12
        let toX: CGFloat = ringPoint.x + 6, toY: CGFloat = ringPoint.y + 8
        let ringCursor = CGPoint(x: fromX + (toX - fromX) * kRing, y: fromY + (toY - fromY) * kRing)
        let cursorPos: CGPoint = t < 2.2 ? dragPoint : ringCursor
        let cursorOpacity = fileIn * (1 - seg(t, 4.7, 5.1))
        let hovering = toRing * (1 - seg(t, 4.5, 4.7))         // 0…1: quanto il puntatore è «sull'anello»

        return ZStack {
            // Anello del menu
            Circle()
                .strokeBorder(Theme.brass.opacity(0.55 * min(1, bloom)), lineWidth: 2)
                .frame(width: ringSide, height: ringSide)
                .position(logo)

            // Spicchi: si allargano quando il puntatore ci passa sopra
            ForEach(Array(petalKinds.enumerated()), id: \.offset) { i, k in
                petal(i, kind: k, bloom: bloom, hoverAngle: hoverAngle, hovering: hovering,
                      logo: logo, ringR: ringR, logoSide: logoSide)
            }

            // Logo, al centro
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: logoSide, height: logoSide)
                .scaleEffect(1 + bump)
                .shadow(color: Theme.shadow.opacity(0.25), radius: 8, y: 4)
                .position(logo)

            // File trascinato
            KindBadge(kind: kind, size: logoSide * 0.42)
                .scaleEffect(fileScale)
                .opacity(fileOpacity)
                .position(filePos)

            // Puntatore
            Image(systemName: "cursorarrow")
                .font(.system(size: 20, weight: .regular))
                .foregroundStyle(Theme.ink)
                .shadow(color: Theme.cream, radius: 1)
                .opacity(cursorOpacity)
                .position(cursorPos)
        }
        .frame(width: w, height: h)
    }

    private func petal(_ i: Int, kind: Kind, bloom: Double, hoverAngle: Double, hovering: Double,
                       logo: CGPoint, ringR: CGFloat, logoSide: CGFloat) -> some View {
        let lag: Double = Double(i) / Double(petalKinds.count) * 0.35
        let o: Double = max(0, min(1.1, (bloom - lag) / (1 - lag)))
        let home: Double = -90 + Double(i) * 60
        let a: Double = (home - 60 * (1 - min(o, 1))) * .pi / 180
        let r: CGFloat = ringR * CGFloat(0.3 + 0.7 * o)
        let px: CGFloat = logo.x + r * CGFloat(cos(a))
        let py: CGFloat = logo.y + r * CGFloat(sin(a))
        let p = CGPoint(x: px, y: py)
        // Distanza (in gradi) tra il puntatore e lo spicchio: sotto i 30° lo spicchio si allarga
        var d = abs(hoverAngle - home).truncatingRemainder(dividingBy: 360)
        if d > 180 { d = 360 - d }
        let lift: Double = max(0, 1 - d / 30) * hovering
        // Valori calcolati a parte: un'unica espressione lunga è troppo pesante per il compilatore
        let tint: Color = Theme.color(kind)
        let side: CGFloat = logoSide * 0.36
        let iconSize: CGFloat = logoSide * 0.14
        let glow: Color = lift > 0.3 ? tint.opacity(0.6) : Theme.shadow.opacity(0.2)
        let glowRadius: CGFloat = CGFloat(3 + 6 * lift)
        let scale: CGFloat = CGFloat((0.3 + 0.7 * o) * (1 + 0.4 * lift))
        let alpha: Double = min(1, o * 1.5)
        let icon = Image(systemName: Theme.symbol(kind))
            .font(.system(size: iconSize, weight: .bold))
            .foregroundStyle(Color.white)
        let disc = Circle().fill(tint.gradient).frame(width: side, height: side)
        return disc
            .overlay(icon)
            .shadow(color: glow, radius: glowRadius, y: 1)
            .scaleEffect(scale)
            .opacity(alpha)
            .position(p)
    }

    // MARK: Curve

    /// Avanzamento da 0 a 1 tra a e b.
    private func seg(_ t: Double, _ a: Double, _ b: Double) -> Double { max(0, min(1, (t - a) / (b - a))) }
    private func ease(_ x: Double) -> Double { x * x * (3 - 2 * x) }
    /// Molla: supera di poco l'arrivo e torna indietro.
    private func spring(_ x: Double) -> Double {
        guard x > 0 else { return 0 }
        return 1 - exp(-6 * x) * cos(7 * x)
    }
}

/// «circa 1 min 20 s», «circa 40 s», «pochi secondi»
func roughDuration(_ seconds: Double) -> String {
    let s = Int(seconds.rounded())
    if s <= 8 { return "pochi secondi" }
    if s < 60 { return "circa \(Int((Double(s) / 5).rounded()) * 5) s" }
    let m = s / 60, r = Int((Double(s % 60) / 10).rounded()) * 10
    if r == 0 { return "circa \(m) min" }
    if r == 60 { return "circa \(m + 1) min" }
    return "circa \(m) min \(r) s"
}
