//! Prova di «Rimuovi lo sfondo» con il motore attuale: un cerchio su fondo a righe.
fn main() {
    let model = std::path::PathBuf::from(std::env::args().nth(1).unwrap());
    let img = image::RgbImage::from_fn(800, 600, |x, y| {
        let (dx, dy) = (x as f32 - 400.0, y as f32 - 300.0);
        if dx * dx + dy * dy < 150.0 * 150.0 { image::Rgb([220, 60, 40]) } else if (x / 20) % 2 == 0 { image::Rgb([200, 200, 190]) } else { image::Rgb([170, 175, 165]) }
    });
    let t = std::time::Instant::now();
    let m = orbit_engine::ai::subject_mask(&model, &img).unwrap();
    println!("fatto in {:?}; centro {} angolo {}", t.elapsed(), m.get_pixel(400, 300)[0], m.get_pixel(20, 20)[0]);
}
