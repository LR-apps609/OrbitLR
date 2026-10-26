//! L'azione vera «Nascondi un logo» → «Togli con l'IA», con il modello nella cartella dei dati.
fn main() {
    let a: Vec<String> = std::env::args().collect();
    let (data, dir) = (std::path::PathBuf::from(&a[1]), std::path::PathBuf::from(&a[2]));
    let mut img = image::RgbImage::from_fn(1000, 700, |x, y| if y < 400 { image::Rgb([(110 + y / 5) as u8, 160, 220]) } else { image::Rgb([60, (120 + (x % 40)) as u8, 70]) });
    for y in 300..380 { for x in 600..900 { img.put_pixel(x, y, image::Rgb([255, 255, 255])); } }
    let src = dir.join("Cartolina.jpg");
    img.save(&src).unwrap();
    let p: orbit_engine::hide::Params = serde_json::from_value(serde_json::json!({"zones": [{"x": 0.59, "y": 0.42, "w": 0.32, "h": 0.13}], "mode": "ai"})).unwrap();
    let t = std::time::Instant::now();
    let out = orbit_engine::hide::photo_ai(None, Some(&data), &src, &p, &dir, &orbit_engine::run::Cancel::new(), &mut |_| {}).unwrap();
    println!("{} in {:?}", out.display(), t.elapsed());
    let o = image::open(&out).unwrap().to_rgb8();
    let white = (300..380).flat_map(|y| (610..890).map(move |x| (x, y))).filter(|&(x, y)| o.get_pixel(x, y).0.iter().all(|&c| c > 240)).count();
    println!("bianchi rimasti: {white}");
}
