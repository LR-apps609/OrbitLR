//! Dal contorno (punti in pixel) alle curve: angoli netti, segmenti dritti, cerchi veri e Bézier cubiche.
//! Il contorno viene prima ammorbidito (via la scalettatura dei pixel), poi diviso negli angoli; ogni tratto
//! diventa una linea se è dritto, altrimenti una o più Bézier (metodo di Schneider, con riparametrizzazione).

#[derive(Clone, Copy, Debug, PartialEq)]
pub struct P {
    pub x: f64,
    pub y: f64,
}

impl FitOpts {
    /// Lunghezza minima (in punti del contorno) di un pezzo dritto
    fn min_line(&self) -> usize {
        ((self.corner_win as f64) * 12.0) as usize
    }
}

impl P {
    pub fn new(x: f64, y: f64) -> P {
        P { x, y }
    }
    fn sub(self, o: P) -> P {
        P::new(self.x - o.x, self.y - o.y)
    }
    fn add(self, o: P) -> P {
        P::new(self.x + o.x, self.y + o.y)
    }
    fn mul(self, k: f64) -> P {
        P::new(self.x * k, self.y * k)
    }
    fn dot(self, o: P) -> f64 {
        self.x * o.x + self.y * o.y
    }
    fn len(self) -> f64 {
        self.x.hypot(self.y)
    }
    fn unit(self) -> P {
        let l = self.len();
        if l > 1e-12 {
            self.mul(1.0 / l)
        } else {
            self
        }
    }
}

#[derive(Clone, Debug)]
pub enum Seg {
    Line(P),
    Cubic(P, P, P),
}

#[derive(Clone, Debug)]
pub enum Shape {
    Circle { cx: f64, cy: f64, r: f64 },
    Path { start: P, segs: Vec<Seg> },
}

/// Impostazioni del disegno delle curve, in pixel dell'immagine di lavoro.
#[derive(Clone, Copy, Debug)]
pub struct FitOpts {
    /// Quanto ammorbidire il contorno (sigma della gaussiana, in punti)
    pub sigma: f64,
    /// Distanza massima tra curva e contorno
    pub tol: f64,
    /// Finestra per riconoscere gli angoli (punti prima e dopo)
    pub corner_win: usize,
    /// Angolo minimo (gradi) per considerare un punto un angolo
    pub corner_deg: f64,
}

fn smooth_closed(p: &[P], sigma: f64) -> Vec<P> {
    let n = p.len();
    if sigma <= 0.0 || n < 3 {
        return p.to_vec();
    }
    let r = (3.0 * sigma) as isize + 1;
    if (n as isize) <= 2 * r {
        return p.to_vec();
    }
    let k: Vec<f64> = (-r..=r).map(|i| (-0.5 * (i as f64 / sigma).powi(2)).exp()).collect();
    let s: f64 = k.iter().sum();
    (0..n as isize)
        .map(|i| {
            let mut acc = P::new(0.0, 0.0);
            for (j, w) in (-r..=r).zip(&k) {
                let q = p[((i + j).rem_euclid(n as isize)) as usize];
                acc = acc.add(q.mul(*w));
            }
            acc.mul(1.0 / s)
        })
        .collect()
}

/// Gli angoli: dove la direzione in entrata e in uscita (su `win` punti) cambia più di `deg` gradi.
fn corners(p: &[P], win: usize, deg: f64) -> Vec<usize> {
    let n = p.len();
    if n < 2 * win + 3 {
        return vec![];
    }
    let ang: Vec<f64> = (0..n)
        .map(|i| {
            let a = p[(i + n - win) % n];
            let b = p[(i + win) % n];
            let v1 = p[i].sub(a);
            let v2 = b.sub(p[i]);
            let c = v1.dot(v2) / (v1.len() * v2.len() + 1e-12);
            c.clamp(-1.0, 1.0).acos().to_degrees()
        })
        .collect();
    let mut out: Vec<usize> = vec![];
    // dal più acuto: ogni angolo «occupa» la sua finestra
    let mut idx: Vec<usize> = (0..n).filter(|&i| ang[i] >= deg).collect();
    idx.sort_by(|&a, &b| ang[b].partial_cmp(&ang[a]).unwrap());
    for i in idx {
        let near = out.iter().any(|&o| {
            let d = if i > o { i - o } else { o - i };
            d.min(n - d) < win
        });
        if !near {
            out.push(i);
        }
    }
    out.sort();
    out
}

/// Cerchio ai minimi quadrati: centro, raggio, errore massimo.
fn fit_circle(p: &[P]) -> (f64, f64, f64, f64) {
    // sistema normale 3×3 per x² + y² = 2ax + 2by + c
    let mut m = [[0.0f64; 3]; 3];
    let mut v = [0.0f64; 3];
    for q in p {
        let row = [2.0 * q.x, 2.0 * q.y, 1.0];
        let b = q.x * q.x + q.y * q.y;
        for i in 0..3 {
            for j in 0..3 {
                m[i][j] += row[i] * row[j];
            }
            v[i] += row[i] * b;
        }
    }
    let s = solve3(m, v).unwrap_or([0.0, 0.0, 0.0]);
    let (cx, cy) = (s[0], s[1]);
    let r = (s[2] + cx * cx + cy * cy).max(0.0).sqrt();
    let e = p.iter().map(|q| ((q.x - cx).hypot(q.y - cy) - r).abs()).fold(0.0, f64::max);
    (cx, cy, r, e)
}

fn solve3(mut a: [[f64; 3]; 3], mut b: [f64; 3]) -> Option<[f64; 3]> {
    for c in 0..3 {
        let piv = (c..3).max_by(|&i, &j| a[i][c].abs().partial_cmp(&a[j][c].abs()).unwrap())?;
        if a[piv][c].abs() < 1e-12 {
            return None;
        }
        a.swap(c, piv);
        b.swap(c, piv);
        for r in 0..3 {
            if r != c {
                let f = a[r][c] / a[c][c];
                for k in 0..3 {
                    a[r][k] -= f * a[c][k];
                }
                b[r] -= f * b[c];
            }
        }
    }
    Some([b[0] / a[0][0], b[1] / a[1][1], b[2] / a[2][2]])
}

pub fn polygon_area(p: &[P]) -> f64 {
    let n = p.len();
    (0..n).map(|i| p[i].x * p[(i + 1) % n].y - p[(i + 1) % n].x * p[i].y).sum::<f64>() / 2.0
}

fn line_err(p: &[P]) -> f64 {
    let a = p[0];
    let d = p[p.len() - 1].sub(a);
    let l = d.len();
    if l < 1e-9 {
        return p.iter().map(|q| q.sub(a).len()).fold(0.0, f64::max);
    }
    p.iter().map(|q| (d.x * (q.y - a.y) - d.y * (q.x - a.x)).abs()).fold(0.0, f64::max) / l
}

/// Dritto davvero: vicino alla corda E senza «pancia» (un arco largo ha il centro spostato da un lato).
fn is_straight(p: &[P], lt: f64) -> bool {
    if line_err(p) > lt {
        return false;
    }
    let a = p[0];
    let d = p[p.len() - 1].sub(a);
    let l = d.len();
    if l < 1e-9 {
        return false;
    }
    let n = p.len();
    let mid = &p[n / 3..(2 * n / 3).max(n / 3 + 1)];
    let m: f64 = mid.iter().map(|q| (d.x * (q.y - a.y) - d.y * (q.x - a.x)) / l).sum::<f64>() / mid.len() as f64;
    m.abs() <= 0.3 * lt
}

fn bez(c: &[P; 4], t: f64) -> P {
    let mt = 1.0 - t;
    c[0].mul(mt * mt * mt).add(c[1].mul(3.0 * mt * mt * t)).add(c[2].mul(3.0 * mt * t * t)).add(c[3].mul(t * t * t))
}

fn chord(p: &[P]) -> Vec<f64> {
    let mut d = vec![0.0; p.len()];
    for i in 1..p.len() {
        d[i] = d[i - 1] + p[i].sub(p[i - 1]).len();
    }
    let tot = d[p.len() - 1];
    if tot > 0.0 {
        d.iter().map(|v| v / tot).collect()
    } else {
        (0..p.len()).map(|i| i as f64 / (p.len() - 1).max(1) as f64).collect()
    }
}

/// Una cubica con tangenti date agli estremi; ritorna controlli, errore massimo e dove.
fn fit_cubic(p: &[P], t1: P, t2: P) -> ([P; 4], f64, usize) {
    let mut u = chord(p);
    let (p0, p3) = (p[0], p[p.len() - 1]);
    let seg = p3.sub(p0).len();
    let mut ctrl = [p0, p0.add(t1.mul(seg / 3.0)), p3.add(t2.mul(seg / 3.0)), p3];
    for _ in 0..4 {
        let (mut c00, mut c01, mut c11, mut x0, mut x1) = (0.0, 0.0, 0.0, 0.0, 0.0);
        for (q, &t) in p.iter().zip(&u) {
            let mt = 1.0 - t;
            let (b0, b1, b2, b3) = (mt * mt * mt, 3.0 * t * mt * mt, 3.0 * t * t * mt, t * t * t);
            let a1 = t1.mul(b1);
            let a2 = t2.mul(b2);
            c00 += a1.dot(a1);
            c01 += a1.dot(a2);
            c11 += a2.dot(a2);
            let tmp = q.sub(p0.mul(b0 + b1)).sub(p3.mul(b2 + b3));
            x0 += a1.dot(tmp);
            x1 += a2.dot(tmp);
        }
        let det = c00 * c11 - c01 * c01;
        let (mut a1, mut a2) = if det.abs() > 1e-12 { ((x0 * c11 - x1 * c01) / det, (c00 * x1 - c01 * x0) / det) } else { (seg / 3.0, seg / 3.0) };
        if a1 < 1e-6 * seg || a2 < 1e-6 * seg {
            a1 = seg / 3.0;
            a2 = seg / 3.0;
        }
        ctrl = [p0, p0.add(t1.mul(a1)), p3.add(t2.mul(a2)), p3];
        // Newton: avvicina i parametri ai punti
        for (i, q) in p.iter().enumerate() {
            if i == 0 || i == p.len() - 1 {
                continue;
            }
            let t = u[i];
            let mt = 1.0 - t;
            let b = bez(&ctrl, t);
            let d1 = ctrl[1].sub(ctrl[0]).mul(3.0 * mt * mt).add(ctrl[2].sub(ctrl[1]).mul(6.0 * mt * t)).add(ctrl[3].sub(ctrl[2]).mul(3.0 * t * t));
            let d2 = ctrl[2].sub(ctrl[1].mul(2.0)).add(ctrl[0]).mul(6.0 * mt).add(ctrl[3].sub(ctrl[2].mul(2.0)).add(ctrl[1]).mul(6.0 * t));
            let diff = b.sub(*q);
            let den = d1.dot(d1) + diff.dot(d2);
            if den.abs() > 1e-12 {
                u[i] = (t - diff.dot(d1) / den).clamp(0.0, 1.0);
            }
        }
    }
    let mut worst = (0.0, 0);
    for (i, q) in p.iter().enumerate() {
        let e = bez(&ctrl, u[i]).sub(*q).len();
        if e > worst.0 {
            worst = (e, i);
        }
    }
    (ctrl, worst.0, worst.1)
}

fn fit_open(p: &[P], tol: f64, t1: Option<P>, t2: Option<P>, depth: u32, out: &mut Vec<Seg>) {
    let n = p.len();
    if n < 3 || line_err(p) <= tol {
        out.push(Seg::Line(p[n - 1]));
        return;
    }
    let k = (n / 10).max(2).min(n - 1);
    let t1 = t1.unwrap_or_else(|| p[k].sub(p[0]).unit());
    let t2 = t2.unwrap_or_else(|| p[n - 1 - k].sub(p[n - 1]).unit());
    let (c, e, i) = fit_cubic(p, t1, t2);
    if e <= tol || depth > 12 || n < 8 {
        out.push(Seg::Cubic(c[1], c[2], c[3]));
        return;
    }
    let i = i.clamp(3, n - 4);
    let tm = p[(i + k).min(n - 1)].sub(p[i.saturating_sub(k)]).unit();
    fit_open(&p[..=i], tol, Some(t1), Some(tm.mul(-1.0)), depth + 1, out);
    fit_open(&p[i..], tol, Some(tm), Some(t2), depth + 1, out);
}


/// Un tratto tra due angoli: prima si cercano i pezzi dritti lunghi (diventano linee vere), poi le curve
/// tra un pezzo dritto e l'altro, tangenti alle linee (raccordi morbidi, come negli angoli arrotondati).
fn fit_piece(p: &[P], tol: f64, min_line: usize, t_in: Option<P>, t_out: Option<P>, out: &mut Vec<Seg>) {
    let n = p.len();
    let lt = tol * 0.6;
    let mut runs: Vec<(usize, usize)> = vec![];
    let mut i = 0;
    while i + min_line < n {
        let mut j = i + min_line;
        if is_straight(&p[i..=j], lt) {
            // si allunga finché resta dritto sia tutto sia l'ultimo tratto (così non «mangia» l'inizio di una curva)
            while j + 1 < n && is_straight(&p[i..=j + 1], lt) && is_straight(&p[j + 1 - min_line..=j + 1], lt) {
                j += 1;
            }
            runs.push((i, j));
            i = j;
        } else {
            i += 1;
        }
    }
    if runs.is_empty() {
        fit_open(p, tol, t_in, t_out, 0, out);
        return;
    }
    // un pezzo dritto che arriva quasi all'angolo ci arriva davvero (niente trattini vicino agli angoli)
    let near = (min_line / 6).max(3);
    if runs[0].0 <= near && t_in.is_none() {
        runs[0].0 = 0;
    }
    let last = runs.len() - 1;
    if runs[last].1 + near >= n - 1 && t_out.is_none() {
        runs[last].1 = n - 1;
    }
    let mut cur = 0;
    let mut tin = t_in;
    for (a, b) in runs {
        let dir = p[b].sub(p[a]).unit();
        if a > cur {
            fit_open(&p[cur..=a], tol, tin, Some(dir.mul(-1.0)), 0, out);
        }
        out.push(Seg::Line(p[b]));
        cur = b;
        tin = Some(dir);
    }
    if cur < n - 1 {
        fit_open(&p[cur..], tol, tin, t_out, 0, out);
    }
}

/// Linee quasi orizzontali o verticali: dritte davvero (entro mezzo grado e `tol` di spostamento).
fn snap_axes(start: &mut P, segs: &mut [Seg], tol: f64) {
    let n = segs.len();
    for i in 0..n {
        let a = if i == 0 { *start } else { end_of(&segs[i - 1]) };
        if let Seg::Line(b) = segs[i] {
            let d = b.sub(a);
            if d.len() < 4.0 * tol {
                continue;
            }
            let horiz = d.y.abs() <= d.x.abs() * 0.035 && d.y.abs() <= tol;
            let vert = d.x.abs() <= d.y.abs() * 0.035 && d.x.abs() <= tol;
            if !(horiz || vert) {
                continue;
            }
            let mut nb = b;
            let mut na = a;
            if horiz {
                let y = (a.y + b.y) / 2.0;
                nb.y = y;
                na.y = y;
            } else {
                let x = (a.x + b.x) / 2.0;
                nb.x = x;
                na.x = x;
            }
            set_end(&mut segs[i], nb);
            if i == 0 {
                *start = na;
            } else {
                set_end(&mut segs[i - 1], na);
            }
            if i == n - 1 {
                *start = nb;
            }
        }
    }
}

pub fn seg_end(s: &Seg) -> P {
    end_of(s)
}

pub fn circle_of(p: &[P]) -> (f64, f64, f64, f64) {
    fit_circle(p)
}

/// La retta migliore (punto medio, direzione) per dei punti.
pub fn line_of(p: &[P]) -> (P, P) {
    let n = p.len() as f64;
    let (mx, my) = (p.iter().map(|q| q.x).sum::<f64>() / n, p.iter().map(|q| q.y).sum::<f64>() / n);
    let (mut sxx, mut sxy, mut syy) = (0.0, 0.0, 0.0);
    for q in p {
        let (dx, dy) = (q.x - mx, q.y - my);
        sxx += dx * dx;
        sxy += dx * dy;
        syy += dy * dy;
    }
    let th = 0.5 * (2.0 * sxy).atan2(sxx - syy);
    (P::new(mx, my), P::new(th.cos(), th.sin()))
}

fn end_of(s: &Seg) -> P {
    match s {
        Seg::Line(p) => *p,
        Seg::Cubic(_, _, p) => *p,
    }
}
fn set_end(s: &mut Seg, v: P) {
    match s {
        Seg::Line(p) => *p = v,
        Seg::Cubic(_, c2, p) => {
            let d = v.sub(*p);
            *c2 = c2.add(d);
            *p = v;
        }
    }
}

/// Un contorno chiuso → una forma (cerchio vero, o tracciato di linee e curve).
pub fn fit_contour(raw: &[P], o: &FitOpts) -> Option<Shape> {
    if raw.len() < 8 {
        return None;
    }
    let p = smooth_closed(raw, o.sigma);
    // Un cerchio intero?
    let (cx, cy, r, e) = fit_circle(&p);
    let area = polygon_area(&p).abs();
    let ca = std::f64::consts::PI * r * r;
    if r > 2.5 * o.sigma.max(1.0) && e < (o.tol * 1.2).max(r * 0.02) && (area - ca).abs() < 0.04 * ca {
        return Some(Shape::Circle { cx, cy, r });
    }
    // Gli angoli si cercano dove sono ancora netti (poco ammorbidito)
    let pc = smooth_closed(raw, o.sigma * 0.5);
    let k = corners(&pc, o.corner_win, o.corner_deg);
    let mut segs = vec![];
    let mut start;
    if k.is_empty() {
        // si parte da un pezzo dritto, se c'è (così non viene spezzato in due)
        let ml = o.min_line();
        let lt = o.tol * 0.6;
        let mut off = 0;
        for i in 0..p.len() {
            let idx: Vec<P> = (0..=ml).map(|k| p[(i + k) % p.len()]).collect();
            if is_straight(&idx, lt) {
                off = i;
                break;
            }
        }
        let q: Vec<P> = (0..=p.len()).map(|k| p[(off + k) % p.len()]).collect();
        start = q[0];
        let t = q[1].sub(q[q.len() - 2]).unit();
        fit_piece(&q, o.tol, ml, Some(t), Some(t.mul(-1.0)), &mut segs);
    } else {
        // il vertice dell'angolo dal contorno poco ammorbidito: resta appuntito
        start = pc[k[0]];
        for j in 0..k.len() {
            let (a, b) = (k[j], k[(j + 1) % k.len()]);
            let mut s: Vec<P> = if b > a { p[a..=b].to_vec() } else { p[a..].iter().chain(p[..=b].iter()).copied().collect() };
            let last = s.len() - 1;
            s[0] = pc[a];
            s[last] = pc[b];
            fit_piece(&s, o.tol, o.min_line(), None, None, &mut segs);
        }
    }
    snap_axes(&mut start, &mut segs, o.tol);
    Some(Shape::Path { start, segs })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn opts() -> FitOpts {
        FitOpts { sigma: 2.0, tol: 2.0, corner_win: 6, corner_deg: 50.0 }
    }

    #[test]
    fn cerchio_vero() {
        let pts: Vec<P> = (0..400).map(|i| {
            let a = i as f64 / 400.0 * std::f64::consts::TAU;
            P::new((100.0 + 60.0 * a.cos()).round(), (80.0 + 60.0 * a.sin()).round())
        }).collect();
        match fit_contour(&pts, &opts()).unwrap() {
            Shape::Circle { cx, cy, r } => assert!((cx - 100.0).abs() < 1.0 && (cy - 80.0).abs() < 1.0 && (r - 60.0).abs() < 1.5),
            s => panic!("non è un cerchio: {s:?}"),
        }
    }

    #[test]
    fn quadrato_con_angoli_netti() {
        let mut pts = vec![];
        for i in 0..100 { pts.push(P::new(i as f64, 0.0)); }
        for i in 0..100 { pts.push(P::new(100.0, i as f64)); }
        for i in 0..100 { pts.push(P::new(100.0 - i as f64, 100.0)); }
        for i in 0..100 { pts.push(P::new(0.0, 100.0 - i as f64)); }
        match fit_contour(&pts, &opts()).unwrap() {
            Shape::Path { segs, .. } => {
                assert_eq!(segs.len(), 4, "{segs:?}");
                assert!(segs.iter().all(|s| matches!(s, Seg::Line(_))));
            }
            s => panic!("{s:?}"),
        }
    }
}

#[cfg(test)]
mod prova_angolo {
    use super::*;
    #[test]
    fn angolo_arrotondato() {
        // quadrato 400 con angoli di raggio 160, campionato a pixel
        let mut pts = vec![];
        let (a, r) = (400.0f64, 160.0f64);
        let per = 2000;
        for i in 0..per {
            let t = i as f64 / per as f64 * 4.0;
            let side = t.floor() as i32;
            let f = t - t.floor();
            // percorso: lato dritto (a-2r) poi quarto di cerchio, in proporzione alla lunghezza
            let ls = a - 2.0 * r;
            let la = std::f64::consts::FRAC_PI_2 * r;
            let s = f * (ls + la);
            let (x, y) = if s < ls { (r + s, 0.0) } else { let th = (s - ls) / r - std::f64::consts::FRAC_PI_2; (a - r + r * th.cos(), r + r * th.sin()) };
            let (x, y) = match side { 0 => (x, y), 1 => (a - y, x), 2 => (a - x, a - y), _ => (y, a - x) };
            pts.push(P::new(x.round(), y.round()));
        }
        pts.dedup();
        let o = FitOpts { sigma: 2.4, tol: 2.4, corner_win: 6, corner_deg: 50.0 };
        match fit_contour(&pts, &o) {
            Some(Shape::Path { segs, .. }) => {
                // quattro lati dritti e quattro raccordi curvi, niente spezzettature
                assert_eq!(segs.iter().filter(|s| matches!(s, Seg::Line(_))).count(), 4, "{segs:?}");
                assert_eq!(segs.iter().filter(|s| matches!(s, Seg::Cubic(..))).count(), 4, "{segs:?}");
            }
            s => panic!("{s:?}"),
        }
    }
}

