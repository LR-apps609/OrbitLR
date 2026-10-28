//! «Pacchetto logo»: dallo stesso disegno vettoriale, tutti i file che servono a chi usa un logo.
//!
//! SVG (web e grafica), PDF ed EPS vettoriali (tipografie, Illustrator, Word, stampa su gadget), PNG trasparenti
//! in tre misure, la versione a un colore (nero e bianco: timbri, incisioni, fondi scuri) e, se l'immagine è
//! quasi quadrata, le icone per un sito. Tutto scritto qui dalle curve, senza programmi esterni: PDF ed EPS
//! restano vettoriali al 100%, anche con le sfumature.

use crate::extreme::{self, Fill, Layer};
use crate::fit::{FitOpts, Seg, Shape, P};
use image::RgbaImage;
use std::fmt::Write as _;

/// Il disegno finito: gli strati in coordinate di lavoro; `s` = pixel di lavoro per pixel dell'immagine.
#[derive(Clone, Debug)]
pub struct Art {
    pub w: u32,
    pub h: u32,
    pub s: f64,
    pub layers: Vec<Layer>,
}

/// Un file del pacchetto: percorso dentro lo ZIP e contenuto.
pub struct Item {
    pub path: String,
    pub data: Vec<u8>,
}

const KAPPA: f64 = 0.552_284_749_8;

/// Le curve di una forma come segmenti (i cerchi diventano quattro curve), in pixel dell'immagine.
fn segments(s: &Shape, k: f64) -> (P, Vec<Seg>) {
    let q = |p: P| P::new(p.x / k, p.y / k);
    match s {
        Shape::Circle { cx, cy, r } => {
            let (cx, cy, r) = (cx / k, cy / k, r / k);
            let c = KAPPA * r;
            let p = |x: f64, y: f64| P::new(x, y);
            (
                p(cx + r, cy),
                vec![
                    Seg::Cubic(p(cx + r, cy + c), p(cx + c, cy + r), p(cx, cy + r)),
                    Seg::Cubic(p(cx - c, cy + r), p(cx - r, cy + c), p(cx - r, cy)),
                    Seg::Cubic(p(cx - r, cy - c), p(cx - c, cy - r), p(cx, cy - r)),
                    Seg::Cubic(p(cx + c, cy - r), p(cx + r, cy - c), p(cx + r, cy)),
                ],
            )
        }
        Shape::Path { start, segs } => (
            q(*start),
            segs.iter()
                .map(|g| match g {
                    Seg::Line(p) => Seg::Line(q(*p)),
                    Seg::Cubic(a, b, p) => Seg::Cubic(q(*a), q(*b), q(*p)),
                })
                .collect(),
        ),
    }
}

fn num(v: f64) -> String {
    let s = format!("{v:.2}");
    let s = s.trim_end_matches('0').trim_end_matches('.').to_string();
    if s == "-0" || s.is_empty() {
        "0".into()
    } else {
        s
    }
}

fn c3(c: [f32; 3]) -> String {
    format!("{} {} {}", num(c[0].clamp(0.0, 1.0) as f64), num(c[1].clamp(0.0, 1.0) as f64), num(c[2].clamp(0.0, 1.0) as f64))
}

/// Il percorso in sintassi PDF/PostScript (y già capovolta dalla trasformazione della pagina).
fn path_ops(shapes: &[Shape], k: f64, ps: bool) -> String {
    let (m, l, c, h) = if ps { ("moveto", "lineto", "curveto", "closepath") } else { ("m", "l", "c", "h") };
    let mut o = String::new();
    for s in shapes {
        let (start, segs) = segments(s, k);
        let _ = writeln!(o, "{} {} {m}", num(start.x), num(start.y));
        for g in &segs {
            match g {
                Seg::Line(p) => {
                    let _ = writeln!(o, "{} {} {l}", num(p.x), num(p.y));
                }
                Seg::Cubic(a, b, p) => {
                    let _ = writeln!(o, "{} {} {} {} {} {} {c}", num(a.x), num(a.y), num(b.x), num(b.y), num(p.x), num(p.y));
                }
            }
        }
        let _ = writeln!(o, "{h}");
    }
    o
}

// ───────────────────────── PDF

pub fn pdf(a: &Art) -> Vec<u8> {
    let (w, h) = (a.w as f64, a.h as f64);
    let mut content = format!("1 0 0 -1 0 {} cm\n", num(h));
    let mut shadings = String::new();
    let mut objs: Vec<String> = vec![]; // dal 5 in poi: le sfumature
    for l in &a.layers {
        let body = if l.rect { format!("0 0 {} {} re\n", num(w), num(h)) } else { path_ops(&l.shapes, a.s, false) };
        let rule = if l.rect { "" } else { "*" };
        match &l.fill {
            Fill::Flat(col) => {
                let _ = write!(content, "{} rg\n{body}f{rule}\n", c3(*col));
            }
            Fill::Linear { p0, p1, c0, c1 } => {
                let id = objs.len();
                let n = 5 + id;
                objs.push(format!(
                    "<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [{} {} {} {}] /Function << /FunctionType 2 /Domain [0 1] /C0 [{}] /C1 [{}] /N 1 >> /Extend [true true] >>",
                    num(p0.x / a.s), num(p0.y / a.s), num(p1.x / a.s), num(p1.y / a.s), c3(*c0), c3(*c1)
                ));
                let _ = write!(shadings, "/Sh{id} {n} 0 R ");
                let _ = write!(content, "q\n{body}W{rule} n\n/Sh{id} sh\nQ\n");
            }
        }
    }
    let mut out: Vec<u8> = b"%PDF-1.4\n%\xE2\xE3\xCF\xD3\n".to_vec();
    let mut offs = vec![];
    let mut add = |out: &mut Vec<u8>, s: String| {
        offs.push(out.len());
        out.extend_from_slice(s.as_bytes());
    };
    add(&mut out, "1 0 obj\n<< /Type /Catalog /Pages 2 0 R >>\nendobj\n".into());
    add(&mut out, "2 0 obj\n<< /Type /Pages /Kids [3 0 R] /Count 1 >>\nendobj\n".into());
    add(&mut out, format!("3 0 obj\n<< /Type /Page /Parent 2 0 R /MediaBox [0 0 {} {}] /Resources << /Shading << {shadings}>> >> /Contents 4 0 R >>\nendobj\n", num(w), num(h)));
    add(&mut out, format!("4 0 obj\n<< /Length {} >>\nstream\n{content}endstream\nendobj\n", content.len()));
    for (i, o) in objs.iter().enumerate() {
        add(&mut out, format!("{} 0 obj\n{o}\nendobj\n", 5 + i));
    }
    let xref = out.len();
    let n = offs.len() + 1;
    let mut x = format!("xref\n0 {n}\n0000000000 65535 f \n");
    for o in &offs {
        let _ = write!(x, "{o:010} 00000 n \n");
    }
    let _ = write!(x, "trailer\n<< /Size {n} /Root 1 0 R >>\nstartxref\n{xref}\n%%EOF\n");
    out.extend_from_slice(x.as_bytes());
    out
}

// ───────────────────────── EPS

pub fn eps(a: &Art, title: &str) -> Vec<u8> {
    let (w, h) = (a.w as f64, a.h as f64);
    let title: String = title.chars().filter(|c| !c.is_control() && *c != '(' && *c != ')').collect();
    let mut o = format!(
        "%!PS-Adobe-3.0 EPSF-3.0\n%%BoundingBox: 0 0 {} {}\n%%HiResBoundingBox: 0 0 {} {}\n%%Title: ({title})\n%%Creator: OrbitLR\n%%LanguageLevel: 3\n%%Pages: 1\n%%EndComments\n%%Page: 1 1\ngsave\n0 {} translate 1 -1 scale\n",
        a.w, a.h, num(w), num(h), num(h)
    );
    for l in &a.layers {
        let body = if l.rect { format!("newpath 0 0 moveto {0} 0 lineto {0} {1} lineto 0 {1} lineto closepath\n", num(w), num(h)) } else { format!("newpath\n{}", path_ops(&l.shapes, a.s, true)) };
        let (fill, clip) = if l.rect { ("fill", "clip") } else { ("eofill", "eoclip") };
        match &l.fill {
            Fill::Flat(c) => {
                let _ = write!(o, "{} setrgbcolor\n{body}{fill}\n", c3(*c));
            }
            Fill::Linear { p0, p1, c0, c1 } => {
                let _ = write!(
                    o,
                    "gsave\n{body}{clip}\n<< /ShadingType 2 /ColorSpace /DeviceRGB /Coords [{} {} {} {}] /Function << /FunctionType 2 /Domain [0 1] /C0 [{}] /C1 [{}] /N 1 >> /Extend [true true] >> shfill\ngrestore\n",
                    num(p0.x / a.s), num(p0.y / a.s), num(p1.x / a.s), num(p1.y / a.s), c3(*c0), c3(*c1)
                );
            }
        }
    }
    o.push_str("grestore\nshowpage\n%%EOF\n");
    o.into_bytes()
}

// ───────────────────────── PNG

/// Il disegno a `size` pixel sul lato lungo, sfondo trasparente.
pub fn raster(a: &Art, size: u32) -> RgbaImage {
    let z = size as f64 / a.w.max(a.h) as f64;
    let (w, h) = (((a.w as f64 * z).round() as u32).max(1), ((a.h as f64 * z).round() as u32).max(1));
    let t = extreme::Target { w: w as usize, h: h as usize, px: vec![], bg: None };
    let px = extreme::render(&a.layers, z / a.s, &t);
    // premoltiplicato → normale
    RgbaImage::from_fn(w, h, |x, y| {
        let p = px[(y * w + x) as usize];
        let al = p[3];
        let d = |c: f32| if al > 0.0 { ((c / al).clamp(0.0, 1.0) * 255.0).round() as u8 } else { 0 };
        image::Rgba([d(p[0]), d(p[1]), d(p[2]), (al * 255.0).round() as u8])
    })
}

pub fn png(img: &RgbaImage) -> Vec<u8> {
    let mut v = std::io::Cursor::new(Vec::new());
    let _ = img.write_to(&mut v, image::ImageFormat::Png);
    v.into_inner()
}

// ───────────────────────── a un colore

/// La versione a un colore, come la fa un grafico: dal fuori verso il dentro le zone si alternano piene e
/// vuote (il fondo pieno, il cerchio sopra vuoto, la stella dentro di nuovo piena), così ogni forma resta
/// visibile anche con un colore solo. Poi tutto si ricalca come una forma sola con i buchi.
pub fn one_color(a: &Art) -> Art {
    let side = 2000u32;
    let z = side as f64 / a.w.max(a.h) as f64;
    let (w, h) = (((a.w as f64 * z).round() as usize).max(1), ((a.h as f64 * z).round() as usize).max(1));
    let t = extreme::Target { w, h, px: vec![], bg: None };
    // la forma più in alto in ogni pixel (-1: niente)
    let mut top = vec![-1i32; w * h];
    for (i, l) in a.layers.iter().enumerate() {
        let one = Layer { fill: Fill::Flat([1.0, 1.0, 1.0]), shapes: l.shapes.clone(), rect: l.rect };
        let px = extreme::render(std::slice::from_ref(&one), z / a.s, &t);
        for (j, p) in px.iter().enumerate() {
            if p[3] >= 0.5 {
                top[j] = i as i32;
            }
        }
    }
    let n = a.layers.len();
    // quante volte due zone si toccano (indice n = il fuori)
    let id = |v: i32| if v < 0 { n } else { v as usize };
    let mut touch = vec![vec![0u64; n + 1]; n + 1];
    let mut area = vec![0u64; n + 1];
    for y in 0..h {
        for x in 0..w {
            let c = id(top[y * w + x]);
            area[c] += 1;
            if x + 1 < w {
                let d = id(top[y * w + x + 1]);
                if d != c {
                    touch[c][d] += 1;
                    touch[d][c] += 1;
                }
            }
            if y + 1 < h {
                let d = id(top[(y + 1) * w + x]);
                if d != c {
                    touch[c][d] += 1;
                    touch[d][c] += 1;
                }
            }
            // il bordo dell'immagine tocca il fuori
            if x == 0 || y == 0 || x + 1 == w || y + 1 == h {
                touch[c][n] += 1;
                touch[n][c] += 1;
            }
        }
    }
    // le zone vicine di luce simile (pezzi della stessa sfumatura) diventano una zona sola
    let lum = |l: &Layer| {
        let c = match &l.fill {
            Fill::Flat(c) => *c,
            Fill::Linear { c0, c1, .. } => [(c0[0] + c1[0]) / 2.0, (c0[1] + c1[1]) / 2.0, (c0[2] + c1[2]) / 2.0],
        };
        255.0 * (0.299 * c[0] + 0.587 * c[1] + 0.114 * c[2])
    };
    let lums: Vec<f32> = a.layers.iter().map(lum).collect();
    let mut parent: Vec<usize> = (0..=n).collect();
    fn root(p: &mut Vec<usize>, mut i: usize) -> usize {
        while p[i] != i {
            p[i] = p[p[i]];
            i = p[i];
        }
        i
    }
    // (senza catene: si confronta con la luce media del gruppo, non con l'ultimo pezzo aggiunto)
    let mut gsum: Vec<(f32, f32)> = lums.iter().map(|l| (*l, 1.0)).collect();
    gsum.push((0.0, 0.0));
    for i in 0..n {
        for j in i + 1..n {
            if touch[i][j] == 0 {
                continue;
            }
            let (ri, rj) = (root(&mut parent, i), root(&mut parent, j));
            if ri == rj {
                continue;
            }
            let (mi, mj) = (gsum[ri].0 / gsum[ri].1, gsum[rj].0 / gsum[rj].1);
            if (mi - mj).abs() < 32.0 {
                parent[rj] = ri;
                gsum[ri] = (gsum[ri].0 + gsum[rj].0, gsum[ri].1 + gsum[rj].1);
            }
        }
    }
    let roots: Vec<usize> = (0..=n).map(|i| root(&mut parent, i)).collect();
    let mut t2 = vec![vec![0u64; n + 1]; n + 1];
    let mut a2 = vec![0u64; n + 1];
    for i in 0..=n {
        a2[roots[i]] += area[i];
        for j in 0..=n {
            if roots[i] != roots[j] {
                t2[roots[i]][roots[j]] += touch[i][j];
            }
        }
    }
    let (touch, area) = (t2, a2);
    // il punto di partenza è vuoto: il fuori, o (immagine senza trasparenza) la zona più grande sul bordo
    let start = if area[n] > 0 { n } else { roots[(0..n).max_by_key(|i| touch[roots[*i]][n]).unwrap_or(0)] };
    let mut ink: Vec<Option<bool>> = vec![None; n + 1];
    ink[start] = Some(false);
    if start != n {
        ink[n] = Some(false);
    }
    // in ampiezza: ogni zona prende il contrario di quelle che tocca di più tra le già decise
    loop {
        let mut best: Option<(usize, u64)> = None;
        for i in 0..=n {
            if ink[i].is_some() || area[i] == 0 {
                continue;
            }
            let t: u64 = (0..=n).filter(|j| ink[*j].is_some()).map(|j| touch[i][j]).sum();
            if t > 0 && best.map_or(true, |b| t > b.1) {
                best = Some((i, t));
            }
        }
        let Some((i, _)) = best else { break };
        let (mut full, mut empty) = (0u64, 0u64);
        for j in 0..=n {
            match ink[j] {
                Some(true) => full += touch[i][j],
                Some(false) => empty += touch[i][j],
                None => {}
            }
        }
        ink[i] = Some(empty >= full);
    }
    let mask: Vec<bool> = top.iter().map(|v| *v >= 0 && ink[roots[*v as usize]] == Some(true)).collect();
    let u = z.max(1.0);
    let fo = FitOpts { sigma: 0.6 * u, tol: 0.5 * u, corner_win: (1.5 * u).round().max(3.0) as usize, corner_deg: 50.0 };
    let shapes = crate::trace_mask(&mask, w, h, u, &fo, 0);
    Art { w: a.w, h: a.h, s: z, layers: vec![Layer { fill: Fill::Flat([0.0, 0.0, 0.0]), shapes, rect: false }] }
}

pub fn recolor(a: &Art, c: [f32; 3]) -> Art {
    let mut b = a.clone();
    for l in &mut b.layers {
        l.fill = Fill::Flat(c);
    }
    b
}

// ───────────────────────── icone

/// .ico con dentro PNG (Windows Vista e successivi, tutti i browser).
pub fn ico(imgs: &[RgbaImage]) -> Vec<u8> {
    let pngs: Vec<Vec<u8>> = imgs.iter().map(png).collect();
    let mut o = vec![0u8, 0, 1, 0, imgs.len() as u8, 0];
    let mut off = 6 + 16 * imgs.len();
    for (img, p) in imgs.iter().zip(&pngs) {
        let d = |v: u32| if v >= 256 { 0u8 } else { v as u8 };
        o.extend_from_slice(&[d(img.width()), d(img.height()), 0, 0, 1, 0, 32, 0]);
        o.extend_from_slice(&(p.len() as u32).to_le_bytes());
        o.extend_from_slice(&(off as u32).to_le_bytes());
        off += p.len();
    }
    for p in pngs {
        o.extend_from_slice(&p);
    }
    o
}

/// Il disegno al centro di un quadrato `size`×`size` (con un poco di margine), trasparente.
fn square(a: &Art, size: u32, margin: f64) -> RgbaImage {
    let inner = ((size as f64) * (1.0 - 2.0 * margin)).round().max(1.0) as u32;
    let img = raster(a, inner);
    let mut out = RgbaImage::new(size, size);
    let (ox, oy) = ((size - img.width().min(size)) / 2, (size - img.height().min(size)) / 2);
    image::imageops::overlay(&mut out, &img, ox as i64, oy as i64);
    out
}

// ───────────────────────── il pacchetto

/// Tutti i file. `svg` è l'SVG già scritto; `name` il nome del file originale senza estensione.
pub fn build(a: &Art, svg: &str, svg_of: &dyn Fn(&Art) -> String, name: &str, en: bool) -> Vec<Item> {
    let mut v = vec![];
    let it = |path: String, data: Vec<u8>| Item { path, data };
    v.push(it(format!("{name}.svg"), svg.as_bytes().to_vec()));
    v.push(it(format!("{name}.pdf"), pdf(a)));
    v.push(it(format!("{name}.eps"), eps(a, name)));
    for s in [512, 1024, 2048] {
        v.push(it(format!("PNG/{name}-{s}.png"), png(&raster(a, s))));
    }
    let one = one_color(a);
    let (black, white) = (recolor(&one, [0.0, 0.0, 0.0]), recolor(&one, [1.0, 1.0, 1.0]));
    let (dir1, nb, nw) = if en { ("One color", "black", "white") } else { ("Un colore", "nero", "bianco") };
    v.push(it(format!("{dir1}/{name}-{nb}.svg"), svg_of(&black).into_bytes()));
    v.push(it(format!("{dir1}/{name}-{nw}.svg"), svg_of(&white).into_bytes()));
    v.push(it(format!("{dir1}/{name}-{nb}.pdf"), pdf(&black)));
    v.push(it(format!("{dir1}/{name}-{nb}.eps"), eps(&black, name)));
    v.push(it(format!("{dir1}/{name}-{nb}-1024.png"), png(&raster(&black, 1024))));
    v.push(it(format!("{dir1}/{name}-{nw}-1024.png"), png(&raster(&white, 1024))));
    let ratio = a.w.max(a.h) as f64 / a.w.min(a.h).max(1) as f64;
    let fav = ratio <= 1.25;
    if fav {
        let icons: Vec<RgbaImage> = [16, 32, 48].iter().map(|s| square(a, *s, 0.0)).collect();
        v.push(it("Favicon/favicon.ico".into(), ico(&icons)));
        v.push(it("Favicon/favicon-32.png".into(), png(&square(a, 32, 0.0))));
        v.push(it("Favicon/apple-touch-icon.png".into(), png(&square(a, 180, 0.06))));
    }
    v.push(it(if en { "README.txt".into() } else { "LEGGIMI.txt".into() }, readme(name, en, fav).into_bytes()));
    v
}

fn readme(name: &str, en: bool, fav: bool) -> String {
    let mut s = if en {
        format!(
            "Logo pack made by OrbitLR\r\n\r\n\
             {name}.svg   For websites and design apps (Figma, Illustrator, Inkscape, Canva). Sharp at any size.\r\n\
             {name}.pdf   For print shops, Word, PowerPoint, Illustrator. Vector: sharp at any size.\r\n\
             {name}.eps   For print shops that ask for EPS (T-shirts, gadgets, signs). Vector.\r\n\
             PNG/         Transparent images: 512 px for documents, 1024 px for social, 2048 px for presentations.\r\n\
             One color/   Black and white versions: stamps, engraving, embroidery, dark backgrounds.\r\n"
        )
    } else {
        format!(
            "Pacchetto logo fatto con OrbitLR\r\n\r\n\
             {name}.svg   Per siti web e programmi di grafica (Figma, Illustrator, Inkscape, Canva). Nitido a qualunque misura.\r\n\
             {name}.pdf   Per tipografie, Word, PowerPoint, Illustrator. Vettoriale: nitido a qualunque misura.\r\n\
             {name}.eps   Per le tipografie che chiedono l'EPS (magliette, gadget, insegne). Vettoriale.\r\n\
             PNG/         Immagini trasparenti: 512 px per documenti, 1024 px per i social, 2048 px per presentazioni.\r\n\
             Un colore/   Versioni nera e bianca: timbri, incisioni, ricami, fondi scuri.\r\n"
        )
    };
    if fav {
        s += if en {
            "Favicon/     Icons for a website: favicon.ico (browser tab) and apple-touch-icon.png (iPhone home screen).\r\n"
        } else {
            "Favicon/     Icone per un sito: favicon.ico (scheda del browser) e apple-touch-icon.png (schermata Home dell'iPhone).\r\n"
        };
    }
    s
}

// ───────────────────────── ZIP (deflate, nomi UTF-8)

pub fn zip(items: &[Item], root: &str) -> Vec<u8> {
    let mut out = vec![];
    let mut central = vec![];
    let (time, date) = dos_now();
    for i in items {
        let name = format!("{root}/{}", i.path);
        let crc = crc32fast::hash(&i.data);
        let comp = miniz_oxide::deflate::compress_to_vec(&i.data, 7);
        let (method, body): (u16, &[u8]) = if comp.len() < i.data.len() { (8, &comp) } else { (0, &i.data) };
        let off = out.len() as u32;
        let hdr = |sig: u32, central: bool| {
            let mut h = vec![];
            h.extend_from_slice(&sig.to_le_bytes());
            if central {
                h.extend_from_slice(&20u16.to_le_bytes()); // fatto da
            }
            h.extend_from_slice(&20u16.to_le_bytes()); // serve
            h.extend_from_slice(&0x0800u16.to_le_bytes()); // nomi UTF-8
            h.extend_from_slice(&method.to_le_bytes());
            h.extend_from_slice(&time.to_le_bytes());
            h.extend_from_slice(&date.to_le_bytes());
            h.extend_from_slice(&crc.to_le_bytes());
            h.extend_from_slice(&(body.len() as u32).to_le_bytes());
            h.extend_from_slice(&(i.data.len() as u32).to_le_bytes());
            h.extend_from_slice(&(name.len() as u16).to_le_bytes());
            h.extend_from_slice(&0u16.to_le_bytes()); // extra
            if central {
                h.extend_from_slice(&0u16.to_le_bytes()); // commento
                h.extend_from_slice(&0u16.to_le_bytes()); // disco
                h.extend_from_slice(&0u16.to_le_bytes()); // attributi interni
                h.extend_from_slice(&0u32.to_le_bytes()); // attributi esterni
                h.extend_from_slice(&off.to_le_bytes());
            }
            h.extend_from_slice(name.as_bytes());
            h
        };
        out.extend_from_slice(&hdr(0x0403_4b50, false));
        out.extend_from_slice(body);
        central.extend_from_slice(&hdr(0x0201_4b50, true));
    }
    let cd_off = out.len() as u32;
    let cd_len = central.len() as u32;
    out.extend_from_slice(&central);
    out.extend_from_slice(&0x0605_4b50u32.to_le_bytes());
    out.extend_from_slice(&[0, 0, 0, 0]);
    out.extend_from_slice(&(items.len() as u16).to_le_bytes());
    out.extend_from_slice(&(items.len() as u16).to_le_bytes());
    out.extend_from_slice(&cd_len.to_le_bytes());
    out.extend_from_slice(&cd_off.to_le_bytes());
    out.extend_from_slice(&0u16.to_le_bytes());
    out
}

/// Ora e data nel formato del DOS (ora locale non disponibile senza librerie: si usa l'ora UTC).
fn dos_now() -> (u16, u16) {
    let secs = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or(0);
    let days = (secs / 86400) as i64;
    let rem = secs % 86400;
    // da giorni dal 1970 a data (algoritmo di Howard Hinnant)
    let z = days + 719_468;
    let era = z.div_euclid(146_097);
    let doe = z - era * 146_097;
    let yoe = (doe - doe / 1460 + doe / 36_524 - doe / 146_096) / 365;
    let y = yoe + era * 400;
    let doy = doe - (365 * yoe + yoe / 4 - yoe / 100);
    let mp = (5 * doy + 2) / 153;
    let d = doy - (153 * mp + 2) / 5 + 1;
    let m = if mp < 10 { mp + 3 } else { mp - 9 };
    let y = if m <= 2 { y + 1 } else { y };
    let time = ((rem / 3600) << 11 | ((rem % 3600) / 60) << 5 | (rem % 60) / 2) as u16;
    let date = ((((y - 1980).max(0)) as u64) << 9 | (m as u64) << 5 | d as u64) as u16;
    (time, date)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn pacchetto_completo_e_un_colore() {
        // logo: quadrato blu con un cerchio giallo e, dentro, un quadratino rosso; sfondo bianco
        let img = RgbaImage::from_fn(300, 300, |x, y| {
            let (dx, dy) = (x as f64 - 150.0, y as f64 - 150.0);
            if (135..165).contains(&x) && (135..165).contains(&y) {
                image::Rgba([220, 60, 50, 255])
            } else if dx * dx + dy * dy < 80.0 * 80.0 {
                image::Rgba([245, 190, 60, 255])
            } else if (30..270).contains(&x) && (30..270).contains(&y) {
                image::Rgba([30, 70, 120, 255])
            } else {
                image::Rgba([255, 255, 255, 255])
            }
        });
        let o = crate::Opts { precise: true, transparent: true, ..Default::default() };
        let out = crate::vectorize(&image::DynamicImage::ImageRgba8(img), None, &o, &mut |_| {}, &|| false).unwrap();
        let z = out.pack_zip("logo", "logo (pacchetto logo)", false);
        assert!(z.starts_with(b"PK"));
        let s = String::from_utf8_lossy(&z);
        for f in ["logo.svg", "logo.pdf", "logo.eps", "PNG/logo-2048.png", "Un colore/logo-nero.svg", "Un colore/logo-bianco-1024.png", "Favicon/favicon.ico", "LEGGIMI.txt"] {
            assert!(s.contains(f), "manca {f}");
        }
        assert!(pdf(&out.art).starts_with(b"%PDF-1.4"));
        assert!(eps(&out.art, "logo").starts_with(b"%!PS-Adobe-3.0 EPSF-3.0"));
        // a un colore: il fondo blu pieno, il cerchio giallo vuoto, il quadratino rosso di nuovo pieno
        let one = raster(&one_color(&out.art), 300);
        let a = |x: u32, y: u32| one.get_pixel(x, y).0[3];
        assert!(a(50, 50) > 200, "fondo");
        assert!(a(150, 100) < 50, "cerchio");
        assert!(a(150, 150) > 200, "quadratino");
        assert!(a(5, 5) < 50, "fuori");
    }
}
