//! Filtri e regolazioni del video, come sull'app per Mac: un filtro pronto (con la sua forza)
//! e sei regolazioni. Il colore diventa una sola matrice 3×4 (stessa matematica nell'anteprima,
//! con feColorMatrix, e nell'esportazione, con colorchannelmixer + lutrgb: filtri LGPL).

use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Look {
    pub preset: String,
    pub amount: f64,
    pub brightness: f64,
    pub contrast: f64,
    pub saturation: f64,
    pub warmth: f64,
    pub sharpness: f64,
    pub vignette: f64,
}

/// Matrice affine del colore: rgb' = m · rgb + o (valori tra 0 e 1).
#[derive(Debug, Clone, Copy, PartialEq)]
pub struct Affine {
    pub m: [[f64; 3]; 3],
    pub o: [f64; 3],
}

impl Affine {
    pub const ID: Affine = Affine { m: [[1., 0., 0.], [0., 1., 0.], [0., 0., 1.]], o: [0., 0., 0.] };

    /// Prima `self`, poi `next`.
    pub fn then(&self, next: &Affine) -> Affine {
        let mut m = [[0.0; 3]; 3];
        let mut o = [0.0; 3];
        for r in 0..3 {
            for c in 0..3 {
                m[r][c] = (0..3).map(|k| next.m[r][k] * self.m[k][c]).sum();
            }
            o[r] = (0..3).map(|k| next.m[r][k] * self.o[k]).sum::<f64>() + next.o[r];
        }
        Affine { m, o }
    }

    pub fn mix(&self, other: &Affine, t: f64) -> Affine {
        let mut out = *self;
        for r in 0..3 {
            for c in 0..3 {
                out.m[r][c] = self.m[r][c] * (1.0 - t) + other.m[r][c] * t;
            }
            out.o[r] = self.o[r] * (1.0 - t) + other.o[r] * t;
        }
        out
    }

    pub fn is_identity(&self) -> bool {
        let id = Affine::ID;
        (0..3).all(|r| (0..3).all(|c| (self.m[r][c] - id.m[r][c]).abs() < 1e-4) && self.o[r].abs() < 1e-4)
    }
}

const LUMA: [f64; 3] = [0.2126, 0.7152, 0.0722];

fn saturation(s: f64) -> Affine {
    let mut m = [[0.0; 3]; 3];
    for r in 0..3 {
        for c in 0..3 {
            m[r][c] = (1.0 - s) * LUMA[c] + if r == c { s } else { 0.0 };
        }
    }
    Affine { m, o: [0.0; 3] }
}

fn contrast(c: f64) -> Affine {
    let off = 0.5 * (1.0 - c);
    Affine { m: [[c, 0., 0.], [0., c, 0.], [0., 0., c]], o: [off; 3] }
}

fn brightness(b: f64) -> Affine {
    Affine { m: Affine::ID.m, o: [b; 3] }
}

fn controls(b: f64, s: f64, c: f64) -> Affine {
    saturation(s).then(&contrast(c)).then(&brightness(b))
}

fn tint(r: f64, g: f64, b: f64) -> Affine {
    Affine { m: [[r, 0., 0.], [0., g, 0.], [0., 0., b]], o: [0.0; 3] }
}

fn lift(a: f64) -> Affine {
    Affine { m: tint(1.0 - a, 1.0 - a, 1.0 - a).m, o: [a; 3] }
}

fn sepia(k: f64) -> Affine {
    let s = Affine { m: [[0.393, 0.769, 0.189], [0.349, 0.686, 0.168], [0.272, 0.534, 0.131]], o: [0.0; 3] };
    Affine::ID.mix(&s, k)
}

/// Colore del filtro pronto, la vignettatura che porta con sé e se ha il bagliore («Sogno»).
fn preset(id: &str) -> (Affine, f64, bool) {
    match id {
        "vivid" => (controls(0.0, 1.45, 1.08), 0.0, false),
        "warm" => (tint(1.10, 1.02, 0.86), 0.0, false),
        "cool" => (tint(0.88, 1.0, 1.12), 0.0, false),
        "mono" => (controls(0.0, 0.0, 1.12), 0.0, false),
        "sepia" => (sepia(0.85), 0.0, false),
        "vintage" => (sepia(0.35).then(&controls(0.0, 0.8, 0.92)).then(&lift(0.06)), 0.6, false),
        "film" => (tint(1.03, 1.0, 0.95).then(&controls(0.0, 0.88, 1.12)).then(&lift(0.03)), 0.0, false),
        "night" => (controls(-0.06, 0.75, 1.15).then(&tint(0.9, 0.97, 1.12)), 0.0, false),
        "dream" => (controls(0.03, 1.05, 1.0), 0.0, true),
        "drama" => (controls(0.0, 0.85, 1.3), 0.8, false),
        "pastel" => (controls(0.06, 0.6, 0.9), 0.0, false),
        "radio" => (sepia(0.25).then(&tint(1.04, 1.03, 0.9)).then(&controls(0.0, 0.9, 1.05)), 0.55, false),
        _ => (Affine::ID, 0.0, false),
    }
}

impl Look {
    pub fn is_identity(&self) -> bool {
        (self.preset.is_empty() || self.preset == "none" || self.amount < 0.001)
            && self.brightness.abs() < 0.001
            && self.contrast.abs() < 0.001
            && self.saturation.abs() < 0.001
            && self.warmth.abs() < 0.001
            && self.sharpness < 0.001
            && self.vignette < 0.001
    }

    /// Il colore finale, la vignettatura (0…1) e il bagliore (0…1).
    pub fn resolve(&self) -> (Affine, f64, f64) {
        let amount = self.amount.clamp(0.0, 1.0);
        let (p, pv, glow) = preset(&self.preset);
        let mut a = Affine::ID.mix(&p, amount);
        if self.brightness.abs() > 0.001 || self.contrast.abs() > 0.001 || self.saturation.abs() > 0.001 {
            a = a.then(&controls(self.brightness * 0.3, 1.0 + self.saturation, 1.0 + self.contrast * 0.5));
        }
        if self.warmth.abs() > 0.001 {
            let w = self.warmth;
            a = a.then(&tint(1.0 + 0.12 * w, 1.0 + 0.02 * w, 1.0 - 0.14 * w));
        }
        let vig = (pv * amount).max(self.vignette).clamp(0.0, 1.0);
        (a, vig, if glow { 0.6 * amount } else { 0.0 })
    }

    /// I filtri di ffmpeg (tutti LGPL) per questo look; stringa vuota se non c'è niente da fare.
    /// `tag` rende unici i nomi interni (serve quando ci sono più clip nello stesso grafo).
    pub fn ffmpeg_filter(&self, tag: &str) -> String {
        if self.is_identity() {
            return String::new();
        }
        let (a, vig, glow) = self.resolve();
        let mut f: Vec<String> = Vec::new();
        if glow > 0.001 {
            // Bagliore: una copia sfocata sommata con «schermo»
            f.push(format!("split[{tag}a][{tag}b];[{tag}b]gblur=sigma=12[{tag}c];[{tag}a][{tag}c]blend=all_mode=screen:all_opacity={:.3}", glow * 0.6));
        }
        if !a.is_identity() {
            let m = a.m;
            f.push(format!(
                "colorchannelmixer=rr={:.4}:rg={:.4}:rb={:.4}:gr={:.4}:gg={:.4}:gb={:.4}:br={:.4}:bg={:.4}:bb={:.4}",
                m[0][0], m[0][1], m[0][2], m[1][0], m[1][1], m[1][2], m[2][0], m[2][1], m[2][2]
            ));
            if a.o.iter().any(|x| x.abs() > 1e-4) {
                f.push(format!("lutrgb=r=val+{:.2}:g=val+{:.2}:b=val+{:.2}", a.o[0] * 255.0, a.o[1] * 255.0, a.o[2] * 255.0).replace("+-", "-"));
            }
        }
        if self.sharpness > 0.001 {
            f.push(format!("unsharp=5:5:{:.2}:5:5:0", self.sharpness * 1.2));
        }
        if vig > 0.001 {
            f.push(format!("vignette=angle={:.3}", 0.25 + vig * 0.6));
        }
        f.join(",")
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn nessun_filtro_niente_da_fare() {
        assert!(Look::default().ffmpeg_filter("t").is_empty());
        assert!(Look { preset: "none".into(), amount: 1.0, ..Default::default() }.ffmpeg_filter("t").is_empty());
    }
    #[test]
    fn bianco_e_nero_toglie_il_colore() {
        let (a, _, _) = Look { preset: "mono".into(), amount: 1.0, ..Default::default() }.resolve();
        // Un rosso puro diventa grigio: i tre canali uguali
        let r: Vec<f64> = (0..3).map(|k| a.m[k][0] + a.o[k]).collect();
        assert!((r[0] - r[1]).abs() < 1e-9 && (r[1] - r[2]).abs() < 1e-9);
    }
    #[test]
    fn luminosita_sposta_tutto() {
        let l = Look { brightness: 1.0, ..Default::default() };
        let (a, _, _) = l.resolve();
        assert!((a.o[0] - 0.3).abs() < 1e-9);
        assert!(l.ffmpeg_filter("t").contains("lutrgb=r=val+76.50"));
    }
    #[test]
    fn composizione() {
        let a = tint(2.0, 1.0, 1.0).then(&brightness(0.1));
        assert!((a.m[0][0] - 2.0).abs() < 1e-9 && (a.o[0] - 0.1).abs() < 1e-9);
        let b = brightness(0.1).then(&tint(2.0, 1.0, 1.0));
        assert!((b.o[0] - 0.2).abs() < 1e-9);
    }
}
