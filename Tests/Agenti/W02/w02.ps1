# W02 · OrbitLR per Windows 2.0 su windows-11-arm (e lo stesso su x64 per confrontare i tempi).
# 1) foto vere della finestra (non la schermata OOBE), 2) installazione e primo avvio con i tempi,
# 3) ogni scheda aperta e fotografata, 4) un lavoro per tipo (immagine, PDF, video, audio) dentro l'app, file controllati.
# Uso: pwsh -File w02.ps1 -Setup OrbitLR-Windows-2.0.0-Setup.exe -Out cartella
param([string]$Setup = "OrbitLR-Setup.exe", [string]$Out = "out")

$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$Cdp = Join-Path $PSScriptRoot "cdp.mjs"
$Res = [ordered]@{ tempi = [ordered]@{}; lavori = @(); note = @() }
function Log([string]$m) { $l = "$(Get-Date -Format HH:mm:ss.fff) $m"; Write-Host $l; Add-Content -Path (Join-Path $Out "diario.txt") -Value $l -Encoding utf8 }
function Salva() { $Res | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Out "risultati.json") -Encoding utf8 }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class U {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr dc, uint f);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern IntPtr GetShellWindow();
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern IntPtr OpenInputDesktop(uint f, bool inh, uint acc);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern bool GetUserObjectInformation(IntPtr h, int i, StringBuilder s, int n, out int need);
  [DllImport("kernel32.dll")] public static extern IntPtr OpenProcess(uint acc, bool inh, uint pid);
  [DllImport("kernel32.dll")] public static extern bool GetProcessInformation(IntPtr h, int cls, out PMI info, int size);
  [DllImport("kernel32.dll")] public static extern bool CloseHandle(IntPtr h);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  [StructLayout(LayoutKind.Sequential)] public struct PMI { public ushort Machine; public ushort Res; public uint Attr; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  public static string Text(IntPtr h) { var sb = new StringBuilder(256); GetWindowText(h, sb, 256); return sb.ToString(); }
  public static string Cls(IntPtr h) { var sb = new StringBuilder(256); GetClassName(h, sb, 256); return sb.ToString(); }
  public static string Windows() {
    var sb = new StringBuilder();
    EnumWindows((h, l) => { if (!IsWindowVisible(h)) return true; uint p; GetWindowThreadProcessId(h, out p); RECT r; GetWindowRect(h, out r);
      sb.AppendLine(p + " | " + Cls(h) + " | " + Text(h) + " | " + r.L + "," + r.T + " " + (r.R - r.L) + "x" + (r.B - r.T)); return true; }, IntPtr.Zero);
    return sb.ToString();
  }
  public static IntPtr Main(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid || !IsWindowVisible(h)) return true;
      if (Text(h) == "OrbitLR") { found = h; return false; } return true; }, IntPtr.Zero);
    return found;
  }
  public static string InputDesktop() {
    IntPtr d = OpenInputDesktop(0, false, 0x0001); if (d == IntPtr.Zero) return "nessuno (errore " + Marshal.GetLastWin32Error() + ")";
    var sb = new StringBuilder(256); int n; GetUserObjectInformation(d, 2, sb, 512, out n); return sb.ToString();
  }
  public static string Machine(uint pid) {
    IntPtr h = OpenProcess(0x1000, false, pid); if (h == IntPtr.Zero) return "?";
    PMI m; bool ok = GetProcessInformation(h, 9, out m, Marshal.SizeOf(typeof(PMI))); CloseHandle(h);
    if (!ok) return "? (GetProcessInformation)";
    return m.Machine == 0x8664 ? "x64" : m.Machine == 0xAA64 ? "arm64" : m.Machine == 0x14c ? "x86" : ("0x" + m.Machine.ToString("X"));
  }
}
"@
[U]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

function PeMachine([string]$f) {
  try {
    $b = [IO.File]::ReadAllBytes($f); $o = [BitConverter]::ToInt32($b, 0x3C); $m = [BitConverter]::ToUInt16($b, $o + 4)
    switch ($m) { 0x8664 { "x64" } 0xAA64 { "arm64" } 0x14c { "x86" } default { "0x{0:X}" -f $m } }
  } catch { "?" }
}

# Quanti colori diversi in un campione: una foto tutta nera/tutta uguale ne ha 1–2
function Colori([string]$png) {
  try {
    $bmp = [System.Drawing.Bitmap]::FromFile($png); $set = @{}
    for ($x = 0; $x -lt $bmp.Width; $x += [Math]::Max(1, [int]($bmp.Width / 40))) { for ($y = 0; $y -lt $bmp.Height; $y += [Math]::Max(1, [int]($bmp.Height / 40))) { $set[$bmp.GetPixel($x, $y).ToArgb()] = 1 } }
    $r = "$($bmp.Width)x$($bmp.Height), $($set.Count) colori"; $bmp.Dispose(); $r
  } catch { "non leggibile: $_" }
}

function FotoSchermo([string]$nome) {
  try {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.Location, [System.Drawing.Point]::Empty, $vs.Size)
    $p = Join-Path $Out "$nome.png"; $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
    Log "foto schermo $nome · $(Colori $p)"
  } catch { Log "foto schermo $nome non riuscita: $_" }
}

# Foto della sola finestra con PrintWindow (PW_RENDERFULLCONTENT): funziona anche se la finestra è coperta
function FotoFinestra([IntPtr]$h, [string]$nome) {
  if ($h -eq [IntPtr]::Zero) { Log "foto finestra ${nome}: nessuna finestra"; return }
  try {
    $r = New-Object U+RECT; [U]::GetWindowRect($h, [ref]$r) | Out-Null
    $w = $r.R - $r.L; $hh = $r.B - $r.T
    $bmp = New-Object System.Drawing.Bitmap $w, $hh
    $g = [System.Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc()
    $ok = [U]::PrintWindow($h, $dc, 2); $g.ReleaseHdc($dc)
    $p = Join-Path $Out "$nome.png"; $bmp.Save($p, [System.Drawing.Imaging.ImageFormat]::Png); $g.Dispose(); $bmp.Dispose()
    Log "foto finestra $nome · PrintWindow $ok · $(Colori $p)"
  } catch { Log "foto finestra $nome non riuscita: $_" }
}

function FotoCdp([string]$nome) {
  $p = Join-Path $Out "$nome.png"
  $r = & node $Cdp shot $p 2>&1
  if (Test-Path $p) { Log "foto DevTools $nome · $(Colori $p)" } else { Log "foto DevTools $nome non riuscita: $r" }
}

function Ferma() {
  Get-Process orbitlr, realesrgan-ncnn-vulkan, yt-dlp, whisper-cli -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
}

# ── 0. Il computer e la schermata OOBE
$os = Get-CimInstance Win32_OperatingSystem; $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
$Res.computer = "$($os.Caption) $($os.Version) · $env:PROCESSOR_ARCHITECTURE · $($cpu.Name) · $($cpu.NumberOfLogicalProcessors) thread · $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) GB"
Log "computer: $($Res.computer)"
Log "schermo: $([System.Windows.Forms.Screen]::PrimaryScreen.Bounds) · desktop di input: $([U]::InputDesktop()) · sessione $((Get-Process -Id $PID).SessionId)"
Log "explorer: $((Get-Process explorer -ErrorAction SilentlyContinue | ForEach-Object { $_.Id }) -join ',') · shell window $([U]::GetShellWindow())"
$sospetti = "FirstLogonAnim", "WWAHost", "UserOOBEBroker", "CloudExperienceHostBroker", "oobe*", "msoobe", "LogonUI", "ShellExperienceHost", "StartMenuExperienceHost", "SearchHost"
Log "processi interessanti: $((Get-Process $sospetti -ErrorAction SilentlyContinue | ForEach-Object { "$($_.Name)#$($_.Id)" }) -join ' ')"
[U]::Windows() | Set-Content (Join-Path $Out "finestre-prima.txt") -Encoding utf8
$fg = [U]::GetForegroundWindow(); $fp = 0; [U]::GetWindowThreadProcessId($fg, [ref]$fp) | Out-Null
Log "in primo piano: '$([U]::Text($fg))' classe $([U]::Cls($fg)) processo $((Get-Process -Id $fp -ErrorAction SilentlyContinue).Name)"
FotoSchermo "00-schermo-iniziale"

# Via la schermata del primo accesso: si chiudono i processi che la mostrano, poi si aspetta explorer
foreach ($n in "FirstLogonAnim", "WWAHost", "UserOOBEBroker", "CloudExperienceHostBroker", "msoobe") {
  $ps = Get-Process $n -ErrorAction SilentlyContinue
  if ($ps) { Log "chiudo $n ($($ps.Id -join ','))"; $ps | Stop-Process -Force -ErrorAction SilentlyContinue }
}
Start-Sleep -Seconds 3
if (-not (Get-Process explorer -ErrorAction SilentlyContinue)) { Log "explorer non c'è: lo avvio"; Start-Process explorer.exe; Start-Sleep -Seconds 8 }
for ($i = 0; $i -lt 20 -and [U]::GetShellWindow() -eq [IntPtr]::Zero; $i++) { Start-Sleep -Seconds 1 }
(New-Object -ComObject Shell.Application).MinimizeAll(); Start-Sleep -Seconds 1
[U]::Windows() | Set-Content (Join-Path $Out "finestre-dopo.txt") -Encoding utf8
$fg = [U]::GetForegroundWindow(); $fp = 0; [U]::GetWindowThreadProcessId($fg, [ref]$fp) | Out-Null
Log "dopo la pulizia · in primo piano: '$([U]::Text($fg))' classe $([U]::Cls($fg)) processo $((Get-Process -Id $fp -ErrorAction SilentlyContinue).Name) · explorer $((Get-Process explorer -ErrorAction SilentlyContinue).Count)"
FotoSchermo "01-schermo-dopo-pulizia"

# ── 1. Installazione (per l'utente, silenziosa)
$t0 = Get-Date
$inst = Start-Process (Resolve-Path $Setup).Path -ArgumentList "/S" -PassThru
if (-not $inst.WaitForExit(300000)) { Log "installazione ferma dopo 5 minuti"; FotoSchermo "installazione-ferma"; $inst | Stop-Process -Force }
$Res.tempi.installazione_s = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
$Exe = Join-Path $env:LOCALAPPDATA "OrbitLR\orbitlr.exe"
if (-not (Test-Path $Exe)) { Log "NON INSTALLATA"; $Res.note += "installazione fallita"; Salva; exit 1 }
$Motori = Join-Path (Split-Path $Exe) "motori"; $Ff = Join-Path $Motori "ffmpeg.exe"
$Res.architettura = [ordered]@{ "orbitlr.exe" = (PeMachine $Exe) }
Get-ChildItem $Motori -Filter *.exe -ErrorAction SilentlyContinue | ForEach-Object { $Res.architettura[$_.Name] = (PeMachine $_.FullName) }
Log "installata in $($Res.tempi.installazione_s) s · architetture: $(($Res.architettura.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ' ')"
$uninst = Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { $_.DisplayName -like "OrbitLR*" } | Select-Object -First 1
$Res.versione = "$($uninst.DisplayName) $($uninst.DisplayVersion)"
Get-ChildItem (Split-Path $Exe) -Recurse | ForEach-Object { "$($_.FullName.Substring((Split-Path $Exe).Length)) $($_.Length)" } | Set-Content (Join-Path $Out "file-installati.txt") -Encoding utf8
Salva

# ── Avvio con DevTools; misura finestra e interfaccia pronta
$Base = @{ WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--remote-debugging-port=9222 --lang=it" }
# Anche come criterio di WebView2 (vale per l'exe, sopra quello che passa l'app)
$pol = "HKCU:\Software\Policies\Microsoft\Edge\WebView2\AdditionalBrowserArguments"
New-Item -Path $pol -Force | Out-Null
New-ItemProperty -Path $pol -Name "orbitlr.exe" -Value "--remote-debugging-port=9222" -PropertyType String -Force | Out-Null
function DiagCdp() {
  $cl = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CommandLine -notmatch '--type=' } | ForEach-Object { $_.CommandLine -replace [regex]::Escape($env:USERPROFILE), '~' }
  Log "WebView2 processo principale: $($cl -join ' ;; ')"
  Log "porta 9222: $((Get-NetTCPConnection -LocalPort 9222 -State Listen -ErrorAction SilentlyContinue | ForEach-Object { "$($_.LocalAddress) pid $($_.OwningProcess)" }) -join ', ')"
  $dap = Get-ChildItem "$env:LOCALAPPDATA\it.ledion.orbitlr" -Recurse -Filter DevToolsActivePort -ErrorAction SilentlyContinue | Select-Object -First 1
  Log "DevToolsActivePort: $(if ($dap) { (Get-Content $dap.FullName) -join ' ' } else { 'non c''è' })"
}
function Avvia([hashtable]$vars, [string]$nome, [switch]$Pronta) {
  Ferma
  $all = $Base + $vars; $old = @{}
  foreach ($k in $all.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $all[$k]) }
  $t0 = Get-Date; $t0ms = [DateTimeOffset]::Now.ToUnixTimeMilliseconds()
  $app = Start-Process -FilePath $Exe -PassThru
  foreach ($k in $all.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) }
  $h = [IntPtr]::Zero; $tw = $null
  for ($i = 0; $i -lt 600 -and $h -eq [IntPtr]::Zero; $i++) { $h = [U]::Main([uint32]$app.Id); if ($h -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 100 } }
  if ($h -ne [IntPtr]::Zero) { $tw = [math]::Round(((Get-Date) - $t0).TotalSeconds, 2) }
  $ready = if ($Pronta) { (& node $Cdp ready 30000 2>&1 | Select-Object -Last 1) } else { "" }
  $tu = if ("$ready" -match '^\d+$') { [math]::Round(([int64]$ready - $t0ms) / 1000, 2) } else { $null }
  $mach = [U]::Machine([uint32]$app.Id)
  $wv = Get-CimInstance Win32_Process -Filter "Name='msedgewebview2.exe'" -ErrorAction SilentlyContinue | Select-Object -First 1
  $wvm = if ($wv) { [U]::Machine([uint32]$wv.ProcessId) } else { "-" }
  Log "$nome · finestra dopo $tw s · interfaccia pronta dopo $tu s · orbitlr in esecuzione come $mach · WebView2 $wvm"
  if ($h -ne [IntPtr]::Zero) { [U]::ShowWindow($h, 9) | Out-Null; [U]::SetWindowPos($h, [IntPtr](-1), 0, 0, 0, 0, 0x0003) | Out-Null; [U]::SetForegroundWindow($h) | Out-Null }
  return [pscustomobject]@{ app = $app; h = $h; finestra_s = $tw; pronta_s = $tu; t0 = $t0; macchina = $mach; webview = $wvm }
}

# ── 2. Primo avvio (profilo nuovo) e secondo avvio
$a = Avvia @{} "primo-avvio" -Pronta
DiagCdp
$Res.tempi.primo_avvio_finestra_s = $a.finestra_s; $Res.tempi.primo_avvio_pronta_s = $a.pronta_s
$Res.esecuzione = "orbitlr.exe come $($a.macchina) · msedgewebview2 come $($a.webview)"
Start-Sleep -Seconds 3
FotoSchermo "02-primo-avvio-schermo"
FotoFinestra $a.h "02-primo-avvio-finestra"
FotoCdp "02-primo-avvio-devtools"
$Res.errori_primo_avvio = (& node $Cdp logs 2>&1 | Select-Object -Last 1)
Salva

$a = Avvia @{} "secondo-avvio" -Pronta
$Res.tempi.secondo_avvio_finestra_s = $a.finestra_s; $Res.tempi.secondo_avvio_pronta_s = $a.pronta_s
Start-Sleep -Seconds 2
FotoSchermo "03-secondo-avvio-schermo"
FotoFinestra $a.h "03-secondo-avvio-finestra"

# ── 3. Ogni scheda (clic sui pulsanti della barra laterale, foto di ognuna)
$sez = & node $Cdp sections (Join-Path $Out "schede") 2>&1 | Select-Object -Last 1
Log "schede: $sez"
try { $Res.schede = $sez | ConvertFrom-Json } catch { $Res.schede = "$sez" }
FotoFinestra $a.h "04-ultima-scheda-finestra"
Salva

# ── 4. File di prova (cartella con accenti e spazi)
$casa = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "Prove W02 è"
New-Item -ItemType Directory -Force -Path $casa | Out-Null
function Fai([string[]]$a) { $r = & $Ff -hide_banner -loglevel error -y @a 2>&1 | ForEach-Object { "$_" }; if ($LASTEXITCODE) { Log "ffmpeg ($LASTEXITCODE): $r" } }
$tf = Get-Date
Fai @("-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=8", "-f", "lavfi", "-i", "sine=frequency=440:duration=8", "-c:v", "libx264", "-pix_fmt", "yuv420p", "-c:a", "aac", "-shortest", "$casa\Gita al lago.mp4")
if (-not (Test-Path "$casa\Gita al lago.mp4")) { Fai @("-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=8", "-f", "lavfi", "-i", "sine=frequency=440:duration=8", "-c:v", "mpeg4", "-q:v", "3", "-c:a", "aac", "-shortest", "$casa\Gita al lago.mp4") }
Fai @("-f", "lavfi", "-i", "testsrc2=size=3000x2000", "-vf", "noise=alls=60:allf=t", "-frames:v", "1", "-q:v", "1", "$casa\Foto grande.jpg")
Fai @("-f", "lavfi", "-i", "sine=frequency=330:duration=30", "-f", "lavfi", "-i", "anoisesrc=d=30:a=0.05", "-filter_complex", "amix=inputs=2", "-ar", "44100", "-ac", "2", "$casa\Nota vocale.wav")
for ($k = 1; $k -le 3; $k++) { Fai @("-f", "lavfi", "-i", "testsrc2=size=1500x1000", "-frames:v", "1", "-q:v", "1", "$casa\pag$k.jpg") }
Copy-Item (Join-Path $PSScriptRoot "..\..\..\Windows\engine\tests\fixtures\iphone-gps.heic") "$casa\Dall iPhone.heic" -ErrorAction SilentlyContinue
$Res.tempi.fixture_ffmpeg_s = [math]::Round(((Get-Date) - $tf).TotalSeconds, 1)

# Un PDF vero di 3 pagine (immagini JPEG + testo), scritto a mano
function NuovoPdf([string]$path, [string[]]$jpgs) {
  $ms = New-Object IO.MemoryStream; $enc = [Text.Encoding]::ASCII; $off = @{}
  $W = { param($s) $b = $enc.GetBytes($s); $ms.Write($b, 0, $b.Length) }
  $n = $jpgs.Count
  & $W "%PDF-1.4`n"
  $off[1] = $ms.Position; & $W "1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj`n"
  $kids = (0..($n - 1) | ForEach-Object { "$(4 + 3 * $_) 0 R" }) -join ' '
  $off[2] = $ms.Position; & $W "2 0 obj << /Type /Pages /Kids [$kids] /Count $n >> endobj`n"
  $off[3] = $ms.Position; & $W "3 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj`n"
  for ($k = 0; $k -lt $n; $k++) {
    $p = 4 + 3 * $k; $c = $p + 1; $im = $p + 2
    $off[$p] = $ms.Position; & $W "$p 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] /Resources << /Font << /F1 3 0 R >> /XObject << /Im1 $im 0 R >> >> /Contents $c 0 R >> endobj`n"
    $s = "q 495 0 0 330 50 450 cm /Im1 Do Q BT /F1 24 Tf 50 380 Td (Pagina $($k + 1) prova OrbitLR) Tj ET"
    $off[$c] = $ms.Position; & $W "$c 0 obj << /Length $($s.Length) >> stream`n$s`nendstream endobj`n"
    $bytes = [IO.File]::ReadAllBytes($jpgs[$k])
    $off[$im] = $ms.Position; & $W "$im 0 obj << /Type /XObject /Subtype /Image /Width 1500 /Height 1000 /ColorSpace /DeviceRGB /BitsPerComponent 8 /Filter /DCTDecode /Length $($bytes.Length) >> stream`n"
    $ms.Write($bytes, 0, $bytes.Length); & $W "`nendstream endobj`n"
  }
  $tot = 3 + 3 * $n; $x = $ms.Position
  & $W "xref`n0 $($tot + 1)`n0000000000 65535 f `n"
  for ($i = 1; $i -le $tot; $i++) { & $W ("{0:D10} 00000 n `n" -f $off[$i]) }
  & $W "trailer << /Size $($tot + 1) /Root 1 0 R >>`nstartxref`n$x`n%%EOF`n"
  [IO.File]::WriteAllBytes($path, $ms.ToArray())
}
NuovoPdf "$casa\Contratto prova.pdf" @("$casa\pag1.jpg", "$casa\pag2.jpg", "$casa\pag3.jpg")
Remove-Item "$casa\pag*.jpg"
Get-ChildItem $casa | ForEach-Object { Log "fixture $($_.Name) $($_.Length) byte" }

function InfoMedia([string]$f) {
  $t = (& $Ff -hide_banner -i $f 2>&1 | ForEach-Object { "$_" }) -join "`n"
  $d = if ($t -match 'Duration: (\d+:\d+:[\d.]+)') { $Matches[1] } else { "?" }
  $st = ($t -split "`n" | Where-Object { $_ -match 'Stream #' } | ForEach-Object { ($_ -replace '^\s+', '') -replace ',? *\(default\)', '' }) -join ' || '
  "durata $d · $st"
}
function Verifica([string]$f) {
  $e = [IO.Path]::GetExtension($f).ToLower()
  if ($e -eq ".pdf") {
    $b = [IO.File]::ReadAllBytes($f); $txt = [Text.Encoding]::ASCII.GetString($b)
    $pag = ([regex]::Matches($txt, '/Type\s*/Page(?!s)')).Count
    return "PDF header '$($txt.Substring(0, 8).Trim())' · pagine (conteggio /Type /Page) $pag · $(if ($txt.Contains('%%EOF')) { 'con %%EOF' } else { 'SENZA %%EOF' })"
  }
  if ($e -in ".jpg", ".jpeg", ".png", ".bmp") {
    try { $i = [System.Drawing.Image]::FromFile($f); $r = "immagine $($i.Width)x$($i.Height) $($i.RawFormat.Guid -eq [System.Drawing.Imaging.ImageFormat]::Jpeg.Guid ? 'JPEG' : $i.PixelFormat)"; $i.Dispose(); return "$r · $(InfoMedia $f)" } catch { return "immagine NON leggibile: $_" }
  }
  return InfoMedia $f
}

# ── 4b. Se DevTools non risponde: ogni scheda aperta dalle variabili di prova, foto con PrintWindow
if ("$sez" -notmatch '^\{') {
  $perScheda = [ordered]@{ convert = "$casa\Foto grande.jpg"; image = "$casa\Foto grande.jpg"; video = "$casa\Gita al lago.mp4"; audio = "$casa\Nota vocale.wav"; pdf = "$casa\Contratto prova.pdf"; activity = "$casa\Foto grande.jpg"; auto = "$casa\Foto grande.jpg"; settings = "$casa\Foto grande.jpg"; help = "$casa\Foto grande.jpg" }
  $i = 10
  foreach ($k in $perScheda.Keys) {
    $a = Avvia @{ ORBIT_PROVA_FILE = $perScheda[$k]; ORBIT_PROVA_SCHEDA = $k } "scheda $k"
    Start-Sleep -Seconds 4
    if ($a.h -ne [IntPtr]::Zero) { [U]::SetForegroundWindow($a.h) | Out-Null; Start-Sleep -Milliseconds 300; [System.Windows.Forms.SendKeys]::SendWait("{ESC}"); Start-Sleep -Milliseconds 700 }
    FotoFinestra $a.h "$i-scheda-$k"
    $i++
  }
  FotoSchermo "19-schermo-ultima-scheda"
}

# ── 5. Un lavoro vero dentro l'app (variabili di prova ORBIT_PROVA_*): attesa del file nuovo, controllo
function Lavoro([string]$nome, [string]$file, [string]$scheda, [string]$azione, [string]$param, [int]$max = 180) {
  $prima = @(Get-ChildItem $casa -Recurse | ForEach-Object FullName)
  $a = Avvia @{ ORBIT_PROVA_FILE = $file; ORBIT_PROVA_SCHEDA = $scheda; ORBIT_PROVA_AZIONE = $azione; ORBIT_PROVA_PARAMETRO = $param } "lavoro $nome"
  $nuovi = @(); $fine = $null; $last = -1; $fermo = 0
  for ($i = 0; $i -lt $max * 4; $i++) {
    Start-Sleep -Milliseconds 250
    $nuovi = @(Get-ChildItem $casa -Recurse -File | Where-Object { $prima -notcontains $_.FullName -and $_.Length -gt 0 })
    $tot = ($nuovi | Measure-Object Length -Sum).Sum
    if ($nuovi.Count -and $tot -eq $last) { $fermo++ } else { $fermo = 0 }
    if ($fermo -ge 3) { $fine = (Get-Date).AddMilliseconds(-750); break }
    $last = if ($nuovi.Count) { $tot } else { -1 }
    if (-not (Get-Process -Id $a.app.Id -ErrorAction SilentlyContinue)) { Log "$nome · l'app si è chiusa da sola (codice $($a.app.ExitCode))"; break }
  }
  # il file è fermo da 750 ms: quel tempo è già tolto
  $sec = if ($fine) { [math]::Round(($fine - $a.t0).TotalSeconds, 2) } else { $null }
  Start-Sleep -Seconds 2
  FotoCdp "05-lavoro-$nome-devtools"
  FotoFinestra $a.h "05-lavoro-$nome-finestra"
  $err = (& node $Cdp logs 2>&1 | Select-Object -Last 1)
  $barra = (& node $Cdp eval "(document.querySelector('.resultbar, .result-bar, .rbar')?.innerText || [...document.querySelectorAll('.toast')].map(t=>t.innerText).join(' | ') || '').replace(/\s+/g,' ').slice(0,300)" 2>&1 | Select-Object -Last 1)
  $src = Get-Item $file
  $r = [ordered]@{ nome = $nome; azione = $azione; parametro = $param; sorgente = "$($src.Name) $($src.Length) byte · $(Verifica $file)"
    pronta_s = $a.pronta_s; file_pronto_dopo_avvio_s = $sec; lavoro_s = $(if ($sec -and $Res.tempi.secondo_avvio_pronta_s) { [math]::Round($sec - $Res.tempi.secondo_avvio_pronta_s, 2) } else { $null })
    uscite = @($nuovi | ForEach-Object { "$($_.FullName.Substring($casa.Length + 1)) $($_.Length) byte · $(Verifica $_.FullName)" }); barra = $barra; errori_console = $err }
  Log "LAVORO $nome · $(if ($nuovi.Count) { 'RIUSCITO' } else { 'NESSUN FILE' }) · $sec s dall'avvio ($($r.lavoro_s) s dopo l'interfaccia pronta) · $($r.uscite -join ' ;; ') · barra: $barra · errori: $err"
  $Res.lavori += $r; Salva
}

Lavoro "immagine-heic-jpg" "$casa\Dall iPhone.heic" "image" "to:jpg" ""
Lavoro "immagine-comprimi" "$casa\Foto grande.jpg" "image" "icompress" "best"
Lavoro "pdf-comprimi" "$casa\Contratto prova.pdf" "pdf" "pdfcompress" "medium"
Lavoro "pdf-in-png" "$casa\Contratto prova.pdf" "pdf" "to:png" ""
Lavoro "video-comprimi" "$casa\Gita al lago.mp4" "video" "vcompress" "best" 300
Lavoro "audio-mp3" "$casa\Nota vocale.wav" "audio" "to:mp3" ""
Lavoro "audio-livella" "$casa\Nota vocale.wav" "audio" "normalize" ""
Ferma

# ── Registri
$dati = "$env:LOCALAPPDATA\it.ledion.orbitlr"
Get-ChildItem $dati, "$env:APPDATA\it.ledion.orbitlr" -Recurse -Depth 2 -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch "EBWebView\\Default\\(Cache|Code Cache|GPUCache)" } | ForEach-Object { "$($_.FullName.Replace($env:USERPROFILE, '~')) $($_.Length)" } | Set-Content (Join-Path $Out "cartelle-app.txt") -Encoding utf8
Get-ChildItem $dati, "$env:APPDATA\it.ledion.orbitlr" -Recurse -Include *.log, *.txt -ErrorAction SilentlyContinue | Where-Object { $_.Length -lt 2MB -and $_.FullName -notmatch "EBWebView" } | ForEach-Object { Copy-Item $_.FullName (Join-Path $Out ("reg-" + $_.Name)) -ErrorAction SilentlyContinue }
$Res.dump_webview2 = (Get-ChildItem $dati -Recurse -Filter *.dmp -ErrorAction SilentlyContinue | Measure-Object).Count
Get-WinEvent -FilterHashtable @{ LogName = "Application"; Level = 1, 2; StartTime = (Get-Date).AddHours(-2) } -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -match "orbitlr|msedgewebview2|ffmpeg" } | Select-Object -First 20 |
  ForEach-Object { "$($_.TimeCreated) $($_.ProviderName) $($_.Id): $(($_.Message -split "`n" | Select-Object -First 6) -join ' ')" } | Set-Content (Join-Path $Out "errori-windows.txt") -Encoding utf8
Salva
# Le foto nel registro del lavoro (gli artifact non si possono scaricare da qui): JPEG piccoli in base64, a pezzi
$enc = [System.Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object { $_.MimeType -eq "image/jpeg" }
$ep = New-Object System.Drawing.Imaging.EncoderParameters 1
$ep.Param[0] = New-Object System.Drawing.Imaging.EncoderParameter ([System.Drawing.Imaging.Encoder]::Quality), ([long]62)
foreach ($f in Get-ChildItem $Out -Recurse -Filter *.png) {
  try {
    $img = [System.Drawing.Image]::FromFile($f.FullName); $k = [Math]::Min(1.0, 1044 / $img.Width)
    $bmp = New-Object System.Drawing.Bitmap $img, ([int]($img.Width * $k)), ([int]($img.Height * $k)); $img.Dispose()
    $ms = New-Object IO.MemoryStream; $bmp.Save($ms, $enc, $ep); $bmp.Dispose()
    $b64 = [Convert]::ToBase64String($ms.ToArray()); $n = [Math]::Ceiling($b64.Length / 6000)
    for ($i = 0; $i -lt $n; $i++) { Write-Host "W02IMG|$($f.Name)|$i|$n|$($b64.Substring($i * 6000, [Math]::Min(6000, $b64.Length - $i * 6000)))" }
  } catch { Log "foto $($f.Name) non pubblicata: $_" }
}
Log "fine"
