# W03 · Prove in piu' su Windows (dopo Tools/dispositivo-windows.ps1, con OrbitLR gia' installata):
# registro (clic destro, disinstallazione, .orbitlr), Ctrl+Alt+C, icona vicino all'orologio,
# clic destro vero da Esplora file, una sola OrbitLR, caratteri ed emoji in WebView2 (porta di debug),
# e WebView2 tolto: cosa fa l'app e cosa fa l'installazione.
# Uso: pwsh -File Tests/Agenti/W03/extra-windows.ps1 -Out cartella -Setup OrbitLR-Setup.exe
param([string]$Out = "extra", [string]$Setup = "OrbitLR-Setup.exe", [switch]$TogliWebView2)

$ErrorActionPreference = "Continue"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Out = (Resolve-Path $Out).Path
$Setup = (Resolve-Path $Setup).Path
$Cdp = Join-Path $PSScriptRoot "cdp.mjs"
$Info = Join-Path $Out "extra.txt"
function Note([string]$m) { $l = "$(Get-Date -Format HH:mm:ss) $m"; Add-Content -Path $Info -Value $l -Encoding utf8; Write-Host $l }

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type @"
using System; using System.Runtime.InteropServices; using System.Text;
public static class X {
  [DllImport("user32.dll", SetLastError=true)] public static extern bool RegisterHotKey(IntPtr h, int id, uint mods, uint vk);
  [DllImport("user32.dll", SetLastError=true)] public static extern bool UnregisterHotKey(IntPtr h, int id);
  [DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr extra);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int c);
  [DllImport("user32.dll")] public static extern IntPtr FindWindow(string c, string t);
  public delegate bool EnumProc(IntPtr h, IntPtr l);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc f, IntPtr l);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  public static string Windows(uint pid) {
    var sb = new StringBuilder();
    EnumWindows((h, l) => { uint p; GetWindowThreadProcessId(h, out p); if (p != pid) return true;
      var t = new StringBuilder(256); GetWindowText(h, t, 256); var c = new StringBuilder(256); GetClassName(h, c, 256);
      if (IsWindowVisible(h) || t.Length > 0) sb.Append("[" + c + " «" + t + "» " + (IsWindowVisible(h) ? "visibile" : "nascosta") + "] ");
      return true; }, IntPtr.Zero);
    return sb.ToString();
  }
  public static void CtrlAltC() {
    keybd_event(0x11, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x43, 0, 0, UIntPtr.Zero);
    System.Threading.Thread.Sleep(80);
    keybd_event(0x43, 0, 2, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero); keybd_event(0x11, 0, 2, UIntPtr.Zero);
  }
  public static void AltTap() { keybd_event(0x12, 0, 0, UIntPtr.Zero); keybd_event(0x12, 0, 2, UIntPtr.Zero); }
}
"@

function Foto([string]$nome) {
  try {
    $vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
    $bmp = New-Object System.Drawing.Bitmap $vs.Width, $vs.Height
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($vs.Location, [System.Drawing.Point]::Empty, $vs.Size)
    $bmp.Save((Join-Path $Out "$nome.png"), [System.Drawing.Imaging.ImageFormat]::Png)
    $g.Dispose(); $bmp.Dispose()
  } catch { Note "foto $nome non riuscita: $_" }
}
function Ferma() {
  Get-Process orbitlr -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 3
}
function WV2() {
  $a = (Get-ItemProperty "HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -ErrorAction SilentlyContinue).pv
  $b = (Get-ItemProperty "HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}" -ErrorAction SilentlyContinue).pv
  $d = (Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application" -Directory -ErrorAction SilentlyContinue | Where-Object Name -match '^\d' | ForEach-Object Name) -join ","
  "macchina=$(if ($a) { $a } else { '-' }) utente=$(if ($b) { $b } else { '-' }) cartella=$(if ($d) { $d } else { '-' })"
}
function Hotkey([string]$quando) {
  $ok = [X]::RegisterHotKey([IntPtr]::Zero, 7703, 0x0003 -bor 0x4000, 0x43)
  $err = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
  if ($ok) { [X]::UnregisterHotKey([IntPtr]::Zero, 7703) | Out-Null }
  Note "Ctrl+Alt+C ($quando): un'altra app $(if ($ok) { 'PUO'' prenderla (libera)' } else { "NON puo' prenderla (codice $err, 1409 = gia' registrata)" })"
}
function Pagina([string]$nome, [int]$attesa = 3000) {
  $j = Join-Path $Out "$nome.json"
  & node $Cdp $j (Join-Path $Out "$nome-pagina.png") $attesa 2>&1 | ForEach-Object { Note "cdp $nome · $_" }
  if (Test-Path $j) { return (Get-Content $j -Raw | ConvertFrom-Json) }
  return $null
}
$Exe = Join-Path $env:LOCALAPPDATA "OrbitLR\orbitlr.exe"
$Dbg = "--lang=it --remote-debugging-port=9222"
function Avvia([string[]]$argomenti = @()) {
  [Environment]::SetEnvironmentVariable("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", $Dbg)
  $p = if ($argomenti.Count) { Start-Process -FilePath $Exe -ArgumentList $argomenti -PassThru } else { Start-Process -FilePath $Exe -PassThru }
  [Environment]::SetEnvironmentVariable("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", $null)
  return $p
}
# Il clic destro dal registro, come lo lancia Esplora file (con la variabile per la porta di debug)
[Environment]::SetEnvironmentVariable("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", $Dbg)

# ── Il computer
$os = Get-CimInstance Win32_OperatingSystem
Note "sistema: $($os.Caption) $($os.Version) build $($os.BuildNumber)"
Note "WebView2: $(WV2)"
Note "Edge: $((Get-Item "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe" -ErrorAction SilentlyContinue).VersionInfo.ProductVersion)"
foreach ($f in "seguiemj.ttf", "SegUIVar.ttf", "segoeui.ttf", "seguisym.ttf") { Note "carattere $f nel sistema: $(Test-Path "$env:windir\Fonts\$f")" }
$mf = Get-WindowsFeature Server-Media-Foundation -ErrorAction SilentlyContinue
Note "Media Foundation (funzione di Windows Server): $(if ($mf) { $mf.InstallState } else { 'non so' })"
Note "orbitlr.exe: $Exe $(Test-Path $Exe) · versione $((Get-Item $Exe -ErrorAction SilentlyContinue).VersionInfo.FileVersion)"
$ff = Join-Path $env:LOCALAPPDATA "OrbitLR\motori\ffmpeg.exe"
Note "ffmpeg dell'app: $((& $ff -hide_banner -version 2>&1 | Select-Object -First 1))"
& $ff -hide_banner -loglevel error -f lavfi -i "color=c=gray:s=320x240:d=0.2:r=10" -pix_fmt nv12 -c:v h264_mf -b:v 500k -f null - 2>&1 | Select-Object -First 3 | ForEach-Object { Note "h264_mf: $_" }
Note "h264_mf: codice $LASTEXITCODE"
foreach ($e in "hevc_mf", "aac_mf") { & $ff -hide_banner -loglevel error -f lavfi -i "color=c=gray:s=320x240:d=0.2:r=10" -f lavfi -i "sine=d=0.2" -pix_fmt nv12 -c:v $(if ($e -eq 'aac_mf') { 'mpeg4' } else { $e }) -c:a $(if ($e -eq 'aac_mf') { 'aac_mf' } else { 'aac' }) -f null - 2>&1 | Out-Null; Note "${e}: codice $LASTEXITCODE" }

# ── Registro
foreach ($k in 'HKCU:\Software\Classes\*\shell\OrbitLR', 'HKCU:\Software\Classes\*\shell\OrbitLR\command', 'HKCU:\Software\Classes\Directory\shell\OrbitLR', 'HKCU:\Software\Classes\Directory\shell\OrbitLR\command') {
  $v = Get-ItemProperty -LiteralPath $k -ErrorAction SilentlyContinue
  Note "registro $k : $(if ($v) { ($v.PSObject.Properties | Where-Object Name -notmatch '^PS' | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ' | ' } else { 'NON C''E''' })"
}
$un = Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { $_.DisplayName -like "OrbitLR*" }
foreach ($u in $un) { Note "disinstallazione: $($u.DisplayName) $($u.DisplayVersion) · Publisher=$($u.Publisher) · DisplayIcon=$($u.DisplayIcon) · UninstallString=$($u.UninstallString) · QuietUninstallString=$($u.QuietUninstallString) · EstimatedSize=$($u.EstimatedSize)" }
Note ".orbitlr: assoc=$((cmd /c assoc .orbitlr 2>&1) -join ' ') · HKCU Classes .orbitlr: $(Test-Path 'HKCU:\Software\Classes\.orbitlr') · HKCR: $(Test-Path 'Registry::HKEY_CLASSES_ROOT\.orbitlr')"
$lnk = Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs", "$env:USERPROFILE\Desktop" -Recurse -Filter "OrbitLR*.lnk" -ErrorAction SilentlyContinue
Note "collegamenti: $(($lnk | ForEach-Object FullName) -join ' · ')"

# ── File di prova con accenti (nomi diversi per riconoscerli nella pagina)
$dir = Join-Path ([Environment]::GetFolderPath("MyDocuments")) "W03 prova è"
New-Item -ItemType Directory -Force -Path $dir | Out-Null
& $ff -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=25:duration=3" -c:v mpeg4 "$dir\Destro uno è.mp4" 2>&1 | Out-Null
foreach ($n in "Scorciatoia ë", "Multi A", "Multi B", "Multi C") { & $ff -hide_banner -loglevel error -y -f lavfi -i "color=c=orange:s=400x300" -frames:v 1 "$dir\$n.png" 2>&1 | Out-Null }
New-Item -ItemType Directory -Force -Path "$dir\Cartella ù" | Out-Null
Copy-Item "$dir\Multi A.png" "$dir\Cartella ù\Dentro.png" -Force
Note "file: $((Get-ChildItem $dir | ForEach-Object Name) -join ' · ')"

# ── Il clic destro c'e' davvero nel menu di Esplora file?
$sh = New-Object -ComObject Shell.Application
$ns = $sh.Namespace($dir)
$item = $ns.ParseName("Destro uno è.mp4")
$verbi = @($item.Verbs() | ForEach-Object { $_.Name })
Note "menu del file: $(($verbi | Where-Object { $_ }) -join ' | ')"
Note "«Apri con OrbitLR» nel menu del file: $([bool]($verbi -match 'OrbitLR'))"
$cart = $ns.ParseName("Cartella ù")
Note "«Apri con OrbitLR» nel menu della cartella: $([bool](@($cart.Verbs() | ForEach-Object { $_.Name }) -match 'OrbitLR'))"

Ferma
Hotkey "OrbitLR chiusa"

# ── 1. Avvio a freddo con il clic destro (Esplora file lancia orbitlr.exe "file")
$t0 = Get-Date
$item.InvokeVerb("Apri con OrbitLR")
Start-Sleep -Seconds 20
$procs = @(Get-Process orbitlr -ErrorAction SilentlyContinue)
Note "1 · clic destro a freddo: processi orbitlr $($procs.Count) · finestre: $(if ($procs) { [X]::Windows([uint32]$procs[0].Id) })"
Foto "e1-clic-destro-freddo"
$pg = Pagina "e1-clic-destro-freddo" 3000
if ($pg) {
  Note "1 · pagina: $($pg.url) · $($pg.ua)"
  Note "1 · il nome «Destro uno è» nella pagina: $($pg.text -match 'Destro uno')"
  Note "1 · console: $(($pg.console | Where-Object { $_.type -in 'error','warning','assert' } | ForEach-Object { "[$($_.type)] $($_.text)" }) -join ' || ')"
  Note "1 · eccezioni: $(($pg.exceptions) -join ' || ')"
  Note "1 · registro: $(($pg.log | Where-Object { $_.level -in 'error','warning' } | ForEach-Object { "[$($_.level)/$($_.source)] $($_.text) $($_.url)" }) -join ' || ')"
  Note "1 · caratteri caricati: $(($pg.fontsLoaded) -join ', ')"
  foreach ($p in $pg.platformFonts.PSObject.Properties) { Note "1 · caratteri usati $($p.Name): $(($p.Value | ForEach-Object { "$($_.familyName)$(if ($_.isCustomFont) { ' (dell''app)' }) ×$($_.glyphCount)" }) -join ', ')" }
  Note "1 · emoji a colori: $($pg.emojiColorPixels) pixel colorati"
}
Hotkey "OrbitLR aperta"

# ── 2. Icona vicino all'orologio (UI Automation, con Windows PowerShell)
$uia = @'
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes
$root = [System.Windows.Automation.AutomationElement]::RootElement
$out = @()
foreach ($cls in "Shell_TrayWnd", "NotifyIconOverflowWindow", "TopLevelWindowForOverflowXamlIsland") {
  $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, $cls)
  foreach ($w in $root.FindAll([System.Windows.Automation.TreeScope]::Children, $c)) {
    foreach ($e in $w.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) {
      $n = $e.Current.Name; if ($n) { $out += "$cls/$($e.Current.ControlType.ProgrammaticName -replace 'ControlType.','')/$n" }
    }
  }
}
$out -join "`n"
'@
$uiaFile = Join-Path $Out "uia-tray.ps1"; Set-Content $uiaFile $uia -Encoding utf8
$tray = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $uiaFile 2>&1
Set-Content (Join-Path $Out "barra-applicazioni.txt") $tray -Encoding utf8
Note "2 · icona OrbitLR nella barra: $(($tray | Where-Object { $_ -match 'OrbitLR' }) -join ' · ')$(if (-not ($tray | Where-Object { $_ -match 'OrbitLR' })) { 'NON TROVATA (elementi letti: ' + @($tray).Count + ')' })"
$ns2 = Get-ChildItem "HKCU:\Control Panel\NotifyIconSettings" -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { $_.ExecutablePath -match 'orbitlr' }
Note "2 · NotifyIconSettings (solo Windows 11/2025): $(if ($ns2) { ($ns2 | ForEach-Object { "$($_.ExecutablePath) promoted=$($_.IsPromoted) tooltip=$($_.InitialTooltip)" }) -join ' · ' } else { 'niente' })"
# Foto dell'angolo in basso a destra
try {
  $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
  $bmp = New-Object System.Drawing.Bitmap 420, 60; $g = [System.Drawing.Graphics]::FromImage($bmp)
  $g.CopyFromScreen($b.Right - 420, $b.Bottom - 60, 0, 0, $bmp.Size); $bmp.Save((Join-Path $Out "e2-orologio.png")); $g.Dispose(); $bmp.Dispose()
} catch { Note "foto orologio: $_" }

# ── 3. Clic destro con OrbitLR gia' aperta: deve restare una sola OrbitLR, il file arriva nella finestra
$cart.InvokeVerb("Apri con OrbitLR")
Start-Sleep -Seconds 8
$procs = @(Get-Process orbitlr -ErrorAction SilentlyContinue)
Note "3 · clic destro su una cartella con OrbitLR aperta: processi orbitlr $($procs.Count)"
$pg = Pagina "e3-cartella" 2000
if ($pg) { Note "3 · «Dentro» o «Cartella ù» nella pagina: $($pg.text -match 'Dentro|Cartella')" }
Foto "e3-cartella"

# ── 4. Piu' file insieme dal clic destro (MultiSelectModel=Player)
try {
  $its = $ns.Items(); $its.Filter(0x40, "Multi *.png")
  Note "4 · selezionati per il clic destro: $($its.Count)"
  $its.InvokeVerbEx("Apri con OrbitLR")
} catch { Note "4 · InvokeVerbEx non riuscito: $_" }
Start-Sleep -Seconds 10
$procs = @(Get-Process orbitlr -ErrorAction SilentlyContinue)
Note "4 · processi orbitlr: $($procs.Count)"
$pg = Pagina "e4-tre-file" 2000
if ($pg) { Note "4 · nella pagina: Multi A $($pg.text -match 'Multi A') · Multi B $($pg.text -match 'Multi B') · Multi C $($pg.text -match 'Multi C')" }
Foto "e4-tre-file"

# ── 5. Ctrl+Alt+C con un file selezionato in Esplora file
Start-Process explorer.exe $dir
Start-Sleep -Seconds 6
$ew = $null
foreach ($w in $sh.Windows()) { try { if ($w.Document.Folder.Self.Path -eq $dir) { $ew = $w } } catch {} }
if ($ew) {
  $sel = $ew.Document.Folder.ParseName("Scorciatoia ë.png")
  $ew.Document.SelectItem($sel, 1 + 4 + 8 + 16)
  Start-Sleep -Seconds 1
  [X]::AltTap(); [X]::ShowWindow([IntPtr]$ew.HWND, 9) | Out-Null
  $fg = [X]::SetForegroundWindow([IntPtr]$ew.HWND)
  Start-Sleep -Milliseconds 800
  Note "5 · Esplora file in primo piano: $fg (primo piano = Esplora: $([X]::GetForegroundWindow() -eq [IntPtr]$ew.HWND)) · selezionati: $(($ew.Document.SelectedItems() | ForEach-Object Name) -join ', ')"
  Foto "e5-prima-di-ctrl-alt-c"
  $t0 = Get-Date
  [X]::CtrlAltC()
  Start-Sleep -Seconds 10
  $fg2 = [X]::GetForegroundWindow(); $sb = New-Object System.Text.StringBuilder 256; [X]::GetWindowText($fg2, $sb, 256) | Out-Null
  Note "5 · dopo Ctrl+Alt+C, in primo piano: «$($sb.ToString())»"
  $pg = Pagina "e5-ctrl-alt-c" 2000
  if ($pg) { Note "5 · «Scorciatoia ë» nella pagina: $($pg.text -match 'Scorciatoia')" }
  Foto "e5-dopo-ctrl-alt-c"
} else { Note "5 · finestra di Esplora file non trovata: $(($sh.Windows() | ForEach-Object { try { $_.LocationURL } catch {} }) -join ' · ')" }

# ── 6. Tempo di avvio e memoria dopo i lavori
$procs = @(Get-Process orbitlr -ErrorAction SilentlyContinue)
Note "6 · orbitlr vivi: $($procs.Count) · memoria $(($procs | ForEach-Object { [math]::Round($_.WorkingSet64/1MB) }) -join ',') MB · WebView2 $((Get-Process msedgewebview2 -ErrorAction SilentlyContinue).Count) processi"
Ferma
[Environment]::SetEnvironmentVariable("WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS", $null)

if (-not $TogliWebView2) { Note "fine (WebView2 non tolto)"; exit 0 }

# ── 7. WebView2 tolto: cosa fa OrbitLR, cosa fa la sua installazione
$wsetup = Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application\*\Installer\setup.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
Note "7 · programma per togliere WebView2: $($wsetup.FullName)"
if ($wsetup) {
  $p = Start-Process $wsetup.FullName -ArgumentList "--uninstall", "--msedgewebview", "--system-level", "--verbose-logging", "--force-uninstall" -PassThru -Wait
  Note "7 · WebView2 tolto: codice $($p.ExitCode) · ora: $(WV2)"
}
Get-Process msedgewebview2 -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$t0 = Get-Date
$app = Start-Process -FilePath $Exe -PassThru
Start-Sleep -Seconds 15
$vivo = Get-Process -Id $app.Id -ErrorAction SilentlyContinue
Note "7 · OrbitLR senza WebView2: $(if ($vivo) { "VIVA dopo 15 s · finestre: $([X]::Windows([uint32]$app.Id))" } else { "CHIUSA (codice $($app.ExitCode)) dopo $([math]::Round(((Get-Date)-$t0).TotalSeconds)) s" })"
# Finestre di messaggio aperte da qualcuno (errore di avvio)?
$msg = @(); foreach ($pp in Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowTitle }) { $msg += "$($pp.ProcessName): «$($pp.MainWindowTitle)»" }
Note "7 · finestre con titolo: $($msg -join ' · ')"
Foto "e7-senza-webview2"
Get-WinEvent -FilterHashtable @{ LogName = "Application"; StartTime = $t0.AddSeconds(-5) } -ErrorAction SilentlyContinue | Where-Object { $_.Message -match 'orbitlr' } | Select-Object -First 5 | ForEach-Object { Note "7 · evento $($_.ProviderName) $($_.Id): $(($_.Message -split "`n" | Select-Object -First 4) -join ' ')" }
Ferma

# Installazione di nuovo (silenziosa): deve scaricare e mettere WebView2 da sola
$t0 = Get-Date
$inst = Start-Process $Setup -ArgumentList "/S" -PassThru
$finito = $inst.WaitForExit(600000)
Note "7 · reinstallazione /S: $(if ($finito) { "finita, codice $($inst.ExitCode)" } else { 'NON finita in 10 minuti' }) in $([math]::Round(((Get-Date)-$t0).TotalSeconds)) s · WebView2 ora: $(WV2)"
Foto "e7-dopo-reinstallazione"
Get-ChildItem $env:TEMP -Filter "MicrosoftEdgeWebview2Setup*" -ErrorAction SilentlyContinue | ForEach-Object { Note "7 · scaricato: $($_.FullName) $($_.Length)" }
$app = Avvia
Start-Sleep -Seconds 20
$vivo = Get-Process -Id $app.Id -ErrorAction SilentlyContinue
Note "7 · OrbitLR dopo la reinstallazione: $(if ($vivo) { "VIVA · finestre: $([X]::Windows([uint32]$app.Id))" } else { "CHIUSA (codice $($app.ExitCode))" })"
$pg = Pagina "e7-dopo" 3000
if ($pg) { Note "7 · pagina: $($pg.ua) · testo: $(($pg.text -split "`n" | Select-Object -First 6) -join ' / ')" }
Foto "e7-app-dopo"
Ferma
Note "fine"
