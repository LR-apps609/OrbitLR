//! Prova del modello LaMa (ONNX) con tract: un quadrato rosso su un fondo a righe si deve ricostruire.
//! cargo run --release --example prova_lama -- lama.onnx
use tract_onnx::prelude::*;

fn main() -> TractResult<()> {
    let path = std::env::args().nth(1).expect("percorso del modello");
    let s = 512usize;
    let t0 = std::time::Instant::now();
    let model = tract_onnx::onnx().model_for_path(&path)?;
    for (i, o) in model.input_outlets()?.iter().enumerate() {
        println!("ingresso {i}: {} {:?}", model.node(o.node).name, model.outlet_fact(*o)?);
    }
    let model = model
        .with_input_fact(0, f32::fact([1, 3, s, s]).into())?
        .with_input_fact(1, f32::fact([1, 1, s, s]).into())?
        .into_optimized()?
        .into_runnable()?;
    println!("caricato in {:?}", t0.elapsed());
    // Righe verticali grigie/blu, quadrato rosso al centro da togliere
    let bg = |x: usize| if (x / 16) % 2 == 0 { [0.3f32, 0.4, 0.8] } else { [0.8, 0.8, 0.8] };
    let in_sq = |x: usize, y: usize| (200..312).contains(&x) && (200..312).contains(&y);
    let img: Tensor = tract_ndarray::Array4::from_shape_fn((1, 3, s, s), |(_, c, y, x)| if in_sq(x, y) { [1.0, 0.0, 0.0][c] } else { bg(x)[c] }).into();
    let mask: Tensor = tract_ndarray::Array4::from_shape_fn((1, 1, s, s), |(_, _, y, x)| if in_sq(x, y) { 1.0f32 } else { 0.0 }).into();
    let t1 = std::time::Instant::now();
    let out = model.run(tvec!(img.into(), mask.into()))?;
    println!("eseguito in {:?}", t1.elapsed());
    let o = out[0].to_array_view::<f32>()?;
    println!("uscita {:?}", o.shape());
    let (mut mi, mut ma) = (f32::MAX, f32::MIN);
    for v in o.iter() { mi = mi.min(*v); ma = ma.max(*v); }
    println!("valori da {mi} a {ma}");
    let scale = if ma > 2.0 { 255.0 } else { 1.0 };
    // Nel quadrato: il rosso deve sparire (rosso non più dominante)
    let (mut red, mut n) = (0.0f32, 0.0f32);
    for y in 220..292 { for x in 220..292 {
        let r = o[[0, 0, y, x]] / scale; let g = o[[0, 1, y, x]] / scale; let b = o[[0, 2, y, x]] / scale;
        red += r - (g + b) / 2.0; n += 1.0;
    }}
    let red = red / n;
    println!("rosso residuo nel quadrato: {red:.3} (scala {scale})");
    if red > 0.25 { eprintln!("ERRORE: il quadrato è ancora rosso"); std::process::exit(1); }
    println!("OK");
    Ok(())
}
