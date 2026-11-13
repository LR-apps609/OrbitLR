# Tester20 · P02 «Prima volta, poco pratico» (windows-2025): scarica, installa in silenzio, primo avvio con profilo nuovo
# (benvenuto), comprime un video del telefono, il risultato è dove se lo aspetta.
param([string]$Setup, [string]$Out)
$Profilo = "P02"
. "$PSScriptRoot\comune.ps1"
Info

# 1. Installazione
$exe = Installa $Setup
if (-not (Passo "installazione silenziosa per l'utente" ([bool]$exe) "$($script:InstModo) · $($script:InstSec) s")) {
  Bug "L'installazione silenziosa (/S) non installa OrbitLR" "bloccante" @("Scarica OrbitLR-Windows-2.0.1-Setup.exe", "Avvia «OrbitLR-Windows-2.0.1-Setup.exe /S»") "orbitlr.exe in %LOCALAPPDATA%\OrbitLR" "nessun orbitlr.exe dopo 8 minuti" "diario.txt, installazione-ferma.png"
  Salva "p02"; exit 0
}
$uninst = Get-ChildItem HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall -ErrorAction SilentlyContinue | Get-ItemProperty | Where-Object { $_.DisplayName -like "OrbitLR*" } | Select-Object -First 1
Passo "registrata tra i programmi dell'utente" ([bool]$uninst) "$($uninst.DisplayName) $($uninst.DisplayVersion)" | Out-Null
$lnk = @(Get-ChildItem "$env:APPDATA\Microsoft\Windows\Start Menu\Programs", ([Environment]::GetFolderPath("Desktop")) -Recurse -Filter "OrbitLR*.lnk" -ErrorAction SilentlyContinue)
Passo "collegamento nel menu Start o sul desktop" ($lnk.Count -gt 0) (($lnk | ForEach-Object Name) -join ", ") | Out-Null
if ($uninst -and $uninst.DisplayVersion -and $uninst.DisplayVersion -notlike "2.0.1*") { Confuso "versione nei Programmi" "dice $($uninst.DisplayVersion) ma il file è la 2.0.1" }

# 2. Primo avvio con profilo nuovo: il benvenuto
Remove-Item "$env:LOCALAPPDATA\it.ledion.orbitlr", "$env:APPDATA\it.ledion.orbitlr" -Recurse -Force -ErrorAction SilentlyContinue
# Prima si prova il DevTools (CDP) di WebView2 per una foto della pagina; se non c'è, foto della finestra + OCR
$cdpPort = 9333
$r = Avvia "1-primo-avvio" @{ WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS = "--lang=it --remote-debugging-port=$cdpPort" } 20 -Resta
Passo "primo avvio: finestra aperta" ($r.viva -and $r.finestra_s) "finestra dopo $($r.finestra_s) s" | Out-Null
if ($r.finestra_s -gt 15) { Confuso "primo avvio lento" "la finestra compare dopo $($r.finestra_s) s" }
$cdp = $false
try { $c = New-Object Net.Sockets.TcpClient; $c.Connect("127.0.0.1", $cdpPort); $cdp = $c.Connected; $c.Close() } catch {}
$benvenuto = $null
if ($cdp) {
  $j = & node (Join-Path $PSScriptRoot "cdp.mjs") $cdpPort (Join-Path $Out "1-primo-avvio-cdp.png") "!!document.querySelector('.modal.welcome') && document.querySelector('.modal.welcome').innerText.slice(0,200)" 2>&1 | Out-String
  Log "CDP: $j"
  $benvenuto = $j -match "true|Benvenut|OrbitLR"
} else {
  NonEseguito "foto del benvenuto con il DevTools (CDP) di WebView2" "la porta $cdpPort non si apre: WebView2 di OrbitLR ignora --remote-debugging-port (come W02); usata la foto della finestra con l'OCR di Windows"
  $t = Ocr $r.foto
  Log "OCR primo avvio: $($t -replace "`n", ' | ')"
  if ($script:OcrOk) { $benvenuto = $t -match "(?i)benvenut|cominciamo|avanti|salta" }
}
if ($null -eq $benvenuto) { NonEseguito "controllo del testo del benvenuto" "né CDP né OCR disponibili: c'è solo la foto 1-primo-avvio.png" }
elseif (-not (Passo "primo avvio: si vede il benvenuto" $benvenuto)) {
  Bug "Al primo avvio con profilo nuovo non compare il benvenuto" "medio" @("Installa OrbitLR", "Aprila per la prima volta (profilo nuovo)") "La finestra di benvenuto (1/3, «Avanti», «Salta»)" "nella finestra non c'è il testo del benvenuto (OCR)" "1-primo-avvio.png, 1-primo-avvio.ocr.txt"
}
Log "chiusura: $(ChiudiBene)"

# 3. Secondo avvio: il benvenuto non torna
$r2 = Avvia "2-secondo-avvio" @{} 12
$t2 = Ocr $r2.foto
if ($script:OcrOk) {
  if (-not (Passo "secondo avvio: niente benvenuto di nuovo" (-not ($t2 -match "(?i)benvenut")))) {
    Bug "Il benvenuto ricompare a ogni avvio" "basso" @("Apri OrbitLR, chiudi con la ✕", "Riaprila") "Il benvenuto solo la prima volta" "c'è di nuovo il benvenuto" "2-secondo-avvio.png"
  }
}

# 4. Un video del telefono (verticale, con la rotazione nei metadati come quelli di iPhone/Android) nei Download
$dl = Join-Path $env:USERPROFILE "Downloads"; New-Item -ItemType Directory -Force $dl | Out-Null
$vidNome = "VID_20261113_101500"
$tmp = Join-Path $env:TEMP "t20-$vidNome.mp4"
Video $tmp 15 "1920x1080" 30 | Out-Null
$vid = Join-Path $dl "$vidNome.mp4"
& $script:Ff -hide_banner -loglevel error -y -display_rotation 90 -i $tmp -c copy $vid 2>&1 | ForEach-Object { Log "rotazione: $_" }
if (-not (Test-Path $vid)) { Copy-Item $tmp $vid; Nota "ffmpeg dell'app non accetta -display_rotation: video senza rotazione" }
$pin = Probe $vid
Log "video del telefono: $((Get-Item $vid).Length) byte · vista $(Vista $pin) · rotazione $(Rotazione $pin) · $($pin.format.duration) s"
$r3 = Avvia "3-comprimi-video" @{ ORBIT_PROVA_FILE = $vid; ORBIT_PROVA_SCHEDA = "video"; ORBIT_PROVA_AZIONE = "vcompress"; ORBIT_PROVA_PARAMETRO = "best" } 240 { [bool](Get-ChildItem $dl -Filter "$vidNome *.mp4" -ErrorAction SilentlyContinue | Where-Object { $_.Length -gt 0 -and $_.Name -notlike "*.orbitlr-*" }) } -Resta
Start-Sleep -Seconds 3
$ris = Get-ChildItem $dl -Filter "$vidNome *.mp4" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*.orbitlr-*" } | Select-Object -First 1
$t3 = Ocr $r3.foto
Log "OCR dopo la compressione: $($t3 -replace "`n", ' | ')"
if (Passo "comprimi: il risultato è accanto all'originale nei Download" ([bool]$ris) "$(if ($ris) { "$($ris.Name) $($ris.Length) byte in $($r3.finito_s) s" } else { 'nessun file in 4 minuti' })") {
  $po = Probe $ris.FullName
  $dIn = [double]$pin.format.duration; $dOut = [double]$po.format.duration
  Passo "comprimi: durata uguale" ([math]::Abs($dIn - $dOut) -lt 0.6) "$dIn → $dOut s" | Out-Null
  $aud = [bool]($po.streams | Where-Object { $_.codec_type -eq "audio" })
  if (-not (Passo "comprimi: l'audio c'è ancora" $aud)) { Bug "Comprimi un video del telefono: l'audio sparisce" "alto" @("Metti un video del telefono (con audio) in Video", "Comprimi «Migliore»") "Video compresso con l'audio" "nessuna traccia audio nel risultato" "ffprobe di $($ris.Name)" }
  $vIn = Vista $pin; $vOut = Vista $po
  if (-not (Passo "comprimi: resta verticale come sul telefono" ($vIn -eq $vOut) "prima $vIn (rotazione $(Rotazione $pin)) · dopo $vOut (rotazione $(Rotazione $po))")) {
    Bug "Comprimi un video del telefono: il risultato è girato (non più verticale)" "alto" @("Registra un video in verticale col telefono (metadati di rotazione 90°)", "In OrbitLR: Video → Comprimi → Migliore") "Il video compresso si vede in verticale come l'originale ($vIn)" "si vede $vOut (rotazione $(Rotazione $po))" "ffprobe prima/dopo nel diario"
  }
  $small = $ris.Length -lt (Get-Item $vid).Length
  if (-not (Passo "comprimi: più leggero dell'originale" $small "$((Get-Item $vid).Length) → $($ris.Length) byte")) { Confuso "comprimi un video" "il risultato pesa più dell'originale ($((Get-Item $vid).Length) → $($ris.Length) byte)" }
  if ($ris.Name -notmatch "compress") { Confuso "nome del risultato" "«$($ris.Name)»: non si capisce che è la versione compressa" }
} else {
  Bug "Comprimi un video del telefono: nessun risultato" "alto" @("Metti VID_20261113_101500.mp4 (verticale, 15 s) nei Download", "OrbitLR → Video → Comprimi → Migliore") "«VID_20261113_101500 (compresso).mp4» accanto all'originale" "nessun file in 4 minuti; app $(if ($r3.viva) { 'aperta' } else { 'chiusa' })" "3-comprimi-video.png, .ocr.txt"
}
$av = Avanzi $dl
Passo "nessun file a metà nei Download" ($av.Count -eq 0) (($av | ForEach-Object Name) -join ", ") | Out-Null
Log "chiusura: $(ChiudiBene)"
$ew = ErroriWindows
if (-not (Passo "nessun errore di Windows su OrbitLR/WebView2" ($ew.Count -eq 0) ($ew -join " || "))) { Nota "errori di Windows: $($ew -join ' || ')" }
Salva "p02"
