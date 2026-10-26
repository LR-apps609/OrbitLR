//! Prova di «Togli con l'IA»: una foto con un logo sopra → il logo sparisce.
//! cargo run --release --example prova_logo -- modello.onnx uscita-cartella
use image::{Rgba, RgbaImage};
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (model, dir) = (std::path::PathBuf::from(&a[1]), std::path::PathBuf::from(&a[2]));
    // Un «paesaggio»: cielo sfumato, mare a righe, e un logo bianco con bordo nero
    let mut img = RgbaImage::from_fn(1200, 800, |x, y| {
        if y < 450 { Rgba([(120 + y / 6) as u8, (170 + y / 10) as u8, 230, 255]) } else { let w = ((x / 9 + y / 5) % 7) as u8 * 6; Rgba([40 + w, 100 + w, 150 + w, 255]) }
    });
    for y in 380..470 { for x in 820..1100 { let b = x < 826 || x > 1093 || y < 386 || y > 463; img.put_pixel(x, y, if b { Rgba([0, 0, 0, 255]) } else { Rgba([250, 250, 250, 255]) }); } }
    img.save(dir.join("logo-prima.png")).unwrap();
    let t = std::time::Instant::now();
    orbit_engine::inpaint::fill_with_model(&model, &mut img, &[(816, 376, 290, 98)], &orbit_engine::run::Cancel::new(), &mut |_| {}).unwrap();
    println!("fatto in {:?}", t.elapsed());
    img.save(dir.join("logo-dopo.png")).unwrap();
    // Nella zona non deve restare il bianco del logo
    let mut white = 0;
    for y in 395..455 { for x in 840..1080 { let p = img.get_pixel(x, y).0; if p[0] > 235 && p[1] > 235 && p[2] > 235 { white += 1; } } }
    println!("pixel bianchi rimasti: {white} su {}", 60 * 240);
}
