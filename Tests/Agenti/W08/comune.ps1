# W08 - funzioni comuni per le prove di carico di OrbitLR per Windows (2.0 installata).
# Solo caratteri ASCII: gira con Windows PowerShell 5.1.
$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$env:WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--lang=it"

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W8 {
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
  [DllImport("user32.dll")] public static extern bool IsHungAppWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern void keybd_event(byte k, byte s, uint f, UIntPtr e);
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
  public static int CountMain() {
    int n = 0;
    EnumWindows((h, l) => { if (!IsWindowVisible(h)) return true; var sb = new System.Text.StringBuilder(256); GetWindowText(h, sb, 256); if (sb.ToString() == "OrbitLR") n++; return true; }, IntPtr.Zero);
    return n;
  }
}
"@

$script:T0 = Get-Date
function Log([string]$m) { $l = "$(Get-Date -Format HH:mm:ss) [+$([int]((Get-Date) - $script:T0).TotalSeconds)s] $m"; Write-Host $l; Add-Content -Path (Join-Path $Out "diario.txt") -Value $l -Encoding utf8 }
function Esito([string]$nome, [string]$stato, [string]$det) {
  # stato: OK | BUG | INFO | NON-PROVATO
  $l = "ESITO|$nome|$stato|$det"
  Add-Content -Path (Join-Path $Out "esiti.txt") -Value $l -Encoding utf8
  if ($stato -eq "BUG") { Write-Host "::warning::$nome - $det" } else { Write-Host "::notice::$nome [$stato] - $det" }
  Log $l
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
  Get-Process orbitlr, ffmpeg, realesrgan-ncnn-vulkan -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  for ($i = 0; $i -lt 20 -and (Get-Process orbitlr, msedgewebview2 -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Milliseconds 500 }
  Start-Sleep -Seconds 1
}

function Installa() {
  New-Item -ItemType Directory -Force -Path C:\Prova | Out-Null
  $url = "https://github.com/LR-apps609/OrbitLR/releases/download/windows-anteprima/OrbitLR-Windows-2.0.0-Setup.exe"
  $ProgressPreference = "SilentlyContinue"
  Invoke-WebRequest -Uri $url -OutFile C:\Prova\OrbitLR-Setup.exe -UseBasicParsing
  Log "installazione scaricata: $((Get-Item C:\Prova\OrbitLR-Setup.exe).Length) byte"
  $p = Start-Process C:\Prova\OrbitLR-Setup.exe -ArgumentList "/S" -PassThru
  $p.WaitForExit(300000) | Out-Null
  for ($i = 0; $i -lt 40 -and (Get-Process OrbitLR-Setup -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 3 }
  $script:Exe = Join-Path $env:LOCALAPPDATA "OrbitLR\orbitlr.exe"
  if (-not (Test-Path $script:Exe)) { $script:Exe = Get-ChildItem $env:LOCALAPPDATA, $env:ProgramFiles -Filter orbitlr.exe -Recurse -Depth 2 -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName }
  if (-not $script:Exe) { Esito "installazione" "BUG" "orbitlr.exe non trovato dopo /S"; exit 1 }
  $script:FF = Join-Path (Split-Path $script:Exe) "motori\ffmpeg.exe"
  $script:FP = Join-Path (Split-Path $script:Exe) "motori\ffprobe.exe"
  $v = (Get-Item $script:Exe).VersionInfo
  Log "installata: $script:Exe versione file $($v.FileVersion) prodotto $($v.ProductVersion) - ffmpeg $(Test-Path $script:FF) - ffprobe $(Test-Path $script:FP)"
  # Esecuzioni automatiche della prima installazione (l'installatore NSIS di Tauri apre l'app alla fine?)
  Start-Sleep -Seconds 3
  Ferma
  $os = Get-CimInstance Win32_OperatingSystem; $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
  $script:NCPU = [Environment]::ProcessorCount
  Log "sistema: $($os.Caption) $($os.Version) - $($cpu.Name) - $script:NCPU thread - RAM $([math]::Round($os.TotalVisibleMemorySize / 1MB, 1)) GB"
  Get-PSDrive -PSProvider FileSystem | ForEach-Object { Log "disco $($_.Name): libero $([math]::Round($_.Free / 1GB, 1)) GB" }
}

function Avvia([hashtable]$vars = @{}, [string[]]$argomenti = @()) {
  $old = @{}
  foreach ($k in $vars.Keys) { $old[$k] = [Environment]::GetEnvironmentVariable($k); [Environment]::SetEnvironmentVariable($k, $vars[$k]) }
  if ($argomenti.Count) { $p = Start-Process -FilePath $script:Exe -ArgumentList ($argomenti | ForEach-Object { '"' + $_ + '"' }) -PassThru }
  else { $p = Start-Process -FilePath $script:Exe -PassThru }
  foreach ($k in $vars.Keys) { [Environment]::SetEnvironmentVariable($k, $old[$k]) }
  return $p
}

function Finestra() {
  foreach ($p in Get-Process orbitlr -ErrorAction SilentlyContinue) { $h = [W8]::Main([uint32]$p.Id); if ($h -ne [IntPtr]::Zero) { return $h } }
  return [IntPtr]::Zero
}

function Davanti() {
  $h = Finestra
  if ($h -ne [IntPtr]::Zero) {
    [W8]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [W8]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
    [W8]::ShowWindow($h, 9) | Out-Null; [W8]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Milliseconds 500
  }
  return $h
}

function Tasti([string]$k) { Davanti | Out-Null; [System.Windows.Forms.SendKeys]::SendWait($k); Start-Sleep -Milliseconds 400 }

# Un campione: CPU (secondi) e memoria di OrbitLR, WebView2 e ffmpeg
function Campione() {
  $o = @(Get-Process orbitlr -ErrorAction SilentlyContinue)
  $w = @(Get-Process msedgewebview2 -ErrorAction SilentlyContinue)
  $f = @(Get-Process ffmpeg -ErrorAction SilentlyContinue)
  $sum = { param($l, $what) $s = 0.0; foreach ($x in $l) { try { $s += (& $what $x) } catch {} }; $s }
  $hung = $false
  $h = Finestra
  if ($h -ne [IntPtr]::Zero) { $hung = [W8]::IsHungAppWindow($h) }
  [pscustomobject]@{
    t = Get-Date
    cpuApp = (& $sum $o { param($x) $x.TotalProcessorTime.TotalSeconds })
    cpuWv = (& $sum $w { param($x) $x.TotalProcessorTime.TotalSeconds })
    wsApp = (& $sum $o { param($x) $x.WorkingSet64 }) / 1MB
    privApp = (& $sum $o { param($x) $x.PrivateMemorySize64 }) / 1MB
    wsWv = (& $sum $w { param($x) $x.WorkingSet64 }) / 1MB
    privWv = (& $sum $w { param($x) $x.PrivateMemorySize64 }) / 1MB
    wsFf = (& $sum $f { param($x) $x.WorkingSet64 }) / 1MB
    nApp = $o.Count; nWv = $w.Count; nFf = $f.Count
    handles = (& $sum $o { param($x) $x.HandleCount })
    threads = (& $sum $o { param($x) $x.Threads.Count })
    hung = $hung
  }
}

# Osserva per al massimo $sec secondi (o finche' $finito e' vero): CPU media, picchi di memoria, finestra bloccata
function Osserva([string]$nome, [int]$sec, [scriptblock]$finito = $null, [int]$passo = 2) {
  $csv = Join-Path $Out "misure-$nome.csv"
  "secondi;cpuApp%core;cpuWv%core;wsApp;privApp;wsWv;privWv;wsFf;nApp;nWv;nFf;handles;threads;bloccata" | Set-Content $csv -Encoding utf8
  $a = Campione; $first = $a; $t0 = Get-Date
  $max = @{ wsApp = $a.wsApp; privApp = $a.privApp; wsWv = $a.wsWv; privWv = $a.privWv; wsFf = $a.wsFf; handles = $a.handles }
  $hung = 0; $hungMax = 0; $hungRun = 0; $fatto = $false; $morta = $false; $vista = ($a.nApp -gt 0)
  while (((Get-Date) - $t0).TotalSeconds -lt $sec) {
    Start-Sleep -Seconds $passo
    $b = Campione
    $dt = ($b.t - $a.t).TotalSeconds
    $ca = [math]::Max(0, ($b.cpuApp - $a.cpuApp)) / $dt * 100
    $cw = [math]::Max(0, ($b.cpuWv - $a.cpuWv)) / $dt * 100
    if ($b.hung) { $hung++; $hungRun += $dt; $hungMax = [math]::Max($hungMax, $hungRun) } else { $hungRun = 0 }
    foreach ($k in @($max.Keys)) { $max[$k] = [math]::Max($max[$k], $b.$k) }
    "{0:N0};{1:N1};{2:N1};{3:N0};{4:N0};{5:N0};{6:N0};{7:N0};{8};{9};{10};{11};{12};{13}" -f ($b.t - $t0).TotalSeconds, $ca, $cw, $b.wsApp, $b.privApp, $b.wsWv, $b.privWv, $b.wsFf, $b.nApp, $b.nWv, $b.nFf, $b.handles, $b.threads, $b.hung | Add-Content $csv -Encoding utf8
    $a = $b
    if ($b.nApp -gt 0) { $vista = $true }
    if ($vista -and $b.nApp -eq 0) { $morta = $true; break }
    if ($finito -and (& $finito)) { $fatto = $true; break }
  }
  $dur = ($a.t - $first.t).TotalSeconds
  if ($dur -le 0) { $dur = 1 }
  $r = [pscustomobject]@{
    nome = $nome; secondi = [math]::Round(((Get-Date) - $t0).TotalSeconds); fatto = $fatto; morta = $morta
    cpuAppCore = [math]::Round(($a.cpuApp - $first.cpuApp) / $dur * 100, 2)
    cpuWvCore = [math]::Round(($a.cpuWv - $first.cpuWv) / $dur * 100, 2)
    cpuTotMacchina = [math]::Round((($a.cpuApp - $first.cpuApp) + ($a.cpuWv - $first.cpuWv)) / $dur * 100 / $script:NCPU, 2)
    wsAppFine = [math]::Round($a.wsApp); wsAppMax = [math]::Round($max.wsApp); privAppMax = [math]::Round($max.privApp)
    wsWvFine = [math]::Round($a.wsWv); wsWvMax = [math]::Round($max.wsWv); privWvMax = [math]::Round($max.privWv)
    wsFfMax = [math]::Round($max.wsFf); handlesInizio = $first.handles; handlesFine = $a.handles; handlesMax = $max.handles
    campioniBloccata = $hung; bloccataMaxSec = [math]::Round($hungMax)
  }
  Log "misura $nome : $(($r | ConvertTo-Json -Compress))"
  Add-Content -Path (Join-Path $Out "misure.jsonl") -Value ($r | ConvertTo-Json -Compress) -Encoding utf8
  return $r
}

function Avanzi([string[]]$dirs) {
  $l = @()
  foreach ($d in $dirs) {
    $l += Get-ChildItem $d -Force -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like ".orbitlr-*" -or $_.Length -eq 0 }
  }
  return $l
}

function Registro() {
  $r = Join-Path $env:APPDATA "it.ledion.orbitlr\temporanei.txt"
  if (Test-Path $r) { return ((Get-Content $r -Raw) -replace "`r?`n", " || ") } else { return "(nessun temporanei.txt)" }
}

# Tutti i testi che l'accessibilita' vede nella finestra di OrbitLR (prova di cosa mostra la pagina)
function TestiApp([string]$nome, [int]$max = 600) {
  $h = Finestra
  if ($h -eq [IntPtr]::Zero) { Log "testi $nome : nessuna finestra"; return @() }
  try {
    $el = [System.Windows.Automation.AutomationElement]::FromHandle($h)
    $all = $el.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)
    $seen = New-Object System.Collections.Generic.List[string]
    foreach ($e in $all) { try { $n = $e.Current.Name; if ($n -and $n.Trim() -and $seen.Count -lt $max) { $seen.Add(($e.Current.ControlType.ProgrammaticName -replace "ControlType\.", "") + ": " + $n.Trim()) } } catch {} }
    $seen | Set-Content (Join-Path $Out "testi-$nome.txt") -Encoding utf8
    return $seen
  } catch { Log "testi $nome : $_"; return @() }
}

# Un pulsante (o voce) della finestra di OrbitLR per nome, premuto con l'accessibilita'
function Premi([string[]]$nomi, [int]$sec = 10, [IntPtr]$h = [IntPtr]::Zero) {
  $t0 = Get-Date
  while (((Get-Date) - $t0).TotalSeconds -lt $sec) {
    if ($h -eq [IntPtr]::Zero) { $root = [System.Windows.Automation.AutomationElement]::FromHandle((Finestra)) } else { $root = [System.Windows.Automation.AutomationElement]::FromHandle($h) }
    foreach ($n in $nomi) {
      try {
        $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, $n)
        $e = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c)
        if ($e) {
          try { $e.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); return "premuto '$n' (invoke)" }
          catch { try { $e.SetFocus(); [System.Windows.Forms.SendKeys]::SendWait("{ENTER}"); return "premuto '$n' (fuoco+invio)" } catch { return "trovato '$n' ma non premuto: $_" } }
        }
      } catch {}
    }
    Start-Sleep -Milliseconds 700
  }
  return "non trovato: $($nomi -join ' / ')"
}

function ChiudiBenvenuto() {
  # Il benvenuto del primo avvio si chiude con Esc
  Tasti "{ESC}"; Start-Sleep -Milliseconds 600; Tasti "{ESC}"
}

function ProcessiFigli() {
  Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.Name -in "orbitlr.exe", "ffmpeg.exe", "ffprobe.exe", "msedgewebview2.exe", "powershell.exe" } | ForEach-Object { "$($_.Name) pid $($_.ProcessId) padre $($_.ParentProcessId)" }
}

function Raccogli() {
  $dati = "$env:LOCALAPPDATA\it.ledion.orbitlr"
  Get-ChildItem $dati, "$env:APPDATA\it.ledion.orbitlr" -Recurse -Depth 2 -Force -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch "EBWebView\\Default\\(Cache|Code Cache|GPUCache)" } | ForEach-Object { "$($_.FullName) $($_.Length)" } | Set-Content (Join-Path $Out "cartelle-app.txt") -Encoding utf8
  $crash = @(Get-ChildItem $dati -Recurse -Filter *.dmp -ErrorAction SilentlyContinue)
  Log "rapporti di arresto (dmp): $($crash.Count)"
  foreach ($c in $crash | Select-Object -First 5) { Copy-Item $c.FullName $Out -ErrorAction SilentlyContinue }
  Get-WinEvent -FilterHashtable @{ LogName = "Application"; Level = 1, 2, 3; StartTime = $script:T0 } -ErrorAction SilentlyContinue |
    Where-Object { $_.Message -match "orbitlr|msedgewebview2|ffmpeg|OrbitLR" } | Select-Object -First 40 |
    ForEach-Object { "$($_.TimeCreated) $($_.ProviderName) $($_.Id): $(($_.Message -split "`n" | Select-Object -First 8) -join ' ')" } | Set-Content (Join-Path $Out "errori-windows.txt") -Encoding utf8
  Log "eventi di errore di Windows su OrbitLR/WebView2/ffmpeg: $((Get-Content (Join-Path $Out 'errori-windows.txt') -ErrorAction SilentlyContinue | Measure-Object).Count)"
  $reg = Join-Path $env:APPDATA "it.ledion.orbitlr\temporanei.txt"
  if (Test-Path $reg) { Copy-Item $reg (Join-Path $Out "temporanei-fine.txt") }
}
