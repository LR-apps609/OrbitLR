//! Il montaggio (come l'editor dell'app per Mac): clip tagliate, velocità, filtri, effetti,
//! transizioni, testi, musica che si abbassa da sola quando si parla. Diventa un solo grafo di ffmpeg.
//! Le transizioni stanno a cavallo del taglio: la durata del video non cambia.

use crate::args;
use crate::error::{EngineError, Result};
use crate::look::Look;
use crate::names;
use crate::probe::{self, FileInfo};
use crate::run::{self, Cancel};
use crate::tools::Tools;
use crate::video::{self, Codec};
use serde::{Deserialize, Serialize};
use std::ffi::OsString;
use std::path::{Path, PathBuf};

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Effects {
    pub speed: f64,
    /// «none», «in», «out»
    pub zoom: String,
    pub flip_h: bool,
    pub flip_v: bool,
    /// 0, 90, 180, 270 in senso orario
    pub rotate: i32,
    /// 0…1
    pub blur: f64,
    pub fade_in: f64,
    pub fade_out: f64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Transition {
    /// «fade», «black», «white», «slide», «zoom», «blur»
    pub kind: String,
    pub duration: f64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Clip {
    pub path: String,
    pub in_point: f64,
    pub out_point: f64,
    pub muted: bool,
    pub look: Option<Look>,
    /// Tra la clip precedente e questa
    pub transition: Option<Transition>,
    pub fx: Option<Effects>,
}

impl Clip {
    pub fn speed(&self) -> f64 {
        self.fx.as_ref().map(|f| if f.speed > 0.0 { f.speed } else { 1.0 }).unwrap_or(1.0).clamp(0.25, 4.0)
    }
    pub fn length(&self) -> f64 {
        (self.out_point - self.in_point).max(0.0) / self.speed()
    }
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Music {
    pub path: String,
    /// Dove parte nel montaggio
    pub offset: f64,
    /// Da che punto della canzone
    pub in_point: f64,
    pub looped: bool,
    #[serde(default = "music_volume")]
    pub volume: f64,
    pub fade_in: f64,
    pub fade_out: f64,
    /// Abbassa la musica quando si parla
    pub duck: bool,
}

/// Un'immagine di una sequenza, con quanto resta sullo schermo.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Frame {
    pub png: String,
    pub duration: f64,
}

/// Un testo già disegnato dall'app (PNG trasparente grande come il video), da mostrare tra `start` ed `end`.
/// Per «Parola per parola» e «Macchina da scrivere» c'è una sequenza (`frames`): un solo ingresso per riga.
#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Overlay {
    pub frames: Vec<Frame>,
    pub png: String,
    pub start: f64,
    pub end: f64,
    pub fade_in: f64,
    pub fade_out: f64,
    /// Entra scorrendo dal basso di tanti pixel (0 = no)
    pub slide: f64,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
#[serde(default)]
pub struct Project {
    pub name: String,
    pub clips: Vec<Clip>,
    pub music: Option<Music>,
    #[serde(default = "one")]
    pub original_volume: f64,
    pub original_muted: bool,
    /// «orig», «9x16», «1x1», «4x5», «16x9»
    pub aspect: String,
    /// Lato corto: 720, 1080, 2160 (mai più grande dell'originale)
    pub resolution: u32,
    pub fps: f64,
    pub look: Option<Look>,
    pub overlays: Vec<Overlay>,
}

fn one() -> f64 {
    1.0
}
fn music_volume() -> f64 {
    0.8
}

impl Project {
    pub fn duration(&self) -> f64 {
        self.clips.iter().map(Clip::length).sum()
    }
}

fn even(x: f64) -> u32 {
    (((x / 2.0).round() as u32) * 2).max(2)
}

/// La misura del video finale: quella della prima clip (dritta), ritagliata al formato scelto,
/// con il lato corto al massimo `resolution`.
pub fn canvas(p: &Project, first: &FileInfo) -> (u32, u32) {
    let (mut w, mut h) = (first.width.max(2) as f64, first.height.max(2) as f64);
    if let Some(fx) = p.clips.first().and_then(|c| c.fx.as_ref()) {
        if fx.rotate.rem_euclid(180) == 90 {
            std::mem::swap(&mut w, &mut h);
        }
    }
    let ratio = match p.aspect.as_str() {
        "9x16" => Some(9.0 / 16.0),
        "1x1" => Some(1.0),
        "4x5" => Some(4.0 / 5.0),
        "16x9" => Some(16.0 / 9.0),
        _ => None,
    };
    if let Some(r) = ratio {
        let (cw, ch) = if w / h > r { (h * r, h) } else { (w, w / r) };
        w = cw;
        h = ch;
    }
    let res = if p.resolution > 0 { p.resolution as f64 } else { 1080.0 };
    let k = (res / w.min(h)).min(1.0);
    (even(w * k), even(h * k))
}

fn xfade_name(kind: &str) -> &'static str {
    match kind {
        "black" => "fadeblack",
        "white" => "fadewhite",
        "slide" => "slideleft",
        "zoom" => "zoomin",
        "blur" => "hblur",
        _ => "fade",
    }
}

/// Costruisce argomenti e grafo. Restituisce (argomenti senza l'uscita, durata).
pub fn build(p: &Project, infos: &[FileInfo], w: u32, h: u32) -> Result<(Vec<OsString>, f64)> {
    if p.clips.is_empty() {
        return Err(EngineError::new("il montaggio è vuoto"));
    }
    let fps = if p.fps > 0.0 { p.fps.clamp(10.0, 60.0) } else { 30.0 };
    let orig_vol = if p.original_muted { 0.0 } else { p.original_volume.clamp(0.0, 2.0) };
    let mut a: Vec<OsString> = Vec::new();
    let mut g = String::new();
    let n = p.clips.len();
    // Durata di ogni transizione (verso la clip i), limitata dalle clip vicine
    let tdur: Vec<f64> = (0..n)
        .map(|i| {
            if i == 0 {
                return 0.0;
            }
            match &p.clips[i].transition {
                Some(t) if t.duration > 0.01 => t.duration.min(p.clips[i - 1].length() * 0.5).min(p.clips[i].length() * 0.5).min(2.0).max(0.0),
                _ => 0.0,
            }
        })
        .collect();

    for (i, c) in p.clips.iter().enumerate() {
        let info = &infos[i];
        let src_len = (c.out_point - c.in_point).max(0.05);
        // Una foto nel montaggio: si ripete per la durata scelta
        if info.kind == Some(crate::probe::Kind::Image) {
            a.extend(args!["-loop", "1", "-framerate", format!("{fps:.3}"), "-t", format!("{src_len:.3}"), "-i", &c.path]);
        } else {
            a.extend(args!["-ss", format!("{:.3}", c.in_point.max(0.0)), "-t", format!("{src_len:.3}"), "-i", &c.path]);
        }
        let fx = c.fx.clone().unwrap_or_default();
        let speed = c.speed();
        let len = src_len / speed;
        let mut v: Vec<String> = vec!["setpts=PTS-STARTPTS".into()];
        if (speed - 1.0).abs() > 0.001 {
            v.push(format!("setpts=PTS/{speed:.4}"));
        }
        match fx.rotate.rem_euclid(360) {
            90 => v.push("transpose=1".into()),
            180 => v.push("transpose=1,transpose=1".into()),
            270 => v.push("transpose=2".into()),
            _ => {}
        }
        if fx.flip_h {
            v.push("hflip".into());
        }
        if fx.flip_v {
            v.push("vflip".into());
        }
        // Riempie la tela (formato social: ritaglia al centro), altrimenti sta dentro con le bande
        if p.aspect.is_empty() || p.aspect == "orig" {
            v.push(format!("scale={w}:{h}:force_original_aspect_ratio=decrease:flags=lanczos,pad={w}:{h}:(ow-iw)/2:(oh-ih)/2"));
        } else {
            v.push(format!("scale={w}:{h}:force_original_aspect_ratio=increase:flags=lanczos,crop={w}:{h}"));
        }
        v.push(format!("fps={fps:.3}"));
        // Se il video della clip finisce prima (audio più lungo nel file), l'ultimo fotogramma resta: la clip dura sempre `len`
        v.push(format!("tpad=stop_mode=clone:stop_duration={len:.3},trim=duration={len:.3},setpts=PTS-STARTPTS"));
        if fx.zoom == "in" || fx.zoom == "out" {
            let frames = (len * fps).max(1.0).round();
            let z = if fx.zoom == "in" { format!("1+0.15*on/{frames}") } else { format!("1.15-0.15*on/{frames}") };
            v.push(format!("zoompan=z='{z}':d=1:x='iw/2-(iw/zoom/2)':y='ih/2-(ih/zoom/2)':s={w}x{h}:fps={fps:.3}"));
        }
        if fx.blur > 0.01 {
            // Stessa sfocatura dell'anteprima a ogni risoluzione
            v.push(format!("gblur=sigma={:.1}", fx.blur.min(1.0) * 25.0 * h as f64 / 1080.0));
        }
        let look = c.look.as_ref().or(p.look.as_ref());
        if let Some(l) = look {
            let f = l.ffmpeg_filter(&format!("l{i}"));
            if !f.is_empty() {
                v.push(f);
            }
        }
        if fx.fade_in > 0.01 {
            v.push(format!("fade=t=in:st=0:d={:.3}", fx.fade_in.min(len)));
        }
        if fx.fade_out > 0.01 {
            v.push(format!("fade=t=out:st={:.3}:d={:.3}", (len - fx.fade_out).max(0.0), fx.fade_out.min(len)));
        }
        // Le transizioni stanno a cavallo del taglio: metà prima, metà dopo (fermo immagine)
        let before = tdur[i] / 2.0;
        let after = if i + 1 < n { tdur[i + 1] / 2.0 } else { 0.0 };
        if before > 0.0 || after > 0.0 {
            v.push(format!("tpad=start_mode=clone:start_duration={before:.3}:stop_mode=clone:stop_duration={after:.3}"));
        }
        // Base dei tempi uguale per tutti: xfade la vuole identica (anche dopo un concat)
        v.push("setsar=1,format=yuv420p,settb=AVTB".into());
        g.push_str(&format!("[{i}:v]{}[v{i}];", v.join(",")));

        // Audio della clip
        let vol = if c.muted { 0.0 } else { orig_vol };
        if info.has_audio && vol > 0.001 {
            let mut au: Vec<String> = vec!["asetpts=PTS-STARTPTS".into(), "aresample=48000".into(), "aformat=sample_fmts=fltp:channel_layouts=stereo".into()];
            if (speed - 1.0).abs() > 0.001 {
                au.push(crate::audio::atempo_chain(speed));
            }
            if (vol - 1.0).abs() > 0.001 {
                au.push(format!("volume={vol:.3}"));
            }
            if fx.fade_in > 0.01 {
                au.push(format!("afade=t=in:st=0:d={:.3}", fx.fade_in.min(len)));
            }
            if fx.fade_out > 0.01 {
                au.push(format!("afade=t=out:st={:.3}:d={:.3}", (len - fx.fade_out).max(0.0), fx.fade_out.min(len)));
            }
            // Lunghezza esatta (con i pezzi delle transizioni in silenzio)
            if before > 0.0 {
                au.push(format!("adelay={}:all=1", (before * 1000.0).round() as i64));
            }
            au.push(format!("apad,atrim=0:{:.3}", before + len + after));
            g.push_str(&format!("[{i}:a]{}[a{i}];", au.join(",")));
        } else {
            g.push_str(&format!("anullsrc=r=48000:cl=stereo,atrim=0:{:.3}[a{i}];", before + len + after));
        }
    }

    // Unione: xfade dove c'è una transizione, altrimenti concat
    let mut cur_v = "v0".to_string();
    let mut cur_a = "a0".to_string();
    let first_after = if n > 1 { tdur[1] / 2.0 } else { 0.0 };
    let mut acc = p.clips[0].length() + first_after;
    for i in 1..n {
        let d = tdur[i];
        let li = p.clips[i].length() + d / 2.0 + if i + 1 < n { tdur[i + 1] / 2.0 } else { 0.0 };
        let (nv, na) = (format!("vj{i}"), format!("aj{i}"));
        if d > 0.0 {
            let kind = p.clips[i].transition.as_ref().map(|t| t.kind.as_str()).unwrap_or("fade");
            g.push_str(&format!("[{cur_v}][v{i}]xfade=transition={}:duration={d:.3}:offset={:.3}[{nv}];", xfade_name(kind), (acc - d).max(0.0)));
            g.push_str(&format!("[{cur_a}][a{i}]acrossfade=d={d:.3}:c1=tri:c2=tri[{na}];"));
            acc = acc + li - d;
        } else {
            g.push_str(&format!("[{cur_v}][{cur_a}][v{i}][a{i}]concat=n=2:v=1:a=1[{nv}][{na}];"));
            acc += li;
        }
        cur_v = nv;
        cur_a = na;
    }
    let total = p.duration();
    let mut next_input = n;

    // Testi
    for (k, o) in p.overlays.iter().enumerate() {
        let start = o.start.max(0.0);
        let end = o.end.min(total);
        if !(end > start) {
            continue;
        }
        let dur = end - start;
        if !o.frames.is_empty() {
            if o.frames.iter().any(|f| !Path::new(&f.png).is_file()) {
                continue;
            }
            // Una sequenza (parola per parola): un file di elenco per il concat demuxer
            let mut list = String::from("ffconcat version 1.0\n");
            for f in &o.frames {
                list.push_str(&format!("file '{}'\nduration {:.3}\n", f.png.replace('\'', "'\\''"), f.duration.max(0.04)));
            }
            if let Some(last) = o.frames.last() {
                list.push_str(&format!("file '{}'\n", last.png.replace('\'', "'\\''")));
            }
            let lf = Path::new(&o.frames[0].png).with_extension("ffconcat");
            if std::fs::write(&lf, list).is_err() {
                continue;
            }
            a.extend(args!["-itsoffset", format!("{start:.3}"), "-f", "concat", "-safe", "0", "-i", &lf]);
        } else {
            if !Path::new(&o.png).is_file() {
                continue;
            }
            a.extend(args!["-itsoffset", format!("{start:.3}"), "-loop", "1", "-framerate", format!("{fps:.3}"), "-t", format!("{:.3}", dur + 0.1), "-i", &o.png]);
        }
        let idx = next_input;
        next_input += 1;
        let mut tf = vec![format!("fps={fps:.3}"), "format=rgba".to_string()];
        if o.fade_in > 0.01 {
            tf.push(format!("fade=t=in:st={start:.3}:d={:.3}:alpha=1", o.fade_in.min(dur)));
        }
        if o.fade_out > 0.01 {
            tf.push(format!("fade=t=out:st={:.3}:d={:.3}:alpha=1", (end - o.fade_out).max(start), o.fade_out.min(dur)));
        }
        g.push_str(&format!("[{idx}:v]{}[t{k}];", tf.join(",")));
        let y = if o.slide > 0.5 {
            format!("'if(lt(t-{start:.3},0.45),{sl:.1}*(1-(t-{start:.3})/0.45),0)'", sl = o.slide)
        } else {
            "0".into()
        };
        g.push_str(&format!("[{cur_v}][t{k}]overlay=x=0:y={y}:enable='between(t,{start:.3},{end:.3})':eof_action=pass:repeatlast=0[vt{k}];"));
        cur_v = format!("vt{k}");
    }

    // Musica
    if let Some(m) = p.music.as_ref().filter(|m| Path::new(&m.path).is_file()) {
        if m.looped {
            a.extend(args!["-stream_loop", "-1"]);
        }
        a.extend(args!["-ss", format!("{:.3}", m.in_point.max(0.0)), "-i", &m.path]);
        let idx = next_input;
        let play = (total - m.offset.max(0.0)).max(0.1);
        let vol = m.volume.clamp(0.0, 2.0);
        let mut mf = vec![format!("atrim=0:{play:.3}"), "asetpts=PTS-STARTPTS".into(), "aresample=48000".into(), "aformat=sample_fmts=fltp:channel_layouts=stereo".into(), format!("volume={vol:.3}")];
        if m.fade_in > 0.01 {
            mf.push(format!("afade=t=in:st=0:d={:.3}", m.fade_in));
        }
        if m.fade_out > 0.01 {
            mf.push(format!("afade=t=out:st={:.3}:d={:.3}", (play - m.fade_out).max(0.0), m.fade_out));
        }
        if m.offset > 0.01 {
            mf.push(format!("adelay={}:all=1", (m.offset * 1000.0).round() as i64));
        }
        g.push_str(&format!("[{idx}:a]{}[mus];", mf.join(",")));
        if m.duck && orig_vol > 0.001 {
            g.push_str(&format!("[{cur_a}]asplit[vo][sc];[mus][sc]sidechaincompress=threshold=0.02:ratio=8:attack=40:release=500:makeup=1[md];[vo][md]amix=inputs=2:duration=first:normalize=0[amx];"));
        } else {
            g.push_str(&format!("[{cur_a}][mus]amix=inputs=2:duration=first:normalize=0[amx];"));
        }
        cur_a = "amx".into();
    }

    // Etichette finali
    g.push_str(&format!("[{cur_v}]null[vout];[{cur_a}]anull[aout]"));
    a.extend(args!["-filter_complex", g, "-map", "[vout]", "-map", "[aout]", "-t", format!("{total:.3}")]);
    Ok((a, total))
}

/// Esporta il montaggio in un MP4 nella cartella `dir`.
pub fn export(tools: &Tools, p: &Project, dir: &Path, cancel: &Cancel, progress: &mut dyn FnMut(f64)) -> Result<PathBuf> {
    if p.clips.is_empty() {
        return Err(EngineError::new("il montaggio è vuoto: aggiungi almeno una clip"));
    }
    let mut infos = Vec::new();
    for c in &p.clips {
        let path = Path::new(&c.path);
        if !path.is_file() {
            return Err(EngineError::new(format!("non trovo più «{}»", path.file_name().unwrap_or_default().to_string_lossy())));
        }
        infos.push(probe::probe(Some(tools), path)?);
    }
    let (w, h) = canvas(p, &infos[0]);
    let (mut base, total) = build(p, &infos, w, h)?;
    // Grafo lungo (tanti sottotitoli): in un file, perché Windows limita la riga di comando a 32.767 caratteri
    let graph_file = names::temp_beside(&dir.join("x.txt"), "txt");
    struct Rm(PathBuf);
    impl Drop for Rm {
        fn drop(&mut self) {
            let _ = std::fs::remove_file(&self.0);
            names::track_temp(&self.0, false);
        }
    }
    let _rm = Rm(graph_file.clone());
    if let Some(i) = base.iter().position(|x| x == "-filter_complex") {
        let g = base[i + 1].clone();
        if g.len() > 6000 {
            std::fs::write(&graph_file, g.to_string_lossy().as_bytes())?;
            let major = tools.version().split("version").nth(1).map(|v| v.trim().trim_start_matches('n')).and_then(|v| v.split(|c: char| !c.is_ascii_digit()).next()).and_then(|d| d.parse::<u32>().ok()).unwrap_or(7);
            if major >= 7 {
                base[i] = "-/filter_complex".into();
            } else {
                base[i] = "-filter_complex_script".into();
            }
            base[i + 1] = graph_file.clone().into();
        }
    }
    if total < 0.1 {
        return Err(EngineError::new("il montaggio è vuoto"));
    }
    let fps = if p.fps > 0.0 { p.fps.clamp(10.0, 60.0) } else { 30.0 };
    let bitrate = (w as f64 * h as f64 * fps * 0.11).max(1_500_000.0) as u64;
    video::ensure_space(dir, (bitrate as f64 * total / 8.0) as u64)?;
    let name = if p.name.trim().is_empty() { "Montaggio".to_string() } else { p.name.trim().to_string() };
    let of = names::OutFile::new(dir, &name, "mp4")?;
    let mut last = EngineError::new("nessun codificatore video disponibile");
    for enc in video::candidates(tools, Codec::H264) {
        let mut a = base.clone();
        a.extend(video::encoder_args(&enc, bitrate));
        a.extend(args!["-c:a", "aac", "-b:a", "192k", "-movflags", "+faststart", &of.tmp]);
        match run::ffmpeg(tools, &a, total, cancel, progress) {
            Ok(()) => return of.commit(),
            Err(e) if e.is_cancelled() => return Err(e),
            Err(e) => {
                let _ = std::fs::remove_file(&of.tmp);
                last = e;
            }
        }
    }
    Err(last)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn info(w: u32, h: u32) -> FileInfo {
        FileInfo { width: w, height: h, has_video: true, has_audio: true, fps: 30.0, duration: 10.0, ..Default::default() }
    }

    #[test]
    fn tela_e_formati() {
        let mut p = Project { clips: vec![Clip { path: "a".into(), out_point: 5.0, ..Default::default() }], resolution: 1080, ..Default::default() };
        assert_eq!(canvas(&p, &info(3840, 2160)), (1920, 1080));
        p.aspect = "9x16".into();
        assert_eq!(canvas(&p, &info(1920, 1080)), (608, 1080));
        p.aspect = "1x1".into();
        assert_eq!(canvas(&p, &info(1080, 1920)), (1080, 1080));
    }

    #[test]
    fn durata_con_velocita_e_transizioni() {
        let c1 = Clip { path: "a".into(), in_point: 0.0, out_point: 4.0, ..Default::default() };
        let mut c2 = Clip { path: "b".into(), in_point: 2.0, out_point: 6.0, fx: Some(Effects { speed: 2.0, ..Default::default() }), ..Default::default() };
        c2.transition = Some(Transition { kind: "fade".into(), duration: 0.8 });
        let p = Project { clips: vec![c1, c2], ..Default::default() };
        assert!((p.duration() - 6.0).abs() < 1e-9, "4 s + 4 s a 2× = 6 s; la transizione non toglie tempo");
        let (a, total) = build(&p, &[info(1280, 720), info(1280, 720)], 1280, 720).unwrap();
        assert!((total - 6.0).abs() < 1e-9);
        let g = a.iter().map(|x| x.to_string_lossy().to_string()).find(|x| x.contains("xfade")).unwrap();
        assert!(g.contains("xfade=transition=fade:duration=0.800:offset=3.600"), "{g}");
    }
}
