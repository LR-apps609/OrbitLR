# Tester20 · Windows · funzioni comuni agli script dei profili (pwsh 7).
# Da includere con: . "$PSScriptRoot\comune.ps1"  (servono $Out e $Profilo già impostati)
$ErrorActionPreference = "Continue"
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$script:T0 = Get-Date

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
if (-not ("T20W" -as [type])) {
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class T20W {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] public static extern bool PrintWindow(IntPtr h, IntPtr hdc, uint f);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
  [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
  [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr h, int id);
  [DllImport("user32.dll")] public static extern bool AllowSetForegroundWindow(int pid);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  public static IntPtr Main(uint pid) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid || !IsWindowVisible(h)) return true;
      var sb = new System.Text.StringBuilder(256); GetWindowText(h, sb, 256); if (sb.ToString() == "OrbitLR") { found = h; return false; } return true; }, IntPtr.Zero);
    return found;
  }
  public static string Title(IntPtr h) { var sb = new System.Text.StringBuilder(256); GetWindowText(h, sb, 256); return sb.ToString(); }
  public static void Keys(byte[] down) {
    foreach (var k in down) keybd_event(k, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(80);
    for (int i = down.Length - 1; i >= 0; i--) keybd_event(down[i], 0, 2, UIntPtr.Zero);
  }
}
"@
}
[T20W]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

# ── Diario ed esito (parte-<nome>.json, unita poi in esito.json)
$script:T20E = [ordered]@{ passi_fatti = 0; passati = 0; non_eseguiti = [System.Collections.ArrayList]::new(); bug = [System.Collections.ArrayList]::new(); confuso = [System.Collections.ArrayList]::new(); note = [System.Collections.ArrayList]::new() }
function Log([string]$m) { $l = "$(Get-Date -Format HH:mm:ss) [+$([int]((Get-Date) - $script:T0).TotalSeconds)s] $m"; Write-Host $l; Add-Content -Path (Join-Path $Out "diario.txt") -Value $l -Encoding utf8 }
function Passo([string]$cosa, $ok, [string]$det = "") {
  $ok = [bool]$ok
  $script:T20E.passi_fatti++; if ($ok) { $script:T20E.passati++ }
  Log "PASSO $(if ($ok) { 'OK' } else { 'NO' }) · $cosa$(if ($det) { " · $det" })"
  return $ok
}
function Bug([string]$titolo, [string]$gravita, [string[]]$passi, [string]$atteso, [string]$visto, [string]$prova) {
  [void]$script:T20E.bug.Add([ordered]@{ titolo = $titolo; gravita = $gravita; passi = @($passi); atteso = $atteso; visto = $visto; prova = $prova })
  Log "BUG [$gravita] $titolo · $visto"
  Write-Host "::warning::BUG [$gravita] $titolo"
}
function NonEseguito([string]$cosa, [string]$perche) { [void]$script:T20E.non_eseguiti.Add([ordered]@{ cosa = $cosa; perche = $perche }); Log "NON ESEGUITO $cosa · $perche" }
function Confuso([string]$cosa, [string]$perche) { [void]$script:T20E.confuso.Add([ordered]@{ cosa = $cosa; perche = $perche }); Log "CONFUSO $cosa · $perche" }
function Nota([string]$t) { [void]$script:T20E.note.Add($t); Log "NOTA $t" }
function Salva([string]$nome) {
  $script:T20E | ConvertTo-Json -Depth 8 | Set-Content (Join-Path $Out "parte-$nome.json") -Encoding utf8
  Log "salvato parte-$nome.json ($($script:T20E.passati)/$($script:T20E.passi_fatti) passi, $($script:T20E.bug.Count) bug)"
}

# ── Foto della finestra di OrbitLR (PrintWindow) o dello schermo
function FinestraApp() {
  foreach ($p in Get-Process orbitlr -ErrorAction SilentlyContinue) { $h = [T20W]::Main([uint32]$p.Id); if ($h -ne [IntPtr]::Zero) { return $h } }
  return [IntPtr]::Zero
}
function Foto([string]$nome) {
  $file = Join-Path $Out "$nome.png"
  $h = FinestraApp
  if ($h -ne [IntPtr]::Zero) {
    try {
      $r = New-Object T20W+RECT; [T20W]::GetWindowRect($h, [ref]$r) | Out-Null
      $bmp = New-Object System.Drawing.Bitmap ([math]::Max(1, $r.R - $r.L)), ([math]::Max(1, $r.B - $r.T))
      $g = [System.Drawing.Graphics]::FromImage($bmp); $dc = $g.GetHdc()
      $ok = [T20W]::PrintWindow($h, $dc, 2); $g.ReleaseHdc($dc)
      if ($ok) { $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png) }
      $g.Dispose(); $bmp.Dispose()
      if ($ok) { return $file }
    } catch { Log "foto finestra $nome non riuscita: $_" }
  }
  try {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.Location, [System.Drawing.Point]::Empty, $vs.Size)
    $bmp.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
  } catch { Log "foto $nome non riuscita: $_" }
  return $file
}

# ── Testo dentro una foto (OCR di Windows, con Windows PowerShell 5.1). Restituisce le righe lette, "" se l'OCR non c'è.
$script:OcrOk = $null
function Ocr([string]$png) {
  if (-not (Test-Path $png)) { return "" }
  $txt = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "ocr.ps1") -Png $png 2>&1 | Out-String
  if ($txt -match "OCR-NON-DISPONIBILE") { if ($null -eq $script:OcrOk) { Nota "OCR di Windows non disponibile su questo computer: $($txt.Trim() -replace '\s+', ' ' | Select-Object -First 1)" }; $script:OcrOk = $false; return "" }
  $script:OcrOk = $true
  $t = ($txt -replace "`r", "").Trim()
  Set-Content -Path ($png -replace "\.png$", ".ocr.txt") -Value $t -Encoding utf8
  return $t
}

# ── L'installazione (come scripts dispositivo-windows.ps1: scaricata da internet, per l'utente, senza amministratore)
$script:Exe = $null
function Installa([string]$Setup) {
  New-Item -ItemType Directory -Force -Path C:\Prova | Out-Null
  Copy-Item $Setup C:\Prova\OrbitLR-Setup.exe -Force
  Set-Content -Path C:\Prova\OrbitLR-Setup.exe -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://github.com/LR-apps609/OrbitLR/releases/" -Encoding ascii
  $dove = Join-Path $env:LOCALAPPDATA "OrbitLR"
  $t0 = Get-Date
  Log "installo senza amministratore (runas /trustlevel:0x20000, /S)"
  & runas.exe /trustlevel:0x20000 "C:\Prova\OrbitLR-Setup.exe /S" 2>&1 | ForEach-Object { Log "runas: $_" }
  $modo = "runas /trustlevel (senza amministratore)"
  for ($i = 0; $i -lt 60 -and -not (Test-Path "$dove\orbitlr.exe"); $i++) { Start-Sleep -Seconds 3 }
  if (-not (Test-Path "$dove\orbitlr.exe")) {
    Foto "installazione-ferma" | Out-Null
    Log "runas non ha installato in 3 minuti: Start-Process /S (file sbloccato)"
    Get-Process OrbitLR-Setup -ErrorAction SilentlyContinue | Stop-Process -Force
    Unblock-File C:\Prova\OrbitLR-Setup.exe -ErrorAction SilentlyContinue
    $modo = "Start-Process /S (utente amministratore, runas non ha funzionato)"
    $inst = Start-Process C:\Prova\OrbitLR-Setup.exe -ArgumentList "/S" -PassThru
    if (-not $inst.WaitForExit(300000)) { $inst | Stop-Process -Force }
  }
  for ($i = 0; $i -lt 40 -and (Get-Process OrbitLR-Setup -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 3 }
  $script:Exe = Get-ChildItem $dove -Filter orbitlr.exe -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
  $script:InstSec = [math]::Round(((Get-Date) - $t0).TotalSeconds)
  $script:InstModo = $modo
  Log "installazione: $modo · $($script:InstSec) s · $(if ($script:Exe) { $script:Exe } else { 'NON INSTALLATA' })"
  if ($script:Exe) {
    $script:Motori = Join-Path (Split-Path $script:Exe) "motori"
    $script:Ff = Join-Path $script:Motori "ffmpeg.exe"
    $script:Fp = Join-Path $script:Motori "ffprobe.exe"
  }
  return $script:Exe
}

function Ferma() {
  Get-Process orbitlr, realesrgan-ncnn-vulkan, yt-dlp, whisper-cli -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Get-CimInstance Win32_Process -Filter "Name='ffmpeg.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -like "*OrbitLR*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
  for ($i = 0; $i -lt 20 -and (Get-Process orbitlr -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
  Start-Sleep -Seconds 1
}

# Chiude OrbitLR come una persona (✕): se dopo 8 s è ancora aperta (domanda nella pagina, non visibile agli script), la si ferma.
function ChiudiBene() {
  $p = Get-Process orbitlr -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $p) { return "già chiusa" }
  $p.CloseMainWindow() | Out-Null
  for ($i = 0; $i -lt 16; $i++) { Start-Sleep -Milliseconds 500; if (-not (Get-Process -Id $p.Id -ErrorAction SilentlyContinue)) { return "chiusa con la ✕ in $([math]::Round($i * 0.5 + 0.5, 1)) s" } }
  Foto "chiusura-ferma" | Out-Null
  Ferma
  return "non chiusa con la ✕ in 8 s (forse una domanda nella pagina): fermata"
}

# Avvia OrbitLR con le variabili date (ORBIT_PROVA_*: file, scheda, azione, parametro, come Tools/dispositivo-windows.ps1).
# $Finito: blocco che dice se il lavoro è finito. -Resta: non chiude l'app alla fine.
function Avvia([string]$nome, [hashtable]$vars = @{}, [int]$attesa = 30, [scriptblock]$finito = $null, [switch]$Resta, [string[]]$argomenti = @()) {
  Ferma
  Log "── avvio «$nome»"
  $vars = @{ WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--lang=it" } + $vars
  $old = @{}
  foreach ($k in $vars.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
  $t0 = Get-Date
  $app = if ($argomenti.Count) { Start-Process -FilePath $script:Exe -ArgumentList $argomenti -PassThru } else { Start-Process -FilePath $script:Exe -PassThru }
  foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) }
  $fin = $null; $finestra = $null; $morta = $false
  while (((Get-Date) - $t0).TotalSeconds -lt $attesa) {
    Start-Sleep -Milliseconds 500
    if (-not $finestra -and [T20W]::Main([uint32]$app.Id) -ne [IntPtr]::Zero) { $finestra = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1) }
    if ($finito -and (& $finito)) { $fin = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1); break }
    if (-not (Get-Process -Id $app.Id -ErrorAction SilentlyContinue)) { $morta = $true; break }
  }
  Start-Sleep -Milliseconds 800
  $p = Get-Process -Id $app.Id -ErrorAction SilentlyContinue
  if ($p) { $mh = [T20W]::Main([uint32]$p.Id); if ($mh -ne [IntPtr]::Zero) { [T20W]::SetForegroundWindow($mh) | Out-Null; Start-Sleep -Milliseconds 500 } }
  $foto = Foto $nome
  $hung = $false; if ($p) { $mh = [T20W]::Main([uint32]$p.Id); if ($mh -ne [IntPtr]::Zero) { $hung = [T20W]::IsHungAppWindow($mh) } }
  $res = [pscustomobject]@{ nome = $nome; viva = [bool]$p; bloccata = $hung; finestra_s = $finestra; finito_s = $fin; secondi = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1); foto = $foto; pid = $app.Id; codice = $(if (-not $p) { try { $app.ExitCode } catch { "?" } } else { $null }) }
  Log "«$nome»: $(if ($p) { 'VIVA' } else { "CHIUSA (codice $($res.codice))" }) · finestra a $finestra s · lavoro finito: $(if ($fin) { "$fin s" } else { 'no' })$(if ($hung) { ' · NON RISPONDE' })"
  if (-not $Resta) { Ferma }
  return $res
}

# ── File di prova con l'ffmpeg dell'app (niente libx264: h264_mf o mpeg4)
function FF([string[]]$a) { & $script:Ff -hide_banner -loglevel error -y @a 2>&1 | ForEach-Object { Log "ffmpeg: $_" } }
function Video([string]$path, [int]$sec = 8, [string]$size = "1280x720", [int]$fps = 30, [string]$extra = "") {
  FF @("-f", "lavfi", "-i", "testsrc2=size=$($size):rate=$($fps):duration=$sec", "-f", "lavfi", "-i", "sine=frequency=440:duration=$sec", "-c:v", "h264_mf", "-b:v", "12M", "-pix_fmt", "nv12", "-c:a", "aac", "-shortest", $path)
  if (-not (Test-Path $path) -or (Get-Item $path).Length -lt 1000) { FF @("-f", "lavfi", "-i", "testsrc2=size=$($size):rate=$($fps):duration=$sec", "-f", "lavfi", "-i", "sine=frequency=440:duration=$sec", "-c:v", "mpeg4", "-q:v", "2", "-c:a", "aac", "-shortest", $path) }
  return (Test-Path $path)
}
function Immagine([string]$path, [string]$size = "1600x1200") { FF @("-f", "lavfi", "-i", "testsrc2=size=$size", "-frames:v", "1", $path); return (Test-Path $path) }
function Audio([string]$path, [int]$sec = 6) { FF @("-f", "lavfi", "-i", "sine=frequency=330:duration=$sec", "-ac", "2", "-ar", "44100", $path); return (Test-Path $path) }

# Un PDF vero (immagini JPEG + testo), scritto a mano (come Tests/Agenti/W02)
function NuovoPdf([string]$path, [int]$pagine = 3) {
  $tmp = Join-Path $env:TEMP "t20pdf"; New-Item -ItemType Directory -Force $tmp | Out-Null
  $jpgs = @(); for ($k = 1; $k -le $pagine; $k++) { FF @("-f", "lavfi", "-i", "testsrc2=size=1500x1000", "-frames:v", "1", "-q:v", "1", "$tmp\pag$k.jpg"); $jpgs += "$tmp\pag$k.jpg" }
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
  return (Test-Path $path)
}

# Informazioni di un file multimediale (ffprobe dell'app)
function Probe([string]$path) {
  if (-not (Test-Path -LiteralPath $path)) { return $null }
  $j = & $script:Fp -v error -show_streams -show_format -of json $path 2>$null | Out-String
  try { return ($j | ConvertFrom-Json) } catch { return $null }
}
function Rotazione($pr) {
  $v = $pr.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
  if (-not $v) { return 0 }
  $r = 0
  if ($v.tags -and $v.tags.rotate) { $r = [int]$v.tags.rotate }
  foreach ($sd in @($v.side_data_list)) { if ($sd -and $null -ne $sd.rotation) { $r = [int]$sd.rotation } }
  return $r
}
# Misura come si vede (con la rotazione)
function Vista($pr) {
  $v = $pr.streams | Where-Object { $_.codec_type -eq "video" } | Select-Object -First 1
  if (-not $v) { return "" }
  $r = [math]::Abs((Rotazione $pr) % 180)
  if ($r -eq 90) { return "$($v.height)x$($v.width)" } else { return "$($v.width)x$($v.height)" }
}

# Avanzi lasciati da OrbitLR in una cartella (file a metà)
function Avanzi([string]$dir) { @(Get-ChildItem -LiteralPath $dir -Force -Recurse -ErrorAction SilentlyContinue | Where-Object { $_.Name -like "*.orbitlr-*" -or $_.Name -like "*.parziale" }) }

# Errori di Windows (applicazione) su OrbitLR nelle ultime ore
function ErroriWindows() {
  @(Get-WinEvent -FilterHashtable @{ LogName = "Application"; Level = 1, 2; StartTime = $script:T0 } -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match "orbitlr|msedgewebview2|ffmpeg|OrbitLR" } | Select-Object -First 10 |
    ForEach-Object { "$($_.TimeCreated) $($_.ProviderName) $($_.Id): $(($_.Message -split "`n" | Select-Object -First 3) -join ' ')" })
}

function Info() {
  $os = Get-CimInstance Win32_OperatingSystem
  $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  Nota "computer: $($os.Caption) $($os.Version) · $env:PROCESSOR_ARCHITECTURE · $($cpu.Name) · $($cpu.NumberOfLogicalProcessors) thread · $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) GB · utente $env:USERNAME"
}

# Un messaggio per l'utente con dentro pezzi tecnici di Windows in inglese (os error, io:, codici)
function Tecnico([string]$dove, [string]$msg) {
  if ($msg -match "(?i)os error \d+|\bio: |An attempt was made|0x[0-9a-f]{6,}|panicked|ffmpeg exited") { Confuso "messaggio d'errore: $dove" "il messaggio per l'utente contiene un pezzo tecnico in inglese: «$msg»" }
}
