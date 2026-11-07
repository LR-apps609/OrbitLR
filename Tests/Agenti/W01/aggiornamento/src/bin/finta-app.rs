// Finta OrbitLR: scrive in W01_SEGNO che è stata riaperta.
fn main() {
    let args: Vec<String> = std::env::args().collect();
    if let Some(p) = std::env::var_os("W01_SEGNO") {
        use std::io::Write;
        let mut f = std::fs::OpenOptions::new().create(true).append(true).open(p).unwrap();
        let _ = writeln!(f, "APP {:?}", args);
    }
}
