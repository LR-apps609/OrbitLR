# OrbitLR per Windows · prova su un computer di GitHub come una persona nuova:
# installazione scaricata da internet (Zone.Identifier), per l'utente senza amministratore, cartelle con accenti e spazi,
# italiano e inglese, varie scale e risoluzioni. Foto della finestra, processo vivo o no, diario e registri.
# Uso: pwsh -File Tools/dispositivo-windows.ps1 -Nome windows-2025 -Setup OrbitLR-Setup.exe -Out cartella
param([string]$Nome = "windows", [string]$Setup = "OrbitLR-Setup.exe", [string]$Out = "foto")

$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$Info = Join-Path $Out "windows.txt"
function Log([string]$m) { $l = "$(Get-Date -Format HH:mm:ss) $m"; Write-Host $l; Add-Content -Path (Join-Path $Out "diario.txt") -Value $l -Encoding utf8 }
function Note([string]$m) { Add-Content -Path $Info -Value $m -Encoding utf8; Write-Host "INFO $m" }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("dwmapi.dll")] public static extern int DwmGetWindowAttribute(IntPtr h, int a, out RECT r, int s);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern uint GetDpiForWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetDpiForSystem();
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromWindow(IntPtr h, uint f);
  [DllImport("user32.dll")] public static extern IntPtr MonitorFromPoint(POINT p, uint f);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
  [DllImport("user32.dll", EntryPoint="SystemParametersInfoW")] public static extern bool SpiSet(uint a, int p, IntPtr v, uint w);
  [DllImport("user32.dll", EntryPoint="SystemParametersInfoW")] public static extern bool SpiGet(uint a, uint p, ref int v, uint w);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int ChangeDisplaySettingsEx(string dev, ref DEVMODE dm, IntPtr h, uint f, IntPtr l);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool EnumDisplaySettings(string dev, int mode, ref DEVMODE dm);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [StructLayout(LayoutKind.Sequential)] public struct POINT { public int X, Y; }
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor; public RECT rcWork; public uint dwFlags; }
  [StructLayout(LayoutKind.Sequential, CharSet=CharSet.Unicode)] public struct DEVMODE {
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmDeviceName;
    public short dmSpecVersion, dmDriverVersion, dmSize, dmDriverExtra; public int dmFields;
    public int dmPositionX, dmPositionY, dmDisplayOrientation, dmDisplayFixedOutput;
    public short dmColor, dmDuplex, dmYResolution, dmTTOption, dmCollate;
    [MarshalAs(UnmanagedType.ByValTStr, SizeConst=32)] public string dmFormName;
    public short dmLogPixels; public int dmBitsPerPel, dmPelsWidth, dmPelsHeight, dmDisplayFlags, dmDisplayFrequency;
    public int dmICMMethod, dmICMIntent, dmMediaType, dmDitherType, dmReserved1, dmReserved2, dmPanningWidth, dmPanningHeight;
  }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  /// La finestra principale di OrbitLR (titolo «OrbitLR»; non la linguetta sul bordo)
  public static IntPtr Main(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid || !IsWindowVisible(h)) return true;
      var sb = new System.Text.StringBuilder(256); GetWindowText(h, sb, 256); if (sb.ToString() == "OrbitLR") { found = h; return false; } return true; }, IntPtr.Zero);
    return found;
  }
  public static string Modes() {
    var seen = new System.Collections.Generic.List<string>(); var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    for (int i = 0; EnumDisplaySettings(null, i, ref dm); i++) { var m = dm.dmPelsWidth + "x" + dm.dmPelsHeight; if (!seen.Contains(m)) seen.Add(m); }
    return string.Join(" ", seen) + " (DEVMODE " + Marshal.SizeOf(typeof(DEVMODE)) + " byte)";
  }
  public static int SetRes(int w, int h) {
    var dm = new DEVMODE(); dm.dmSize = (short)Marshal.SizeOf(typeof(DEVMODE));
    if (!EnumDisplaySettings(null, -1, ref dm)) return -100;
    dm.dmPelsWidth = w; dm.dmPelsHeight = h; dm.dmFields = 0x80000 | 0x100000;
    return ChangeDisplaySettingsEx(null, ref dm, IntPtr.Zero, 0, IntPtr.Zero);
  }
  public static MONITORINFO Primary() { var p = new POINT(); var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(mi); GetMonitorInfo(MonitorFromPoint(p, 1), ref mi); return mi; }
}
"@
# Coordinate vere in pixel (non scalate da Windows)
[W]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

function Schermo() {
  $mi = [W]::Primary()
  $dpi = [W]::GetDpiForSystem()
  "schermo $($mi.rcMonitor.R - $mi.rcMonitor.L)x$($mi.rcMonitor.B - $mi.rcMonitor.T) · area utile $($mi.rcWork.R - $mi.rcWork.L)x$($mi.rcWork.B - $mi.rcWork.T) (in alto $($mi.rcWork.T)) · scala di sistema $([math]::Round($dpi / 96 * 100))%"
}

function Foto([string]$nome) {
  try {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.Location, [System.Drawing.Point]::Empty, $vs.Size)
    $bmp.Save((Join-Path $Out "$nome.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
  } catch { Log "foto $nome non riuscita: $_" }
}

function Ferma() {
  Get-Process orbitlr, realesrgan-ncnn-vulkan, yt-dlp, whisper-cli -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
}

$script:Exe = $null

# La finestra principale di OrbitLR: posizione e misura vere, dentro l'area utile o no
function Finestra([string]$etichetta) {
  $h = [IntPtr]::Zero
  foreach ($p in Get-Process orbitlr -ErrorAction SilentlyContinue) { $h = [W]::Main([uint32]$p.Id); if ($h -ne [IntPtr]::Zero) { break } }
  if ($h -eq [IntPtr]::Zero) { return "$etichetta · nessuna finestra «OrbitLR»" }
  $r = New-Object W+RECT
  [W]::DwmGetWindowAttribute($h, 9, [ref]$r, 16) | Out-Null
  $mi = New-Object W+MONITORINFO; $mi.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($mi)
  [W]::GetMonitorInfo([W]::MonitorFromWindow($h, 2), [ref]$mi) | Out-Null
  $dpi = [W]::GetDpiForWindow($h)
  $wk = $mi.rcWork
  $entra = ($r.L -ge $wk.L - 1) -and ($r.T -ge $wk.T - 1) -and ($r.R -le $wk.R + 1) -and ($r.B -le $wk.B + 1)
  $s = $dpi / 96
  "$etichetta · finestra $($r.L),$($r.T) $($r.R - $r.L)x$($r.B - $r.T) px ($([math]::Round(($r.R - $r.L) / $s))x$([math]::Round(($r.B - $r.T) / $s)) logici) · area utile $($wk.L),$($wk.T)-$($wk.R),$($wk.B) · scala $([math]::Round($s * 100))% · " + $(if ($entra) { "ENTRA" } else { "NON ENTRA (sporge di $([math]::Max(0, $r.B - $wk.B)) px in basso, $([math]::Max(0, $wk.T - $r.T)) px in alto)" })
}

# Avvia OrbitLR con le variabili date, aspetta, fotografa (anche a metà), dice se è viva
function Prova([string]$nome, [hashtable]$vars = @{}, [int]$attesa = 25, [scriptblock]$finito = $null) {
  Ferma
  Log "── $nome"
  $old = @{}
  foreach ($k in $vars.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
  $t0 = Get-Date
  $app = Start-Process -FilePath $script:Exe -PassThru
  foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) }
  Start-Sleep -Seconds 6
  Foto "$nome-6s"
  # Cosa fa mentre si aspetta: i processi figli (prove dei codificatori, motori)
  $figli = Get-CimInstance Win32_Process -Filter "ParentProcessId=$($app.Id)" -ErrorAction SilentlyContinue | ForEach-Object { $_.Name }
  Log "$nome · figli a 6 s: $(($figli | Group-Object | ForEach-Object { "$($_.Name)×$($_.Count)" }) -join ', ')"
  $fatto = $false
  for ($i = 6; $i -lt $attesa; $i += 3) {
    Start-Sleep -Seconds 3
    if ($finito -and (& $finito)) { $fatto = $true; break }
    if (-not (Get-Process -Id $app.Id -ErrorAction SilentlyContinue)) { break }
  }
  $p = Get-Process -Id $app.Id -ErrorAction SilentlyContinue
  if ($p) { $mh = [W]::Main([uint32]$p.Id); if ($mh -ne [IntPtr]::Zero) { [W]::SetForegroundWindow($mh) | Out-Null; Start-Sleep -Milliseconds 600 } }
  Foto $nome
  $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds)
  $vivo = if ($p) { "VIVA dopo $sec s (memoria $([math]::Round($p.WorkingSet64 / 1MB)) MB, WebView2 $((Get-Process msedgewebview2 -ErrorAction SilentlyContinue).Count) processi)" } else { "CHIUSA da sola (codice $($app.ExitCode)) dopo $sec s" }
  Note "${nome}: $vivo · $(Finestra 'finestra')$(if ($finito) { if ($fatto) { ' · LAVORO RIUSCITO' } else { ' · LAVORO NON FINITO' } })"
  return $fatto
}

# ── Il computer
$os = Get-CimInstance Win32_OperatingSystem
$cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$gpu = (Get-CimInstance Win32_VideoController | ForEach-Object { $_.Name }) -join "; "
Note "macchina: $Nome"
Note "sistema: $($os.Caption) $($os.Version) build $($os.BuildNumber) · architettura $env:PROCESSOR_ARCHITECTURE ($($os.OSArchitecture))"
Note "processore: $($cpu.Name) · $($cpu.NumberOfLogicalProcessors) thread · memoria $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) GB"
Note "scheda video: $gpu"
Note "$(Schermo)"
Note "lingua: cultura $((Get-Culture).Name) · interfaccia $((Get-UICulture).Name) · utente $env:USERNAME · amministratore $(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator))"
$wv = (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -ErrorAction SilentlyContinue).pv
Note "WebView2: $(if ($wv) { $wv } else { 'non trovato nel registro' })"

# ── Installazione come da internet, per l'utente, senza amministratore
New-Item -ItemType Directory -Force -Path C:\Prova | Out-Null
Copy-Item $Setup C:\Prova\OrbitLR-Setup.exe -Force
Set-Content -Path C:\Prova\OrbitLR-Setup.exe -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://github.com/LR-apps609/OrbitLR/releases/" -Encoding ascii
Log "Zone.Identifier: $((Get-Content C:\Prova\OrbitLR-Setup.exe -Stream Zone.Identifier) -join ' | ')"
Set-Culture it-IT
$dove = Join-Path $env:LOCALAPPDATA "OrbitLR"
Log "installo senza amministratore (runas /trustlevel:0x20000)"
$t0 = Get-Date
& runas.exe /trustlevel:0x20000 "C:\Prova\OrbitLR-Setup.exe /S" 2>&1 | ForEach-Object { Log "runas: $_" }
$modo = "senza amministratore (runas /trustlevel)"
for ($i = 0; $i -lt 60 -and -not (Test-Path "$dove\orbitlr.exe"); $i++) {
  Start-Sleep -Seconds 3
  if ($i -eq 5) { Foto "installazione-15s" }
}
if (-not (Test-Path "$dove\orbitlr.exe")) {
  Foto "installazione-bloccata"
  Log "runas non ha installato in 3 minuti: provo con Start-Process (stesso utente, il computer di GitHub è amministratore)"
  Get-Process OrbitLR-Setup -ErrorAction SilentlyContinue | Stop-Process -Force
  $modo = "Start-Process /S (utente amministratore: runas non ha funzionato)"
  $inst = Start-Process C:\Prova\OrbitLR-Setup.exe -ArgumentList "/S" -PassThru
  if (-not $inst.WaitForExit(300000)) { Foto "installazione-bloccata-2"; Log "installazione ancora ferma dopo 5 minuti"; $inst | Stop-Process -Force }
}
# Aspetta che l'installazione finisca davvero (l'exe c'è prima della fine)
for ($i = 0; $i -lt 40 -and (Get-Process OrbitLR-Setup -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 3 }
$script:Exe = Get-ChildItem $dove -Filter orbitlr.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
if (-not $script:Exe) { $script:Exe = Get-ChildItem $env:LOCALAPPDATA, $env:ProgramFiles -Filter orbitlr.exe -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
Note "installazione: $modo · $([math]::Round(((Get-Date) - $t0).TotalSeconds)) s · $(if ($script:Exe) { $script:Exe } else { 'NON INSTALLATA' })"
if (-not $script:Exe) { Foto "schermo-senza-app"; exit 1 }
$uninst = Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { $_.DisplayName -like "OrbitLR*" } | Select-Object -First 1
Note "registrata per l'utente: $(if ($uninst) { "$($uninst.DisplayName) $($uninst.DisplayVersion)" } else { 'no' }) · clic destro «Apri con OrbitLR»: $(Test-Path 'HKCU:\Software\Classes\*\shell\OrbitLR')"
$motori = Join-Path (Split-Path $script:Exe) "motori"
$ff = Join-Path $motori "ffmpeg.exe"

# ── File di prova in cartelle con accenti e spazi (come C:\Users\Nicolò De Santis\…)
$casa = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Nicolò De Santis\Prove è à ù"
New-Item -ItemType Directory -Force -Path $casa | Out-Null
$tmpAcc = "C:\Temp Nicolò\Tmp è"
New-Item -ItemType Directory -Force -Path $tmpAcc | Out-Null
& $ff -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=8" -f lavfi -i "sine=frequency=440:duration=8" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$casa\Gita al lago è.mp4" 2>&1 | Out-Null
if (-not (Test-Path "$casa\Gita al lago è.mp4")) { & $ff -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=8" -f lavfi -i "sine=frequency=440:duration=8" -c:v mpeg4 -q:v 3 -c:a aac -shortest "$casa\Gita al lago è.mp4" 2>&1 | Out-Null }
& $ff -hide_banner -loglevel error -y -f lavfi -i "color=c=white:s=600x400" -vf "drawbox=x=60:y=50:w=480:h=300:color=0x1E5078:t=fill,drawbox=x=225:y=125:w=150:h=150:color=0xF0B432:t=fill" -frames:v 1 "$casa\Logo piccolo è.png" 2>&1 | Out-Null
Log "file di prova: $((Get-ChildItem $casa | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ' · ')"
$accenti = @{ TEMP = $tmpAcc; TMP = $tmpAcc; WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--lang=it" }

# ── 1. Primo avvio in italiano: benvenuto, prove dei codificatori, nessun clic (come chi aspetta)
Prova "1-primo-avvio-it" $accenti 60 | Out-Null

# ── 2. Un lavoro vero su un file in una cartella con accenti (comprimi un video)
Prova "2-video-accenti" ($accenti + @{ ORBIT_PROVA_FILE = "$casa\Gita al lago è.mp4"; ORBIT_PROVA_SCHEDA = "video"; ORBIT_PROVA_AZIONE = "vcompress"; ORBIT_PROVA_PARAMETRO = "best" }) 120 { [bool](Get-ChildItem $casa -Filter "Gita al lago è (*).mp4" -ErrorAction SilentlyContinue) } | Out-Null
Log "file creati: $((Get-ChildItem $casa | ForEach-Object Name) -join ' · ')"

# ── 3. Vettoriale di un logo piccolo: scarica il motore dell'IA (45 MB) e usa la scheda video (Vulkan)
$ok = Prova "3-vettoriale-piccolo" ($accenti + @{ ORBIT_PROVA_FILE = "$casa\Logo piccolo è.png"; ORBIT_PROVA_SCHEDA = "image"; ORBIT_PROVA_AZIONE = "vector"; ORBIT_PROVA_PARAMETRO = "auto" }) 420 { [bool](Get-ChildItem $casa -Filter "Logo piccolo è (*).svg" -ErrorAction SilentlyContinue) }
$ia = Get-Process realesrgan-ncnn-vulkan -ErrorAction SilentlyContinue
Log "vettoriale: $(if ($ok) { 'SVG creato' } else { 'nessun SVG in 7 minuti' }) · motore IA ancora acceso: $([bool]$ia) · modelli: $((Get-ChildItem "$env:LOCALAPPDATA\it.ledion.orbitlr\modelli" -Recurse -ErrorAction SilentlyContinue | Measure-Object).Count) file"

# ── 4. In inglese
Set-Culture en-US
Prova "4-inglese" @{} 20 | Out-Null
Set-Culture it-IT

# ── 5. Scala della pagina con WebView2 (solo il contenuto, non la finestra)
foreach ($f in "1.25", "1.5", "1.75", "2") {
  Prova "5-webview2-scala-$f" @{ WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--lang=it --force-device-scale-factor=$f" } 18 | Out-Null
}

# ── 6. Risoluzioni dello schermo (se la scheda video del computer di prova le accetta)
Note "risoluzioni possibili: $([W]::Modes())"
$cmd = Get-Command Set-DisplayResolution -ErrorAction SilentlyContinue
Note "Set-DisplayResolution: $(if ($cmd) { 'c''è' } else { 'non c''è' })"
$prima = [W]::Primary(); $pw = $prima.rcMonitor.R - $prima.rcMonitor.L; $ph = $prima.rcMonitor.B - $prima.rcMonitor.T
foreach ($res in "1920x1080", "1366x768", "1280x720", "1280x1024") {
  $w, $hh = $res.Split("x") | ForEach-Object { [int]$_ }
  $r = [W]::SetRes($w, $hh)
  if ($r -ne 0 -and $cmd) { try { Set-DisplayResolution -Width $w -Height $hh -Force -ErrorAction Stop; $r = 0 } catch { $r = "Set-DisplayResolution: $_" } }
  Start-Sleep -Seconds 3
  Note "risoluzione ${res}: $(if ($r -eq 0) { 'cambiata' } else { "non accettata (codice $r)" }) · $(Schermo)"
  if ($r -eq 0) { Prova "6-risoluzione-$res" @{ WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--lang=it" } 15 | Out-Null }
}
[W]::SetRes($pw, $ph) | Out-Null
# ── 7. Scala di Windows (125–200%) senza uscire: SPI_SETLOGICALDPIOVERRIDE, relativa alla scala consigliata
$base = 0; [W]::SpiGet(0x9E, 0, [ref]$base, 0) | Out-Null
Note "scala: passo attuale $base rispetto a quella consigliata"
foreach ($passo in 1, 2, 3, 4) {
  $okSet = [W]::SpiSet(0x9F, $passo, [IntPtr]::Zero, 1)
  Start-Sleep -Seconds 3
  Note "scala passo +${passo}: SystemParametersInfo $okSet · $(Schermo)"
  Prova "7-scala-passo$passo" @{ WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--lang=it" } 15 | Out-Null
}
[W]::SpiSet(0x9F, $base, [IntPtr]::Zero, 1) | Out-Null
Ferma

# ── Registri: cartelle dell'app, rapporti di arresto di WebView2, errori di Windows
$dati = "$env:LOCALAPPDATA\it.ledion.orbitlr"
Get-ChildItem $dati, "$env:APPDATA\it.ledion.orbitlr" -Recurse -Depth 2 -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch "EBWebView\\Default\\(Cache|Code Cache|GPUCache)" } | ForEach-Object { "$($_.FullName) $($_.Length)" } | Set-Content (Join-Path $Out "cartelle-app.txt") -Encoding utf8
$crash = Get-ChildItem $dati -Recurse -Filter *.dmp -ErrorAction SilentlyContinue
Note "rapporti di arresto WebView2: $(($crash | Measure-Object).Count)"
Get-WinEvent -FilterHashtable @{ LogName = "Application"; Level = 1, 2; StartTime = (Get-Date).AddHours(-2) } -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -match "orbitlr|msedgewebview2|ffmpeg|realesrgan|OrbitLR" } | Select-Object -First 20 |
  ForEach-Object { "$($_.TimeCreated) $($_.ProviderName) $($_.Id): $(($_.Message -split "`n" | Select-Object -First 6) -join ' ')" } | Set-Content (Join-Path $Out "errori-windows.txt") -Encoding utf8
Note "errori di Windows su OrbitLR/WebView2: $((Get-Content (Join-Path $Out 'errori-windows.txt') -ErrorAction SilentlyContinue | Measure-Object).Count)"
Get-ChildItem $Out | ForEach-Object { Log "$($_.Name) $($_.Length)" }
