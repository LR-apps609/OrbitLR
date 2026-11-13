# Tester20 · P17 «Windows 11 ARM» (windows-11-arm): installa, apre, un lavoro vero per tipo (immagine, video, audio, PDF)
# dentro l'app (variabili ORBIT_PROVA_*), con i tempi.
param([string]$Setup, [string]$Out)
$Profilo = "P17"
. "$PSScriptRoot\comune.ps1"
Info
# Su windows-11-arm all'inizio c'è la finestra della prima configurazione (WWAHost) sopra tutto (W02)
Get-Process WWAHost, UserOOBEBroker -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
$exe = Installa $Setup
if (-not (Passo "installazione silenziosa su ARM" ([bool]$exe) "$($script:InstModo) · $($script:InstSec) s")) {
  Bug "Su Windows 11 ARM l'installazione silenziosa non installa OrbitLR" "bloccante" @("OrbitLR-Windows-2.0.1-Setup.exe /S su Windows 11 ARM") "OrbitLR installata" "non installata" "diario.txt"; Salva "p17"; exit 0
}
# Architettura dei programmi (intestazione PE)
function Arch([string]$f) { try { $b = [IO.File]::ReadAllBytes($f); $pe = [BitConverter]::ToInt32($b, 0x3C); switch ([BitConverter]::ToUInt16($b, $pe + 4)) { 0x8664 { "x64" } 0xAA64 { "arm64" } 0x14C { "x86" } default { "?" } } } catch { "?" } }
Nota "architettura: orbitlr.exe $(Arch $exe) · ffmpeg.exe $(Arch $script:Ff) · computer $env:PROCESSOR_ARCHITECTURE"
if ((Arch $exe) -eq "x64" -and $env:PROCESSOR_ARCHITECTURE -eq "ARM64") { Nota "OrbitLR gira emulata (x64 su ARM, Prism): niente versione arm64 (già visto da W02)" }

$r = Avvia "1-primo-avvio" @{} 25
Passo "primo avvio su ARM: finestra aperta" ($r.viva -and $r.finestra_s) "finestra dopo $($r.finestra_s) s" | Out-Null
$r2 = Avvia "2-secondo-avvio" @{} 10
Nota "tempo alla finestra: primo avvio $($r.finestra_s) s, secondo $($r2.finestra_s) s"

$casa = Join-Path $env:USERPROFILE "Documents\Prova ARM"
New-Item -ItemType Directory -Force $casa | Out-Null
$t0 = Get-Date
Immagine "$casa\Foto grande.png" "3000x2000" | Out-Null
Copy-Item (Join-Path $PSScriptRoot "..\..\..\Windows\engine\tests\fixtures\iphone-gps.heic") "$casa\Dall iPhone.heic"
Video "$casa\Gita.mp4" 15 "1920x1080" 30 | Out-Null
Audio "$casa\Nota vocale.wav" 30 | Out-Null
NuovoPdf "$casa\Contratto.pdf" 3 | Out-Null
Nota "file di prova creati con l'ffmpeg dell'app in $([math]::Round(((Get-Date) - $t0).TotalSeconds)) s: $((Get-ChildItem $casa | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ' · ')"

$lavori = @(
  @{ n = "immagine PNG → JPG"; f = "Foto grande.png"; s = "image"; a = "to:jpg"; p = ""; out = "Foto grande*.jpg" },
  @{ n = "immagine HEIC → JPG"; f = "Dall iPhone.heic"; s = "image"; a = "to:jpg"; p = ""; out = "Dall iPhone*.jpg" },
  @{ n = "video comprimi (migliore)"; f = "Gita.mp4"; s = "video"; a = "vcompress"; p = "best"; out = "Gita *.mp4" },
  @{ n = "audio WAV → MP3"; f = "Nota vocale.wav"; s = "audio"; a = "to:mp3"; p = ""; out = "Nota vocale*.mp3" },
  @{ n = "PDF comprimi"; f = "Contratto.pdf"; s = "pdf"; a = "pdfcompress"; p = "medium"; out = "Contratto *.pdf" }
)
$tempi = @()
foreach ($l in $lavori) {
  $pat = $l.out
  $r = Avvia "3-$($l.a -replace ':', '-')-$($l.f -replace '\W', '')" @{ ORBIT_PROVA_FILE = "$casa\$($l.f)"; ORBIT_PROVA_SCHEDA = $l.s; ORBIT_PROVA_AZIONE = $l.a; ORBIT_PROVA_PARAMETRO = $l.p } 300 { [bool](Get-ChildItem $casa -Filter $pat -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 -and $_.Name -ne $l.f -and $_.Name -notlike "*.orbitlr-*" }) }
  $o = Get-ChildItem $casa -Filter $pat -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne $l.f -and $_.Name -notlike "*.orbitlr-*" } | Select-Object -First 1
  $valido = $false
  if ($o) {
    if ($o.Extension -eq ".pdf") { $txt = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($o.FullName)); $valido = $txt.StartsWith("%PDF") -and $txt.Contains("%%EOF") }
    else { $po = Probe $o.FullName; $valido = [bool]$po -and [bool]($po.streams) }
  }
  $tempi += "$($l.n): $(if ($r.finito_s) { "$($r.finito_s) s" } else { 'non finito' })"
  if (-not (Passo "ARM · $($l.n)" ($o -and $valido) "$(if ($o) { "$($o.Name) $($o.Length) byte in $($r.finito_s) s (dall'avvio)" } else { 'nessun risultato in 5 minuti' })")) {
    Bug "Windows 11 ARM: «$($l.n)» non produce il file" "alto" @("Windows 11 ARM, OrbitLR 2.0.1", "$($l.f) → $($l.a)") "Il file convertito accanto all'originale" "$(if ($o) { "file non valido: $($o.Name)" } else { "nessun file in 5 minuti; app $(if ($r.viva) { 'aperta' } else { 'chiusa' })" })" "$($r.nome).png"
  }
}
Nota "tempi su ARM (dall'avvio dell'app al file finito): $($tempi -join ' · ')"
$ew = ErroriWindows
Passo "nessun errore di Windows su OrbitLR" ($ew.Count -eq 0) ($ew -join " || ") | Out-Null
Salva "p17"
