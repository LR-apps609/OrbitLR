use std::path::{Path, PathBuf};
use std::process::Command;
use std::sync::OnceLock;

/// Dove sono ffmpeg e ffprobe, e cosa sa fare questo computer.
#[derive(Debug, Clone)]
pub struct Tools {
    pub ffmpeg: PathBuf,
    pub ffprobe: PathBuf,
    encoders: std::sync::Arc<OnceLock<Encoders>>,
}

/// I codificatori video che funzionano davvero su questo computer, dal migliore al più lento.
#[derive(Debug, Clone, Default, serde::Serialize)]
pub struct Encoders {
    pub h264: Vec<String>,
    pub hevc: Vec<String>,
    pub all: Vec<String>,
}

impl Tools {
    /// Cerca prima nella cartella dei motori dell'app, poi nel PATH (per le prove su Linux e in sviluppo).
    pub fn locate(motori: Option<&Path>) -> Option<Tools> {
        let exe = |n: &str| if cfg!(windows) { format!("{n}.exe") } else { n.to_string() };
        if let Some(dir) = motori {
            let f = dir.join(exe("ffmpeg"));
            let p = dir.join(exe("ffprobe"));
            if f.is_file() && p.is_file() {
                return Some(Tools::at(f, p));
            }
        }
        let f = which(&exe("ffmpeg"))?;
        let p = which(&exe("ffprobe"))?;
        Some(Tools::at(f, p))
    }

    pub fn at(ffmpeg: PathBuf, ffprobe: PathBuf) -> Tools {
        Tools { ffmpeg, ffprobe, encoders: Default::default() }
    }

    pub fn ffmpeg_cmd(&self) -> Command {
        quiet(Command::new(&self.ffmpeg))
    }

    pub fn ffprobe_cmd(&self) -> Command {
        quiet(Command::new(&self.ffprobe))
    }

    /// Prova ogni codificatore una volta (una frazione di secondo): l'elenco di ffmpeg dice cosa è
    /// compilato, non cosa c'è sul computer (una scheda NVIDIA, Intel o AMD).
    pub fn encoders(&self) -> &Encoders {
        self.encoders.get_or_init(|| detect(self))
    }

    pub fn version(&self) -> String {
        let out = self.ffmpeg_cmd().args(["-hide_banner", "-version"]).output();
        out.ok()
            .and_then(|o| String::from_utf8(o.stdout).ok())
            .and_then(|s| s.lines().next().map(|l| l.to_string()))
            .unwrap_or_default()
    }
}

/// Su Windows i programmi lanciati non aprono la finestra nera del terminale.
pub fn quiet(mut c: Command) -> Command {
    #[cfg(windows)]
    {
        use std::os::windows::process::CommandExt;
        const CREATE_NO_WINDOW: u32 = 0x0800_0000;
        c.creation_flags(CREATE_NO_WINDOW);
    }
    c.stdin(std::process::Stdio::null());
    c
}

/// Su Windows i processi figli (ffmpeg) non muoiono con l'app: li si lega a un «Job» di Windows
/// che li chiude da solo quando OrbitLR si chiude, anche se viene chiusa a forza.
#[cfg(windows)]
pub fn bind_to_app(child: &std::process::Child) {
    use std::os::windows::io::AsRawHandle;
    use windows_sys::Win32::Foundation::HANDLE;
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JobObjectExtendedLimitInformation, SetInformationJobObject,
        JOBOBJECT_EXTENDED_LIMIT_INFORMATION, JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE,
    };
    static JOB: OnceLock<usize> = OnceLock::new();
    let job = *JOB.get_or_init(|| unsafe {
        let h = CreateJobObjectW(std::ptr::null(), std::ptr::null());
        if h as usize == 0 {
            return 0;
        }
        let mut info: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
        info.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(
            h,
            JobObjectExtendedLimitInformation,
            &info as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION as *const core::ffi::c_void,
            std::mem::size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
        );
        h as usize
    });
    if job != 0 {
        unsafe {
            AssignProcessToJobObject(job as HANDLE, child.as_raw_handle() as HANDLE);
        }
    }
}

#[cfg(not(windows))]
pub fn bind_to_app(_child: &std::process::Child) {}

fn which(name: &str) -> Option<PathBuf> {
    let path = std::env::var_os("PATH")?;
    std::env::split_paths(&path).map(|d| d.join(name)).find(|p| p.is_file())
}

const H264: &[&str] = &["h264_nvenc", "h264_qsv", "h264_amf", "h264_mf", "libx264", "libopenh264"];
const HEVC: &[&str] = &["hevc_nvenc", "hevc_qsv", "hevc_amf", "hevc_mf", "libx265"];

fn detect(t: &Tools) -> Encoders {
    let listed = t
        .ffmpeg_cmd()
        .args(["-hide_banner", "-encoders"])
        .output()
        .ok()
        .map(|o| String::from_utf8_lossy(&o.stdout).to_string())
        .unwrap_or_default();
    let all: Vec<String> = listed
        .lines()
        .filter_map(|l| {
            let mut it = l.split_whitespace();
            let flags = it.next()?;
            let name = it.next()?;
            (flags.len() == 6 && !name.starts_with('=')).then(|| name.to_string())
        })
        .collect();
    let works = |name: &str| -> bool {
        if !all.iter().any(|a| a == name) {
            return false;
        }
        // Una prova minuscola: se la scheda video non c'è, il codificatore hardware fallisce subito
        let mut c = t.ffmpeg_cmd();
        c.args(["-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "color=c=gray:s=320x240:d=0.2:r=10"])
            .args(["-pix_fmt", if name.starts_with("lib") { "yuv420p" } else { "nv12" }])
            .args(["-c:v", name, "-b:v", "500k", "-f", "null", "-"]);
        matches!(c.output(), Ok(o) if o.status.success())
    };
    Encoders {
        h264: H264.iter().filter(|n| works(n)).map(|s| s.to_string()).collect(),
        hevc: HEVC.iter().filter(|n| works(n)).map(|s| s.to_string()).collect(),
        all,
    }
}
