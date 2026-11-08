# W01 · OrbitLR per Windows: installazione, primo avvio, chiusura dal vassoio, riavvio, reinstallazione,
# disinstallazione e residui, utente con spazi e accenti, WebView2 mancante.
# Uso: pwsh -File Tests/Agenti/W01/ciclo.ps1 -Setup OrbitLR-Setup.exe -Out cartella
param([string]$Setup = "OrbitLR-Setup.exe", [string]$Out = "w01")

$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$Setup = (Resolve-Path $Setup).Path
$Ris = Join-Path $Out "risultati.txt"
function Log([string]$m) { $l = "$(Get-Date -Format HH:mm:ss) $m"; Write-Host $l; Add-Content -Path (Join-Path $Out "diario.txt") -Value $l -Encoding utf8 }
function Esito([string]$nome, [bool]$ok, [string]$dett = "") { $l = "$(if ($ok) { 'PASSATO' } else { 'FALLITO' }) · $nome · $dett"; Add-Content -Path $Ris -Value $l -Encoding utf8; Write-Host "== $l" }
function Info([string]$nome, [string]$dett) { $l = "INFO · $nome · $dett"; Add-Content -Path $Ris -Value $l -Encoding utf8; Write-Host "== $l" }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing, UIAutomationClient, UIAutomationTypes
Add-Type @"
using System; using System.Runtime.InteropServices;
public static class W {
  [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr v);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
  [DllImport("user32.dll")] public static extern void mouse_event(uint f, uint x, uint y, uint d, IntPtr e);
  [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
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
  public static string Titles(uint pid) {
    var all = new System.Collections.Generic.List<string>();
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid) return true;
      var sb = new System.Text.StringBuilder(256); GetWindowText(h, sb, 256); if (sb.Length > 0) all.Add(sb.ToString() + (IsWindowVisible(h) ? "" : " (nascosta)")); return true; }, IntPtr.Zero);
    return string.Join(" | ", all);
  }
}
"@
[W]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null

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
function Click([int]$x, [int]$y, [bool]$right = $false) {
  [W]::SetCursorPos($x, $y) | Out-Null; Start-Sleep -Milliseconds 200
  if ($right) { [W]::mouse_event(0x8, 0, 0, 0, [IntPtr]::Zero); [W]::mouse_event(0x10, 0, 0, 0, [IntPtr]::Zero) }
  else { [W]::mouse_event(0x2, 0, 0, 0, [IntPtr]::Zero); [W]::mouse_event(0x4, 0, 0, 0, [IntPtr]::Zero) }
}
function Procs() { @(Get-Process orbitlr -ErrorAction SilentlyContinue) }
function Ferma() { Get-Process orbitlr, msedgewebview2, ffmpeg -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2 }

$Dove = Join-Path $env:LOCALAPPDATA "OrbitLR"
$Exe = Join-Path $Dove "orbitlr.exe"
$Dati = Join-Path $env:LOCALAPPDATA "it.ledion.orbitlr"
$Segno = Join-Path $Dati "in-uso"

# Tutto quello che OrbitLR lascia sul computer (cartelle, registro, collegamenti)
function Stato([string]$etichetta) {
  $f = Join-Path $Out "stato-$etichetta.txt"
  $r = @()
  foreach ($p in $Dove, $Dati, (Join-Path $env:APPDATA "it.ledion.orbitlr"), (Join-Path $env:LOCALAPPDATA "Temp\it.ledion.orbitlr")) {
    $n = (Get-ChildItem $p -Recurse -Force -ErrorAction SilentlyContinue | Measure-Object).Count
    $r += "cartella $($p.Replace($env:USERPROFILE, '%USERPROFILE%')): $(if (Test-Path $p) { "C'È ($n elementi)" } else { 'no' })"
  }
  foreach ($k in 'HKCU:\Software\Classes\*\shell\OrbitLR', 'HKCU:\Software\Classes\Directory\shell\OrbitLR', 'HKCU:\Software\Ledion', 'HKCU:\Software\Ledion\OrbitLR', 'HKCU:\Software\OrbitLR', 'HKCU:\Software\it.ledion.orbitlr') {
    $r += "registro ${k}: $(if (Test-Path -LiteralPath $k) { "C'È" } else { 'no' })"
  }
  $un = Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { $_.DisplayName -like "OrbitLR*" }
  $r += "Programmi installati (HKCU Uninstall): $(if ($un) { ($un | ForEach-Object { "$($_.PSChildName) = $($_.DisplayName) $($_.DisplayVersion)" }) -join '; ' } else { 'no' })"
  foreach ($run in 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Run', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce') {
    $v = (Get-ItemProperty $run -ErrorAction SilentlyContinue).PSObject.Properties | Where-Object { "$($_.Value)" -match "orbitlr" }
    $r += "avvio automatico ${run}: $(if ($v) { ($v | ForEach-Object Name) -join ',' } else { 'no' })"
  }
  $lnk = Get-ChildItem ([Environment]::GetFolderPath("Desktop")), ([Environment]::GetFolderPath("Programs")), ([Environment]::GetFolderPath("CommonDesktopDirectory")), ([Environment]::GetFolderPath("CommonPrograms")) -Recurse -Filter "*OrbitLR*" -ErrorAction SilentlyContinue
  $r += "collegamenti: $(if ($lnk) { ($lnk | ForEach-Object { $_.FullName.Replace($env:USERPROFILE, '%USERPROFILE%') }) -join '; ' } else { 'no' })"
  $q = & reg.exe query HKCU /s /f orbitlr 2>$null | Where-Object { $_ -match '^HKEY' }
  $r += "reg query HKCU /f orbitlr: $(($q | Measure-Object).Count) chiavi"
  $r += $q | ForEach-Object { "   $_" }
  $r | Set-Content $f -Encoding utf8
  return $r
}

# Avvia OrbitLR, aspetta la finestra, foto
function Apri([string]$nome, [int]$attesa = 25, [string[]]$argomenti = @()) {
  $t0 = Get-Date
  $p = if ($argomenti.Count) { Start-Process -FilePath $Exe -ArgumentList $argomenti -PassThru } else { Start-Process -FilePath $Exe -PassThru }
  $h = [IntPtr]::Zero
  for ($i = 0; $i -lt $attesa * 2; $i++) {
    Start-Sleep -Milliseconds 500
    $h = [W]::Main([uint32]$p.Id)
    if ($h -ne [IntPtr]::Zero -and $i -ge 16) { break }
    if ($p.HasExited) { break }
  }
  $fin = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  if ($h -ne [IntPtr]::Zero) { [W]::SetForegroundWindow($h) | Out-Null; Start-Sleep -Seconds 2 }
  Foto $nome
  $vivo = -not $p.HasExited
  Info "$nome" "processo $(if ($vivo) { 'vivo' } else { "chiuso (codice $($p.ExitCode))" }) · finestra «OrbitLR» $(if ($h -ne [IntPtr]::Zero) { 'sì' } else { 'NO' }) dopo $fin s · finestre: $([W]::Titles([uint32]$p.Id)) · WebView2 $((Get-Process msedgewebview2 -ErrorAction SilentlyContinue).Count) processi · segno in-uso $(Test-Path $Segno)"
  return $p
}

# Chiude dal menu dell'icona vicino all'orologio («Esci»)
function EsciDalVassoio([string]$nome) {
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $tc = [System.Windows.Automation.TreeScope]::Descendants
  $all = [System.Windows.Automation.Condition]::TrueCondition
  $trova = {
    param($dove)
    foreach ($e in $dove.FindAll($tc, $all)) { try { if ($e.Current.Name -like "OrbitLR*" -and $e.Current.ControlType.ProgrammaticName -match "Button|MenuItem") { return $e } } catch {} }
    return $null
  }
  $tray = $root.FindFirst([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, "Shell_TrayWnd")))
  $icona = if ($tray) { & $trova $tray } else { $null }
  $dove = "barra"
  if (-not $icona -and $tray) {
    # Icone nascoste: la freccia «^»
    foreach ($e in $tray.FindAll($tc, $all)) { try { if ($e.Current.Name -match "hidden icons|icone nascoste|Show hidden|Mostra") { $b = $e.Current.BoundingRectangle; Click ([int]($b.X + $b.Width / 2)) ([int]($b.Y + $b.Height / 2)); Start-Sleep -Seconds 2; break } } catch {} }
    foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $all)) { try { if ($w.Current.ClassName -match "Overflow|NotifyIcon") { $icona = & $trova $w; if ($icona) { $dove = "icone nascoste"; break } } } catch {} }
  }
  if (-not $tray) { Info "$nome" "barra delle applicazioni (Shell_TrayWnd) non trovata" }
  Foto "$nome-1-vassoio"
  if (-not $icona) {
    $nomi = if ($tray) { ($tray.FindAll($tc, $all) | ForEach-Object { try { $_.Current.Name } catch {} } | Where-Object { $_ }) -join ' | ' } else { '' }
    Info "$nome" "icona OrbitLR non trovata vicino all'orologio · elementi della barra: $nomi"
    return $false
  }
  $b = $icona.Current.BoundingRectangle
  Log "icona OrbitLR trovata ($dove): $($icona.Current.Name) a $($b.X),$($b.Y)"
  Click ([int]($b.X + $b.Width / 2)) ([int]($b.Y + $b.Height / 2)) $true
  Start-Sleep -Seconds 2
  Foto "$nome-2-menu"
  $voce = $null
  foreach ($e in $root.FindAll($tc, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ControlTypeProperty, [System.Windows.Automation.ControlType]::MenuItem)))) {
    try { if ($e.Current.Name -match "^(Esci|Quit)$") { $voce = $e; break } } catch {}
  }
  if ($voce) {
    $vb = $voce.Current.BoundingRectangle
    Log "voce «$($voce.Current.Name)» a $($vb.X),$($vb.Y)"
    Click ([int]($vb.X + $vb.Width / 2)) ([int]($vb.Y + $vb.Height / 2))
  } else {
    Log "voce Esci/Quit non trovata con UIA: provo con i tasti (Fine, Invio)"
    [System.Windows.Forms.SendKeys]::SendWait("{END}"); Start-Sleep -Milliseconds 300; [System.Windows.Forms.SendKeys]::SendWait("{ENTER}")
  }
  return $true
}

function AspettaChiusura([int]$sec) { for ($i = 0; $i -lt $sec * 2; $i++) { if (-not (Procs).Count) { return [math]::Round($i / 2, 1) }; Start-Sleep -Milliseconds 500 }; return -1 }

function Installa([string]$nome, [string]$modo = "diretto") {
  Log "Installa $nome ($modo) · orbitlr vivi: $((Procs).Count)"
  $t0 = Get-Date
  if ($modo -eq "runas") {
    & runas.exe /trustlevel:0x20000 "`"$Setup`" /S" 2>&1 | ForEach-Object { Log "runas: $_" }
    for ($i = 0; $i -lt 60 -and -not (Test-Path $Exe); $i++) { Start-Sleep -Seconds 3 }
    Start-Sleep -Seconds 2
    for ($i = 0; $i -lt 60 -and (Get-Process OrbitLR-Setup -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 2 }
    $code = "n/d (runas)"
    if (-not (Test-Path $Exe)) { Log "runas non ha installato: provo diretto"; $modo = "diretto (runas non ha funzionato)" }
  }
  if ($modo -ne "runas") {
    $p = Start-Process -FilePath $Setup -ArgumentList "/S" -PassThru
    $fin = $false
    for ($i = 0; $i -lt 120; $i++) {
      Start-Sleep -Seconds 1
      if ($p.HasExited) { $fin = $true; break }
      if ($i -eq 20 -or $i -eq 60) { Foto "$nome-installazione-$($i)s"; Log "$nome · installatore ancora aperto dopo $i s · finestre: $([W]::Titles([uint32]$p.Id)) · orbitlr vivi: $((Procs).Count)" }
    }
    $code = if ($fin) { $p.ExitCode } else { "FERMO dopo 120 s" }
    if (-not $fin) { Foto "$nome-installazione-ferma"; Log "$nome · FERMO · finestre: $([W]::Titles([uint32]$p.Id))"; Get-Process OrbitLR-Setup -ErrorAction SilentlyContinue | Stop-Process -Force }
    for ($i = 0; $i -lt 30 -and (Get-Process OrbitLR-Setup -ErrorAction SilentlyContinue); $i++) { Start-Sleep -Seconds 2 }
  }
  $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
  $v = if (Test-Path $Exe) { (Get-Item $Exe).VersionInfo.ProductVersion } else { "" }
  Info "$nome" "modo $modo · codice $code · $sec s · orbitlr.exe $(if (Test-Path $Exe) { "c'è ($v, modificato $((Get-Item $Exe).LastWriteTime.ToString('HH:mm:ss')))" } else { 'NON C''È' })"
  return (Test-Path $Exe)
}

# ════════ 0. Il computer e WebView2
Log "FASE 0: Il computer e WebView2"
$os = Get-CimInstance Win32_OperatingSystem
Info "sistema" "$($os.Caption) $($os.Version) · $env:PROCESSOR_ARCHITECTURE · cultura $((Get-Culture).Name) · interfaccia $((Get-UICulture).Name)"
$wvKeys = "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}", "HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}", "HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}"
foreach ($k in $wvKeys) { Info "WebView2 nel registro" "$k → $((Get-ItemProperty $k -ErrorAction SilentlyContinue).pv)" }
Info "WebView2 sul disco" "$((Get-ChildItem 'C:\Program Files (x86)\Microsoft\EdgeWebView\Application' -Directory -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ')"
Stato "0-prima" | Out-Null
Set-Content -Path "$Setup" -Stream Zone.Identifier -Value "[ZoneTransfer]`r`nZoneId=3`r`nHostUrl=https://github.com/LR-apps609/OrbitLR/releases/" -Encoding ascii

# ════════ 1. Installazione per l'utente, senza amministratore, in silenzio
Log "FASE 1: Installazione per l'utente, senza amministratore, in silenzio"
$ok = Installa "1-installazione" "runas"
Esito "installazione silenziosa per l'utente" $ok
# Start-Process (ShellExecute) su un file «da internet» apre l'avviso di sicurezza e si ferma: da qui in poi senza Zone.Identifier
Unblock-File $Setup
Info "Zone.Identifier tolto dopo la prima installazione" "$(-not (Get-Item $Setup -Stream Zone.Identifier -ErrorAction SilentlyContinue))"
$s = Stato "1-installata"
Esito "voce «Apri con OrbitLR» sui file e sulle cartelle" (($s -match "shell\\OrbitLR: C'È").Count -eq 2) (($s | Select-String "shell\\OrbitLR") -join " ; ")
Esito "nessun avvio automatico con Windows" (-not ($s -match "avvio automatico.*: (?!no)")) (($s | Select-String "avvio automatico") -join " ; ")
Info "collegamenti dopo l'installazione" (($s | Select-String "collegamenti") -join "")
if (Test-Path $Dove) { Get-ChildItem $Dove -Recurse | ForEach-Object { "$($_.FullName.Replace($env:USERPROFILE, '%USERPROFILE%')) $($_.Length)" } | Set-Content (Join-Path $Out "file-installati.txt") -Encoding utf8 }
if (-not $ok) { Foto "installazione-fallita"; exit 1 }

# ════════ 2. Primo avvio
Log "FASE 2: Primo avvio"
$p = Apri "2-primo-avvio" 40
Esito "primo avvio: finestra OrbitLR aperta" ([W]::Main([uint32]$p.Id) -ne [IntPtr]::Zero)
Esito "primo avvio: segno «in uso» creato" (Test-Path $Segno)
Start-Sleep -Seconds 10
Foto "2-primo-avvio-50s"
Get-ChildItem $Dati -Recurse -Depth 1 -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName.Replace($env:USERPROFILE, '%USERPROFILE%') } | Set-Content (Join-Path $Out "dati-dopo-primo-avvio.txt") -Encoding utf8

# ════════ 3. Chiudi dal vassoio («Esci»)
Log "FASE 3: Chiudi dal vassoio («Esci»)"
$trovata = EsciDalVassoio "3-vassoio"
$t = AspettaChiusura 12
Foto "3-vassoio-3-dopo"
if ($t -lt 0) {
  # «Esci» chiede alla pagina; se la pagina mostra una domanda, si vede nella foto
  Info "vassoio" "dopo «Esci» OrbitLR è ancora aperta dopo 12 s: finestre $(foreach ($q in Procs) { [W]::Titles([uint32]$q.Id) })"
  # Secondo «Esci» (main.rs: dopo 3 s il secondo Esci chiude comunque)
  Start-Sleep -Seconds 4
  if ($trovata) { EsciDalVassoio "3-vassoio-bis" | Out-Null; $t = AspettaChiusura 12 }
}
Esito "chiusura dal vassoio con «Esci»" ($trovata -and $t -ge 0) "icona trovata $trovata · chiusa dopo $t s"
Esito "chiusura dal vassoio: segno «in uso» tolto" (-not (Test-Path $Segno))
Ferma

# ════════ 4. Riapertura e chiusura con la ✕ (WM_CLOSE)
Log "FASE 4: Riapertura e chiusura con la ✕ (WM_CLOSE)"
$p = Apri "4-riapertura" 30
Esito "riapertura: finestra OrbitLR" ([W]::Main([uint32]$p.Id) -ne [IntPtr]::Zero)
$h = [W]::Main([uint32]$p.Id)
[W]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
$t = AspettaChiusura 10
Foto "4-dopo-x"
if ($t -lt 0) { Info "✕" "dopo la ✕ OrbitLR è ancora viva dopo 10 s (resta nel vassoio?): $(foreach ($q in Procs) { [W]::Titles([uint32]$q.Id) })" }
Info "chiusura con la ✕" "chiusa dopo $t s · segno in-uso $(Test-Path $Segno)"
Ferma

# ════════ 5. Chiusura improvvisa (processo ucciso) e riapertura
Log "FASE 5: Chiusura improvvisa (processo ucciso) e riapertura"
$p = Apri "5a-prima-di-uccidere" 30
Stop-Process -Id $p.Id -Force; Start-Sleep -Seconds 2
Esito "dopo un'uccisione il segno «in uso» resta (rilevamento chiusura improvvisa)" (Test-Path $Segno)
$p = Apri "5b-dopo-uccisione" 30
Esito "si riapre dopo una chiusura improvvisa" ([W]::Main([uint32]$p.Id) -ne [IntPtr]::Zero)

# ════════ 6. Una sola OrbitLR: seconda apertura con un file
Log "FASE 6: Una sola OrbitLR: seconda apertura con un file"
$f = Join-Path $env:USERPROFILE "Documents\Prova è W01.txt"; "ciao" | Set-Content $f -Encoding utf8
Start-Process -FilePath $Exe -ArgumentList "`"$f`"" | Out-Null
Start-Sleep -Seconds 6
Foto "6-seconda-apertura"
Esito "una sola OrbitLR aperta dopo la seconda apertura" ((Procs).Count -eq 1) "$((Procs).Count) processi orbitlr"

# ════════ 8. Reinstallazione con OrbitLR chiusa
Log "FASE 8: Reinstallazione con OrbitLR chiusa"
Ferma
$ok = Installa "8-reinstallazione-app-chiusa" "diretto"
Esito "reinstallazione con OrbitLR chiusa" $ok
$p = Apri "8b-apre" 30
Esito "si apre dopo la reinstallazione (app chiusa)" ([W]::Main([uint32]$p.Id) -ne [IntPtr]::Zero)
Ferma

# ════════ 9. Disinstallazione silenziosa e residui
Log "FASE 9: Disinstallazione silenziosa e residui"
$un = Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall | Get-ItemProperty | Where-Object { $_.DisplayName -like "OrbitLR*" } | Select-Object -First 1
Info "disinstallatore" "$($un.UninstallString.Replace($env:USERPROFILE, '%USERPROFILE%')) · QuietUninstallString $(if ($un.QuietUninstallString) { 'sì' } else { 'no' }) · EstimatedSize $($un.EstimatedSize) KB"
$uexe = ($un.UninstallString -replace '^"([^"]+)".*', '$1')
$t0 = Get-Date
$u = Start-Process -FilePath $uexe -ArgumentList "/S" -PassThru
$u.WaitForExit(180000) | Out-Null
for ($i = 0; $i -lt 60 -and (Test-Path $Exe); $i++) { Start-Sleep -Seconds 1 }
Start-Sleep -Seconds 3
Info "disinstallazione" "codice $($u.ExitCode) · $([math]::Round(((Get-Date) - $t0).TotalSeconds, 1)) s"
$s = Stato "9-disinstallata"
Esito "disinstallazione: programma tolto" (-not (Test-Path $Exe)) (($s | Select-Object -First 1))
Esito "disinstallazione: voce «Apri con OrbitLR» tolta" (-not ($s -match "shell\\OrbitLR: C'È")) (($s | Select-String "shell\\OrbitLR") -join " ; ")
Esito "disinstallazione: niente in Programmi installati" (($s -match "Programmi installati.*: no").Count -eq 1)
Esito "disinstallazione: collegamenti tolti" (($s -match "^collegamenti: no").Count -eq 1) (($s | Select-String "^collegamenti") -join "")
Info "residui dopo la disinstallazione" (($s | Where-Object { $_ -match "C'È|chiavi" }) -join " ; ")

# ════════ 10. Reinstallazione dopo la disinstallazione
Log "FASE 10: Reinstallazione dopo la disinstallazione"
$ok = Installa "10-reinstallazione-dopo-disinstallazione" "runas"
$p = Apri "10b-apre" 30
Esito "reinstallata e aperta dopo la disinstallazione" ($ok -and [W]::Main([uint32]$p.Id) -ne [IntPtr]::Zero)
Ferma
$ff = Join-Path $Dove "motori\ffmpeg.exe"

# ════════ 11. Utente con spazi e accenti
Log "FASE 11: Utente con spazi e accenti"
$nomeU = "Nicolò De Santis"
$pw = "W1!" + [guid]::NewGuid().ToString("N").Substring(0, 16) + "aZ"
$sec = ConvertTo-SecureString $pw -AsPlainText -Force
try {
  New-LocalUser -Name $nomeU -Password $sec -PasswordNeverExpires -ErrorAction Stop | Out-Null
  Add-LocalGroupMember -Group "Users" -Member $nomeU -ErrorAction SilentlyContinue
  Info "utente nuovo" "creato (non amministratore)"
} catch { Info "utente nuovo" "non creato: $_" }
$cred = New-Object System.Management.Automation.PSCredential(".\$nomeU", $sec)
New-Item -ItemType Directory -Force -Path "C:\Prova W01" | Out-Null
Copy-Item $Setup "C:\Prova W01\OrbitLR-Setup.exe" -Force
& icacls.exe "C:\Prova W01" /grant "*S-1-1-0:(OI)(CI)F" | Out-Null
try {
  $t0 = Get-Date
  $pi = Start-Process -FilePath "C:\Prova W01\OrbitLR-Setup.exe" -ArgumentList "/S" -Credential $cred -LoadUserProfile -WorkingDirectory "C:\Prova W01" -PassThru -ErrorAction Stop
  $pi.WaitForExit(300000) | Out-Null
  Start-Sleep -Seconds 3
  $casa = (Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -like "*Nicol*" } | Select-Object -First 1).LocalPath
  Info "profilo dell'utente nuovo" "$(if ($casa) { "cartella «$(Split-Path $casa -Leaf)»" } else { 'non trovato' })"
  $exeU = if ($casa) { Join-Path $casa "AppData\Local\OrbitLR\orbitlr.exe" } else { "" }
  Esito "installazione come «$nomeU»" ($exeU -and (Test-Path $exeU)) "codice $($pi.ExitCode) · $([math]::Round(((Get-Date) - $t0).TotalSeconds)) s"
  if ($exeU -and (Test-Path $exeU)) {
    $ctx = & reg.exe query "HKU" 2>$null
    # File di prova nella sua cartella Documenti (nome con accento e spazi)
    $doc = Join-Path $casa "Documents\Vacanze è là"
    New-Item -ItemType Directory -Force -Path $doc | Out-Null
    & $ff -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=25:duration=4" -f lavfi -i "sine=frequency=440:duration=4" -c:v libx264 -pix_fmt yuv420p -c:a aac -shortest "$doc\Gita è.mp4" 2>&1 | Out-Null
    & icacls.exe $doc /grant "${nomeU}:(OI)(CI)F" | Out-Null
    $cmd = "C:\Prova W01\apri-come-utente.cmd"
    # chcp 65001: il file .cmd è in UTF-8
    @("@echo off", "chcp 65001 >nul", "set ORBIT_PROVA_FILE=$doc\Gita è.mp4", "set ORBIT_PROVA_SCHEDA=video", "set ORBIT_PROVA_AZIONE=vcompress", "set ORBIT_PROVA_PARAMETRO=best", "start `"`" `"$exeU`"") | Set-Content $cmd -Encoding utf8NoBOM
    $pa = Start-Process -FilePath "cmd.exe" -ArgumentList "/C `"$cmd`"" -Credential $cred -LoadUserProfile -WorkingDirectory "C:\Prova W01" -PassThru
    $fatto = $false
    for ($i = 0; $i -lt 60; $i++) { Start-Sleep -Seconds 3; if (Get-ChildItem $doc -Filter "Gita è (*).mp4" -ErrorAction SilentlyContinue) { $fatto = $true; break }; if ($i -eq 5) { Foto "11-utente-accenti-15s" } }
    Foto "11-utente-accenti"
    $pu = Get-CimInstance Win32_Process -Filter "Name='orbitlr.exe'" | ForEach-Object { $o = Invoke-CimMethod -InputObject $_ -MethodName GetOwner; "pid $($_.ProcessId) di $(if ($o.User -like 'Nicol*') { 'utente nuovo' } else { 'altro utente' })" }
    Info "OrbitLR come «$nomeU»" "processi: $($pu -join ', ') · file nella cartella: $((Get-ChildItem $doc | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ' · ')"
    Esito "come «$nomeU»: comprimi un video in «Documents\Vacanze è là»" $fatto
    $du = Join-Path $casa "AppData\Local\it.ledion.orbitlr"
    Info "cartella dati dell'utente nuovo" "$(if (Test-Path $du) { ((Get-ChildItem $du -ErrorAction SilentlyContinue | ForEach-Object Name) -join ', ') } else { 'non creata' })"
    Get-Process orbitlr -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2
    # Disinstallazione come quell'utente
    $uu = Join-Path $casa "AppData\Local\OrbitLR\uninstall.exe"
    if (Test-Path $uu) {
      $pq = Start-Process -FilePath $uu -ArgumentList "/S" -Credential $cred -LoadUserProfile -WorkingDirectory "C:\Prova W01" -PassThru
      $pq.WaitForExit(120000) | Out-Null; Start-Sleep -Seconds 5
      Esito "come «$nomeU»: disinstallazione" (-not (Test-Path $exeU)) "codice $($pq.ExitCode)"
    } else { Info "disinstallatore dell'utente nuovo" "non trovato: $((Get-ChildItem (Split-Path $exeU) | ForEach-Object Name) -join ', ')" }
  }
} catch { Info "utente con accenti" "non riuscito: $_" }

# ════════ 12. WebView2 «mancante»: l'installatore lo va a prendere?
Log "FASE 12: WebView2 «mancante»: l'installatore lo va a prendere?"
$bk = Join-Path $Out "webview2-chiavi"
New-Item -ItemType Directory -Force -Path $bk | Out-Null
$i = 0
foreach ($k in $wvKeys) {
  if (Test-Path $k) { $i++; $rk = $k.Replace("HKLM:\", "HKLM\").Replace("HKCU:\", "HKCU\"); & reg.exe export $rk (Join-Path $bk "$i.reg") /y | Out-Null; & reg.exe delete $rk /f | Out-Null; Log "tolta per prova: $rk" }
}
Ferma
$visti = New-Object System.Collections.Generic.HashSet[string]
$t0 = Get-Date
$pw2 = Start-Process -FilePath $Setup -ArgumentList "/S" -PassThru
while (-not $pw2.HasExited -and ((Get-Date) - $t0).TotalSeconds -lt 300) {
  Get-Process | Where-Object { $_.Name -match "WebView2|EdgeUpdate|Edge.*Setup|MicrosoftEdge" } | ForEach-Object { [void]$visti.Add($_.Name) }
  Start-Sleep -Milliseconds 300
}
$sec2 = [math]::Round(((Get-Date) - $t0).TotalSeconds, 1)
$dopo = foreach ($k in $wvKeys) { "$k → $((Get-ItemProperty $k -ErrorAction SilentlyContinue).pv)" }
Info "installazione con WebView2 tolto dal registro" "codice $(if ($pw2.HasExited) { $pw2.ExitCode } else { 'ferma' }) · $sec2 s · processi visti: $(($visti | Sort-Object) -join ', ') · registro dopo: $($dopo -join ' ; ')"
$scaricato = Get-ChildItem $env:TEMP -Recurse -Filter "MicrosoftEdgeWebview2Setup*" -ErrorAction SilentlyContinue
Esito "senza WebView2 l'installatore scarica e avvia il programma di Microsoft" (($visti | Where-Object { $_ -match "WebView2Setup|EdgeUpdate" }).Count -gt 0 -or $scaricato) "file in TEMP: $(($scaricato | ForEach-Object Name) -join ', ')"
$p = Apri "12-apre-dopo-webview2" 30
Esito "si apre dopo l'installazione con WebView2 mancante" ([W]::Main([uint32]$p.Id) -ne [IntPtr]::Zero)
Ferma
# Rimette le chiavi se il programma di Microsoft non le ha ricreate
foreach ($r in Get-ChildItem $bk -Filter *.reg) { & reg.exe import $r.FullName 2>&1 | Out-Null }

Ferma
Installa "7-0-prima" "diretto" | Out-Null
$p = Apri "7-0-app-aperta" 30
# ════════ 7. Reinstallazione sopra sé stessa con OrbitLR APERTA
Log "FASE 7: Reinstallazione sopra sé stessa con OrbitLR APERTA"
$prima = (Get-Item $Exe).LastWriteTime
$ok = Installa "7-reinstallazione-con-app-aperta" "diretto"
Start-Sleep -Seconds 3
Foto "7-dopo-reinstallazione-aperta"
Info "reinstallazione con app aperta" "processi orbitlr dopo: $((Procs).Count) · exe riscritto: $((Get-Item $Exe -ErrorAction SilentlyContinue).LastWriteTime -ne $prima)"
Esito "reinstallazione con OrbitLR aperta: exe al suo posto" $ok
Ferma
Get-Process OrbitLR-Setup -ErrorAction SilentlyContinue | Stop-Process -Force
$p = Apri "7b-apre-dopo-reinstallazione" 30
Esito "si apre dopo la reinstallazione (con app aperta)" ([W]::Main([uint32]$p.Id) -ne [IntPtr]::Zero)
Ferma

Ferma
Get-WinEvent -FilterHashtable @{ LogName = "Application"; Level = 1, 2; StartTime = (Get-Date).AddHours(-1) } -ErrorAction SilentlyContinue |
  Where-Object { $_.Message -match "orbitlr|msedgewebview2|OrbitLR" } | Select-Object -First 20 |
  ForEach-Object { "$($_.TimeCreated) $($_.ProviderName) $($_.Id): $(($_.Message -split "`n" | Select-Object -First 6) -join ' ')" } | Set-Content (Join-Path $Out "errori-windows.txt") -Encoding utf8
Info "errori di Windows su OrbitLR" "$((Get-Content (Join-Path $Out 'errori-windows.txt') -ErrorAction SilentlyContinue | Measure-Object).Count)"
Get-Content $Ris
