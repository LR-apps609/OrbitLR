//! «Forme pulite»: dopo il ricalco, le forme che un grafico avrebbe disegnato pulite tornano pulite.
//!
//! - le linee quasi a 0°, 45°, 90°… diventano esatte, e gli angoli tra loro si ricalcolano come incroci veri;
//! - stelle e poligoni quasi regolari diventano regolari (stessi raggi, stessi angoli);
//! - linee orizzontali e verticali di forme diverse quasi allineate si allineano davvero; lo stesso per
//!   centri e raggi dei cerchi.
//!
//! Ogni cambiamento si accetta solo se nessun punto si sposta più di una piccola tolleranza: se il disegno
//! originale era davvero storto o irregolare, resta com'era.

use crate::extreme::Layer;
use crate::fit::{Seg, Shape, P};

/// `px`: un pixel dell'immagine in coordinate di lavoro.
pub fn clean(layers: &mut [Layer], px: f64) {
    for l in layers.iter_mut() {
        for s in l.shapes.iter_mut() {
            snap_angles(s, 0.3 * px);
            regular(s, 0.6 * px);
            regular_any(s, px);
        }
    }
    align(layers, 0.35 * px);
}

// ───────────────────────── poligoni

/// I vertici di un tracciato fatto solo di linee (chiuso: l'ultimo coincide con l'inizio).
fn polygon(s: &Shape) -> Option<Vec<P>> {
    let Shape::Path { start, segs } = s else { return None };
    if segs.len() < 3 {
        return None;
    }
    let mut v = Vec::with_capacity(segs.len());
    for g in segs {
        match g {
            Seg::Line(p) => v.push(*p),
            Seg::Cubic(..) => return None,
        }
    }
    let last = *v.last()?;
    if (last.x - start.x).abs() > 1e-6 || (last.y - start.y).abs() > 1e-6 {
        v.push(*start);
    }
    // v[i] = fine del lato i; il lato i va da v[i-1] a v[i]
    Some(v)
}

fn set_polygon(s: &mut Shape, v: &[P]) {
    if let Shape::Path { start, segs } = s {
        let n = v.len();
        *start = v[n - 1];
        *segs = v.iter().map(|p| Seg::Line(*p)).collect();
    }
}

fn dist(a: P, b: P) -> f64 {
    ((a.x - b.x).powi(2) + (a.y - b.y).powi(2)).sqrt()
}

/// Lati quasi a multipli di 15° (0°, 45°, 90° per primi): esatti; i vertici diventano gli incroci dei lati.
fn snap_angles(s: &mut Shape, tol: f64) {
    let Some(v) = polygon(s) else {
        snap_lines_in_path(s, tol);
        return;
    };
    let n = v.len();
    // ogni lato: punto medio e direzione (eventualmente esatta)
    let mut lines: Vec<(P, P)> = Vec::with_capacity(n);
    let mut changed = false;
    for i in 0..n {
        let (a, b) = (v[(i + n - 1) % n], v[i]);
        let m = P::new((a.x + b.x) / 2.0, (a.y + b.y) / 2.0);
        let len = dist(a, b);
        let ang = (b.y - a.y).atan2(b.x - a.x);
        let step = std::f64::consts::PI / 12.0; // 15°
        let q = (ang / step).round() * step;
        let k = ((q / step).round() as i64).rem_euclid(12);
        // 0°, 45°, 90° più facili; gli altri multipli di 15° solo se proprio vicini
        let lim = if k % 3 == 0 { 1.5f64 } else { 0.6 }.to_radians();
        let d = if len > 0.0 && (ang - q).abs() < lim && (ang - q).abs() * len / 2.0 < tol { q } else { ang };
        if d != ang {
            changed = true;
        }
        lines.push((m, P::new(d.cos(), d.sin())));
    }
    if !changed {
        return;
    }
    let mut nv = v.clone();
    for i in 0..n {
        let (m1, d1) = lines[i];
        let (m2, d2) = lines[(i + 1) % n];
        let cr = d1.x * d2.y - d1.y * d2.x;
        if cr.abs() < 0.17 {
            continue; // quasi paralleli: il vertice resta
        }
        let t = ((m2.x - m1.x) * d2.y - (m2.y - m1.y) * d2.x) / cr;
        nv[i] = P::new(m1.x + d1.x * t, m1.y + d1.y * t);
    }
    if v.iter().zip(&nv).all(|(a, b)| dist(*a, *b) <= tol) {
        set_polygon(s, &nv);
    }
}

/// Nei tracciati con curve: i lati quasi orizzontali o verticali diventano esatti (le curve accanto seguono).
fn snap_lines_in_path(_s: &mut Shape, _tol: f64) {
    // già fatto in `fit::snap_axes` durante il ricalco
}

/// Stelle e poligoni regolari: stesso centro, raggi uguali (alternati per le stelle), angoli uguali.
fn regular(s: &mut Shape, tol: f64) {
    let Some(v) = polygon(s) else { return };
    let n = v.len();
    if !(3..=40).contains(&n) {
        return;
    }
    let c = P::new(v.iter().map(|p| p.x).sum::<f64>() / n as f64, v.iter().map(|p| p.y).sum::<f64>() / n as f64);
    let r: Vec<f64> = v.iter().map(|p| dist(*p, c)).collect();
    let th: Vec<f64> = v.iter().map(|p| (p.y - c.y).atan2(p.x - c.x)).collect();
    let tau = std::f64::consts::TAU;
    // verso di percorrenza
    let mut turn = 0.0;
    for i in 0..n {
        let mut d = th[(i + 1) % n] - th[i];
        while d > std::f64::consts::PI {
            d -= tau;
        }
        while d < -std::f64::consts::PI {
            d += tau;
        }
        turn += d;
    }
    if (turn.abs() - tau).abs() > 0.5 {
        return; // non gira una volta intorno al centro
    }
    let dir = turn.signum();
    let step = dir * tau / n as f64;
    // angolo di partenza: media circolare
    let (mut sx, mut sy) = (0.0, 0.0);
    for i in 0..n {
        let a = th[i] - i as f64 * step;
        sx += a.cos();
        sy += a.sin();
    }
    let a0 = sy.atan2(sx);
    let mut best: Option<Vec<P>> = None;
    // poligono (un raggio) o stella (due raggi alternati)
    for groups in [1usize, 2] {
        if groups == 2 && (n % 2 != 0 || n < 6) {
            continue;
        }
        let mut rr = vec![0.0; groups];
        for g in 0..groups {
            let vals: Vec<f64> = (g..n).step_by(groups).map(|i| r[i]).collect();
            rr[g] = vals.iter().sum::<f64>() / vals.len() as f64;
        }
        if groups == 2 && (rr[0] - rr[1]).abs() < 0.15 * rr[0].max(rr[1]) {
            continue; // non è una stella
        }
        let nv: Vec<P> = (0..n).map(|i| {
            let a = a0 + i as f64 * step;
            let rad = rr[i % groups];
            P::new(c.x + rad * a.cos(), c.y + rad * a.sin())
        }).collect();
        let worst = v.iter().zip(&nv).map(|(a, b)| dist(*a, *b)).fold(0.0, f64::max);
        if std::env::var("VETTORE_DEBUG").is_ok() { eprintln!("regolare: n {n} gruppi {groups} raggi {rr:?} scarto {worst:.3} tol {tol:.3}"); }
        if worst <= tol.max(0.015 * rr.iter().cloned().fold(0.0, f64::max)).min(3.0 * tol) {
            best = Some(nv);
            break;
        }
    }
    if let Some(nv) = best {
        set_polygon(s, &nv);
    }
}

// ───────────────────────── stelle e poligoni anche dentro tracciati «sporchi»

/// Il contorno come tanti punti (le curve campionate).
fn flatten(s: &Shape) -> Vec<P> {
    match s {
        Shape::Circle { .. } => vec![],
        Shape::Path { start, segs } => {
            let mut out = vec![*start];
            let mut a = *start;
            for g in segs {
                match g {
                    Seg::Line(b) => {
                        out.push(*b);
                        a = *b;
                    }
                    Seg::Cubic(c1, c2, b) => {
                        for k in 1..=8 {
                            let t = k as f64 / 8.0;
                            let u = 1.0 - t;
                            out.push(P::new(
                                u * u * u * a.x + 3.0 * u * u * t * c1.x + 3.0 * u * t * t * c2.x + t * t * t * b.x,
                                u * u * u * a.y + 3.0 * u * u * t * c1.y + 3.0 * u * t * t * c2.y + t * t * t * b.y,
                            ));
                        }
                        a = *b;
                    }
                }
            }
            out
        }
    }
}

fn seg_dist(p: P, a: P, b: P) -> f64 {
    let (dx, dy) = (b.x - a.x, b.y - a.y);
    let l2 = dx * dx + dy * dy;
    let t = if l2 > 0.0 { (((p.x - a.x) * dx + (p.y - a.y) * dy) / l2).clamp(0.0, 1.0) } else { 0.0 };
    dist(p, P::new(a.x + t * dx, a.y + t * dy))
}

fn dp(p: &[P], eps: f64, out: &mut Vec<P>) {
    if p.len() < 3 {
        return;
    }
    let (a, b) = (p[0], p[p.len() - 1]);
    let (mut best, mut bi) = (0.0, 0);
    for (i, q) in p.iter().enumerate().take(p.len() - 1).skip(1) {
        let d = seg_dist(*q, a, b);
        if d > best {
            best = d;
            bi = i;
        }
    }
    if best > eps {
        dp(&p[..=bi], eps, out);
        out.push(p[bi]);
        dp(&p[bi..], eps, out);
    }
}

/// Douglas–Peucker su un contorno chiuso: i vertici veri.
fn simplify_closed(p: &[P], eps: f64) -> Vec<P> {
    let n = p.len();
    if n < 4 {
        return p.to_vec();
    }
    let c = P::new(p.iter().map(|q| q.x).sum::<f64>() / n as f64, p.iter().map(|q| q.y).sum::<f64>() / n as f64);
    let i0 = (0..n).max_by(|a, b| dist(p[*a], c).partial_cmp(&dist(p[*b], c)).unwrap()).unwrap();
    let i1 = (0..n).max_by(|a, b| dist(p[*a], p[i0]).partial_cmp(&dist(p[*b], p[i0])).unwrap()).unwrap();
    let (a, b) = (i0.min(i1), i0.max(i1));
    let first: Vec<P> = p[a..=b].to_vec();
    let second: Vec<P> = p[b..].iter().chain(p[..=a].iter()).copied().collect();
    let mut out = vec![p[a]];
    dp(&first, eps, &mut out);
    out.push(p[b]);
    dp(&second, eps, &mut out);
    out
}

/// Distanza massima tra due contorni (in tutti e due i versi).
fn hausdorff(pts: &[P], poly: &[P]) -> f64 {
    let n = poly.len();
    let d1 = pts.iter().map(|q| (0..n).map(|i| seg_dist(*q, poly[i], poly[(i + 1) % n])).fold(f64::MAX, f64::min)).fold(0.0, f64::max);
    let m = pts.len();
    let d2 = poly.iter().map(|q| (0..m).map(|i| seg_dist(*q, pts[i], pts[(i + 1) % m])).fold(f64::MAX, f64::min)).fold(0.0, f64::max);
    d1.max(d2)
}

/// Una forma che è quasi una stella o un poligono regolare (anche se il ricalco l'ha spezzata in tanti
/// pezzi e curvette) diventa quella figura esatta, se il contorno vero non si sposta più di poco.
fn regular_any(s: &mut Shape, px: f64) {
    let pts = flatten(s);
    if pts.len() < 8 {
        return;
    }
    let simp = simplify_closed(&pts, 1.2 * px);
    let n = simp.len();
    // solo stelle e poligoni da 5 lati in su (triangoli e quadrati: troppo facile scambiarli per altro)
    if !(5..=24).contains(&n) {
        return;
    }
    let mut cand = Shape::Path { start: simp[n - 1], segs: simp.iter().map(|p| Seg::Line(*p)).collect() };
    let before = polygon(&cand).unwrap();
    regular(&mut cand, 3.0 * px);
    let after = polygon(&cand).unwrap();
    if after == before {
        return;
    }
    let r = after.iter().map(|q| dist(*q, P::new(after.iter().map(|p| p.x).sum::<f64>() / n as f64, after.iter().map(|p| p.y).sum::<f64>() / n as f64))).fold(0.0, f64::max);
    let h = hausdorff(&pts, &after);
    let lim = (0.8 * px).max(0.02 * r).min(1.6 * px);
    if std::env::var("VETTORE_DEBUG").is_ok() {
        eprintln!("forma regolare: {n} vertici, scarto {:.2} px (limite {:.2})", h / px, lim / px);
    }
    if h <= lim {
        *s = cand;
    }
}

// ───────────────────────── allineamenti tra forme

/// Raggruppa valori vicini (entro `tol`) e dà a ognuno la media del suo gruppo.
fn cluster(vals: &[f64], tol: f64) -> Vec<f64> {
    let mut idx: Vec<usize> = (0..vals.len()).collect();
    idx.sort_by(|a, b| vals[*a].partial_cmp(&vals[*b]).unwrap_or(std::cmp::Ordering::Equal));
    let mut out = vals.to_vec();
    let mut i = 0;
    while i < idx.len() {
        let mut j = i + 1;
        while j < idx.len() && vals[idx[j]] - vals[idx[i]] <= tol {
            j += 1;
        }
        if j - i > 1 {
            let m = idx[i..j].iter().map(|k| vals[*k]).sum::<f64>() / (j - i) as f64;
            for k in &idx[i..j] {
                out[*k] = m;
            }
        }
        i = j;
    }
    out
}

/// Lati orizzontali e verticali quasi allineati (anche tra forme diverse) si allineano; centri e raggi dei
/// cerchi quasi uguali diventano uguali.
fn align(layers: &mut [Layer], tol: f64) {
    // (strato, forma, lato, orizzontale?) e il valore (y per gli orizzontali, x per i verticali)
    let mut keys: Vec<(usize, usize, usize, bool)> = vec![];
    let mut vals: Vec<f64> = vec![];
    for (li, l) in layers.iter().enumerate() {
        for (si, s) in l.shapes.iter().enumerate() {
            let Shape::Path { start, segs } = s else { continue };
            for (gi, g) in segs.iter().enumerate() {
                let a = if gi == 0 { *start } else { crate::fit::seg_end(&segs[gi - 1]) };
                if let Seg::Line(b) = g {
                    if (a.y - b.y).abs() < 1e-9 && (a.x - b.x).abs() > 3.0 * tol {
                        keys.push((li, si, gi, true));
                        vals.push(a.y);
                    } else if (a.x - b.x).abs() < 1e-9 && (a.y - b.y).abs() > 3.0 * tol {
                        keys.push((li, si, gi, false));
                        vals.push(a.x);
                    }
                }
            }
        }
    }
    // orizzontali e verticali separati
    for horiz in [true, false] {
        let sel: Vec<usize> = (0..keys.len()).filter(|i| keys[*i].3 == horiz).collect();
        let v: Vec<f64> = sel.iter().map(|i| vals[*i]).collect();
        let nv = cluster(&v, tol);
        for (k, i) in sel.iter().enumerate() {
            if (nv[k] - v[k]).abs() < 1e-12 {
                continue;
            }
            let (li, si, gi, h) = keys[*i];
            if let Shape::Path { start, segs } = &mut layers[li].shapes[si] {
                let n = segs.len();
                let set = |p: &mut P| if h { p.y = nv[k] } else { p.x = nv[k] };
                // la fine di questo lato e la fine del precedente (= il suo inizio)
                move_end(segs, gi, &set);
                if gi == 0 {
                    set(start);
                    move_end(segs, n - 1, &set);
                } else {
                    move_end(segs, gi - 1, &set);
                    if gi - 1 == n - 1 {
                        set(start);
                    }
                }
                if gi == n - 1 {
                    set(start);
                }
            }
        }
    }
    // cerchi
    let mut circ: Vec<(usize, usize)> = vec![];
    let (mut cx, mut cy, mut cr) = (vec![], vec![], vec![]);
    for (li, l) in layers.iter().enumerate() {
        for (si, s) in l.shapes.iter().enumerate() {
            if let Shape::Circle { cx: x, cy: y, r } = s {
                circ.push((li, si));
                cx.push(*x);
                cy.push(*y);
                cr.push(*r);
            }
        }
    }
    if circ.len() >= 2 {
        let (nx, ny, nr) = (cluster(&cx, tol), cluster(&cy, tol), cluster(&cr, tol));
        for (k, (li, si)) in circ.iter().enumerate() {
            layers[*li].shapes[*si] = Shape::Circle { cx: nx[k], cy: ny[k], r: nr[k] };
        }
    }
}

fn move_end(segs: &mut [Seg], i: usize, set: &dyn Fn(&mut P)) {
    match &mut segs[i] {
        Seg::Line(p) => set(p),
        Seg::Cubic(_, c2, p) => {
            let old = *p;
            set(p);
            c2.x += p.x - old.x;
            c2.y += p.y - old.y;
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::extreme::Fill;

    fn star(cx: f64, cy: f64, ro: f64, ri: f64, jitter: f64) -> Shape {
        let mut v = vec![];
        for i in 0..10 {
            let a = -std::f64::consts::FRAC_PI_2 + i as f64 * std::f64::consts::TAU / 10.0;
            let r = if i % 2 == 0 { ro } else { ri };
            let j = if i % 3 == 0 { jitter } else { -jitter * 0.7 };
            v.push(P::new(cx + (r + j) * a.cos(), cy + (r - j) * a.sin()));
        }
        Shape::Path { start: v[9], segs: v.iter().map(|p| Seg::Line(*p)).collect() }
    }

    #[test]
    fn stella_regolare() {
        let mut l = vec![Layer { fill: Fill::Flat([1.0, 0.0, 0.0]), shapes: vec![star(100.0, 100.0, 80.0, 32.0, 0.6)], rect: false }];
        clean(&mut l, 1.0);
        let v = polygon(&l[0].shapes[0]).unwrap();
        let c = P::new(v.iter().map(|p| p.x).sum::<f64>() / v.len() as f64, v.iter().map(|p| p.y).sum::<f64>() / v.len() as f64);
        let ro: Vec<f64> = v.iter().step_by(2).map(|p| dist(*p, c)).collect();
        let spread = ro.iter().cloned().fold(0.0, f64::max) - ro.iter().cloned().fold(f64::MAX, f64::min);
        assert!(spread < 0.05, "punte non regolari: {ro:?}");
    }

    #[test]
    fn stella_storta_resta() {
        // irregolare davvero: non si tocca
        let s = star(100.0, 100.0, 80.0, 32.0, 6.0);
        let mut l = vec![Layer { fill: Fill::Flat([1.0, 0.0, 0.0]), shapes: vec![s.clone()], rect: false }];
        clean(&mut l, 1.0);
        assert_eq!(polygon(&l[0].shapes[0]).unwrap(), polygon(&s).unwrap());
    }

    #[test]
    fn rettangoli_allineati() {
        let rect = |x0: f64, y0: f64, x1: f64, y1: f64| Shape::Path { start: P::new(x0, y0), segs: vec![Seg::Line(P::new(x1, y0)), Seg::Line(P::new(x1, y1)), Seg::Line(P::new(x0, y1)), Seg::Line(P::new(x0, y0))] };
        let mut l = vec![
            Layer { fill: Fill::Flat([0.0; 3]), shapes: vec![rect(10.0, 10.0, 50.0, 40.0)], rect: false },
            Layer { fill: Fill::Flat([1.0; 3]), shapes: vec![rect(60.0, 10.2, 90.0, 39.8)], rect: false },
        ];
        clean(&mut l, 1.0);
        let a = polygon(&l[0].shapes[0]).unwrap();
        let b = polygon(&l[1].shapes[0]).unwrap();
        assert!((a[0].y - b[0].y).abs() < 1e-9 && (a[2].y - b[2].y).abs() < 1e-9, "{a:?} {b:?}");
    }
}
