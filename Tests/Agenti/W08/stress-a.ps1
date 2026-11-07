# W08 - parte A: CPU e memoria a riposo, 300 file in un lavoro, un file da 3 GB,
# chiusura durante un lavoro (con la domanda e con taskkill /F), avanzi e pulizia al riavvio.
param([string]$Out = "w08-a")
. "$PSScriptRoot\comune.ps1"

Installa
$W = "C:\W08"
New-Item -ItemType Directory -Force -Path $W | Out-Null

# ---------------------------------------------------------------- 1. A riposo
Ferma
$p = Avvia
Start-Sleep -Seconds 15
Foto "a1-primo-avvio-15s"
$r = Osserva "riposo-1-benvenuto" 60
Esito "riposo con il benvenuto aperto" $(if ($r.cpuTotMacchina -lt 1) { "OK" } else { "BUG" }) "CPU macchina $($r.cpuTotMacchina)% (app $($r.cpuAppCore)% di un core, WebView2 $($r.cpuWvCore)% di un core, $script:NCPU thread) - memoria app $($r.wsAppFine) MB, WebView2 $($r.wsWvFine) MB ($((Get-Process msedgewebview2 -EA SilentlyContinue).Count) processi)"
ChiudiBenvenuto
Start-Sleep -Seconds 5
Foto "a1-dopo-esc"
$r = Osserva "riposo-2-finestra" 90
$riposoWs = $r.wsAppFine + $r.wsWvFine
Esito "riposo con la finestra aperta (90 s)" $(if ($r.cpuTotMacchina -lt 1) { "OK" } else { "BUG" }) "CPU macchina $($r.cpuTotMacchina)% (app $($r.cpuAppCore)%, WebView2 $($r.cpuWvCore)% di un core) - memoria app $($r.wsAppFine) MB (privata max $($r.privAppMax)), WebView2 $($r.wsWvFine) MB - handle $($r.handlesInizio)->$($r.handlesFine)"
$h = Finestra
if ($h -ne [IntPtr]::Zero) { [W8]::ShowWindow($h, 6) | Out-Null }
Start-Sleep -Seconds 3
$r = Osserva "riposo-3-ridotta" 60
Esito "riposo con la finestra ridotta a icona (60 s)" $(if ($r.cpuTotMacchina -lt 1) { "OK" } else { "BUG" }) "CPU macchina $($r.cpuTotMacchina)% (app $($r.cpuAppCore)%, WebView2 $($r.cpuWvCore)% di un core) - memoria app $($r.wsAppFine) MB, WebView2 $($r.wsWvFine) MB"
# Chiusa per bene (nessun lavoro): deve chiudersi senza domande
$h = Finestra
if ($h -ne [IntPtr]::Zero) { [W8]::ShowWindow($h, 9) | Out-Null; [W8]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
$t = Get-Date
while ((Get-Process orbitlr -EA SilentlyContinue) -and ((Get-Date) - $t).TotalSeconds -lt 15) { Start-Sleep -Milliseconds 300 }
$viva = [bool](Get-Process orbitlr -EA SilentlyContinue)
$wvDopo = (Get-Process msedgewebview2 -EA SilentlyContinue).Count
Esito "chiusura senza lavori (WM_CLOSE)" $(if (-not $viva -and $wvDopo -eq 0) { "OK" } else { "INFO" }) "chiusa: $(-not $viva) in $([math]::Round(((Get-Date) - $t).TotalSeconds,1)) s - processi WebView2 rimasti: $wvDopo"
if ($viva) { Foto "a1-non-si-chiude"; TestiApp "a1-non-si-chiude" | Out-Null }
Ferma

# ---------------------------------------------------------------- 2. 300 file in un lavoro (PNG -> JPG)
$d3 = "$W\trecento"
New-Item -ItemType Directory -Force -Path $d3 | Out-Null
& $script:FF -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=30" -frames:v 300 "$d3\foto %03d.png"
$png = @(Get-ChildItem $d3 -Filter *.png)
Log "300 file: creati $($png.Count) PNG, $([math]::Round(($png | Measure-Object Length -Sum).Sum / 1MB)) MB"
$lista = ($png | ForEach-Object FullName) -join ";"
Log "lunghezza dell'elenco passato all'app: $($lista.Length) caratteri"
$t = Get-Date
$p = Avvia @{ ORBIT_PROVA_FILE = $lista; ORBIT_PROVA_SCHEDA = "image"; ORBIT_PROVA_AZIONE = "to:jpg"; ORBIT_PROVA_PARAMETRO = "" }
$r = Osserva "trecento" 900 { (@(Get-ChildItem $d3 -Filter *.jpg | Where-Object Length -gt 0)).Count -ge 300 -and -not (Get-ChildItem $d3 -Force -Filter ".orbitlr-*") }
Start-Sleep -Seconds 8
Foto "a2-trecento-fine"
$jpg = @(Get-ChildItem $d3 -Filter *.jpg)
$vuoti = @($jpg | Where-Object Length -eq 0)
$falsi = @($jpg | Where-Object { $b = [IO.File]::ReadAllBytes($_.FullName) | Select-Object -First 2; -not ($b[0] -eq 0xFF -and $b[1] -eq 0xD8) })
$dim = @()
foreach ($f in $jpg | Get-Random -Count ([math]::Min(5, $jpg.Count))) { try { $im = [System.Drawing.Image]::FromFile($f.FullName); $dim += "$($f.Name) $($im.Width)x$($im.Height)"; $im.Dispose() } catch { $dim += "$($f.Name) illeggibile" } }
$av = Avanzi @($d3)
$ok = ($jpg.Count -eq 300) -and ($vuoti.Count -eq 0) -and ($falsi.Count -eq 0) -and ($av.Count -eq 0) -and -not $r.morta
Esito "300 file in un lavoro (PNG 1920x1080 -> JPG)" $(if ($ok) { "OK" } else { "BUG" }) "JPG creati $($jpg.Count)/300 in $($r.secondi) s - vuoti $($vuoti.Count) - non JPEG $($falsi.Count) - avanzi $($av.Count) - app morta: $($r.morta) - CPU app $($r.cpuAppCore)% di un core, WebView2 $($r.cpuWvCore)% - memoria app max $($r.wsAppMax) MB (privata $($r.privAppMax)), WebView2 max $($r.wsWvMax) MB - finestra bloccata: $($r.campioniBloccata) campioni, al massimo $($r.bloccataMaxSec) s di fila - esempi: $($dim -join ', ')"
TestiApp "a2-trecento" | Out-Null
$r2 = Osserva "dopo-trecento-riposo" 60
Esito "a riposo dopo i 300 file (60 s)" $(if ($r2.cpuTotMacchina -lt 1) { "OK" } else { "BUG" }) "CPU macchina $($r2.cpuTotMacchina)% (app $($r2.cpuAppCore)%, WebView2 $($r2.cpuWvCore)% di un core) - memoria app $($r2.wsAppFine) MB, WebView2 $($r2.wsWvFine) MB (prima del lavoro, a riposo: app+WebView2 $riposoWs MB) - handle app $($r2.handlesFine)"
Ferma

# ---------------------------------------------------------------- 3. Un file da 3 GB (video 1080p non compresso + audio)
$g = "$W\grande"
New-Item -ItemType Directory -Force -Path $g | Out-Null
$big = "$g\Film grande.mov"
# Prima 10 s per sapere quanto pesa un secondo, poi la durata giusta per superare i 3 GB (MJPEG 1080p + audio AAC)
& $script:FF -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=25" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 10 -c:v mjpeg -q:v 2 -pix_fmt yuvj420p -c:a aac "$g\prova10.mov"
$s10 = (Get-Item "$g\prova10.mov").Length
$durata = [math]::Min(1800, [math]::Ceiling(3.15e9 / ($s10 / 10)))
Remove-Item "$g\prova10.mov" -Force
$t = Get-Date
& $script:FF -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1920x1080:rate=25" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t $durata -c:v mjpeg -q:v 2 -pix_fmt yuvj420p -c:a aac $big
$bs = (Get-Item $big -EA SilentlyContinue).Length
Log "file grande: $([math]::Round($bs / 1GB, 2)) GB, $durata s di video, creato in $([math]::Round(((Get-Date) - $t).TotalSeconds)) s"
$vars = @{ ORBIT_PROVA_FILE = $big; ORBIT_PROVA_SCHEDA = "video"; ORBIT_PROVA_AZIONE = "vcompress"; ORBIT_PROVA_PARAMETRO = "best" }
$p = Avvia $vars
$r = Osserva "tre-giga" 900 { $o = Get-ChildItem $g -Filter "Film grande (*).mp4" -EA SilentlyContinue | Where-Object Length -gt 0; $o -and -not (Get-ChildItem $g -Force -Filter ".orbitlr-*") -and -not (Get-Process ffmpeg -EA SilentlyContinue) } 3
Start-Sleep -Seconds 3
Foto "a3-tre-giga-fine"
TestiApp "a3-tre-giga" | Out-Null
$o = Get-ChildItem $g -Filter "Film grande (*).mp4" -EA SilentlyContinue | Select-Object -First 1
$info = if ($o -and (Test-Path $script:FP)) { (& $script:FP -v error -show_entries format=duration:stream=codec_name,width,height -of compact $o.FullName) -join " ; " } else { "" }
$av = Avanzi @($g)
Esito "video da $([math]::Round($bs / 1GB, 2)) GB: Comprimi (best)" $(if ($o -and $o.Length -gt 0 -and $av.Count -eq 0 -and $info -match "duration=$([int]$durata - 1)|duration=$durata") { "OK" } else { "BUG" }) "uscita: $(if ($o) { "$($o.Name) $([math]::Round($o.Length / 1MB, 1)) MB" } else { 'nessuna' }) in $($r.secondi) s - ffprobe: $info - avanzi: $(($av | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ') - memoria app max $($r.wsAppMax) MB, WebView2 max $($r.wsWvMax) MB, ffmpeg max $($r.wsFfMax) MB - CPU app $($r.cpuAppCore)% di un core - bloccata $($r.campioniBloccata) campioni"
Ferma

# ---------------------------------------------------------------- 4. Chiusura con la X durante il lavoro da 3 GB
function AspettaLavoro([string]$dir, [int]$sec = 90) {
  $t = Get-Date
  while (((Get-Date) - $t).TotalSeconds -lt $sec) {
    $tmp = Get-ChildItem $dir -Force -Filter ".orbitlr-*" -EA SilentlyContinue
    if ($tmp -and (Get-Process ffmpeg -EA SilentlyContinue)) { return $tmp }
    Start-Sleep -Milliseconds 500
  }
  return $null
}
Get-ChildItem $g -Filter "Film grande (*" | Remove-Item -Force
$p = Avvia $vars
$tmp = AspettaLavoro $g
Log "lavoro partito: temporaneo $(($tmp | ForEach-Object Name) -join ',') - ffmpeg $(@(Get-Process ffmpeg -EA SilentlyContinue).Count)"
Start-Sleep -Seconds 15
$prima = @(Get-ChildItem $g -Force | ForEach-Object { "$($_.Name) $($_.Length)" })
Log "durante il lavoro: $($prima -join ' | ') - registro: $(Registro)"
$h = Finestra
[W8]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
Start-Sleep -Seconds 4
Foto "a4-x-durante-lavoro"
$testi = TestiApp "a4-x-durante-lavoro"
$vivaDopoX = [bool](Get-Process orbitlr -EA SilentlyContinue)
$ffDopoX = [bool](Get-Process ffmpeg -EA SilentlyContinue)
$chiede = [bool]($testi | Where-Object { $_ -match "lavori in corso|Interrompi e chiudi|Jobs are still running|Stop and Quit" })
Esito "X durante un lavoro: chiede prima di chiudere" $(if ($vivaDopoX -and $chiede) { "OK" } else { "BUG" }) "app viva $vivaDopoX - ffmpeg vivo $ffDopoX - domanda vista: $chiede"
$premuto = Premi @("Interrompi e chiudi", "Stop and Quit") 8
if ($premuto -notmatch "^premuto") { Log "pulsante: $premuto - provo con Tab e Invio"; Tasti "{TAB}"; Tasti "{ENTER}"; $premuto += " / tastiera" }
Log "Interrompi e chiudi: $premuto"
$t = Get-Date
while ((Get-Process orbitlr -EA SilentlyContinue) -and ((Get-Date) - $t).TotalSeconds -lt 20) { Start-Sleep -Milliseconds 200 }
$sec = [math]::Round(((Get-Date) - $t).TotalSeconds, 1)
$vivaApp = [bool](Get-Process orbitlr -EA SilentlyContinue)
Start-Sleep -Seconds 2
$ffViva = @(Get-Process ffmpeg -EA SilentlyContinue).Count
$wvViva = @(Get-Process msedgewebview2 -EA SilentlyContinue).Count
$dopo = @(Get-ChildItem $g -Force | ForEach-Object { "$($_.Name) $($_.Length)" })
$av = Avanzi @($g)
Esito "Interrompi e chiudi durante il lavoro da 3 GB: niente avanzi" $(if (-not $vivaApp -and $ffViva -eq 0 -and $av.Count -eq 0) { "OK" } else { "BUG" }) "$premuto - app chiusa dopo $sec s: $(-not $vivaApp) - ffmpeg ancora acceso: $ffViva - WebView2 rimasti: $wvViva - cartella: $($dopo -join ' | ') - registro temporanei: $(Registro)"
Foto "a4-dopo-interrompi"
Ferma

# ---------------------------------------------------------------- 5. Chiusura forzata (taskkill /F, come Gestione attivita') durante il lavoro
Get-ChildItem $g -Filter "Film grande (*" | Remove-Item -Force
$p = Avvia $vars
$tmp = AspettaLavoro $g
Log "lavoro partito: temporaneo $(($tmp | ForEach-Object Name) -join ',') - ffmpeg $(@(Get-Process ffmpeg -EA SilentlyContinue).Count)"
Start-Sleep -Seconds 15
$ffPid = (Get-Process ffmpeg -EA SilentlyContinue | Select-Object -First 1).Id
Log "prima di taskkill /F: $((Get-ChildItem $g -Force | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ' | ') - ffmpeg pid $ffPid"
& taskkill.exe /F /IM orbitlr.exe 2>&1 | ForEach-Object { Log "taskkill: $_" }
Start-Sleep -Seconds 3
$ffViva = @(Get-Process ffmpeg -EA SilentlyContinue).Count
$s1 = (Get-ChildItem $g -Force -Filter ".orbitlr-*" -EA SilentlyContinue | Measure-Object Length -Sum).Sum
Start-Sleep -Seconds 5
$s2 = (Get-ChildItem $g -Force -Filter ".orbitlr-*" -EA SilentlyContinue | Measure-Object Length -Sum).Sum
$wvViva = @(Get-Process msedgewebview2 -EA SilentlyContinue).Count
$avKill = @(Avanzi @($g))
Esito "taskkill /F durante il lavoro: ffmpeg si ferma con l'app" $(if ($ffViva -eq 0 -and $s1 -eq $s2) { "OK" } else { "BUG" }) "ffmpeg ancora acceso dopo 3 s: $ffViva - temporaneo cresce ancora: $($s1 -ne $s2) ($s1 -> $s2 byte) - WebView2 rimasti dopo 8 s: $wvViva"
Esito "taskkill /F durante il lavoro: cosa resta subito" "INFO" "avanzi: $(($avKill | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ') - registro: $(Registro)"
Get-Process ffmpeg, msedgewebview2 -EA SilentlyContinue | Stop-Process -Force -EA SilentlyContinue
# Riavvio: i temporanei rimasti si devono cancellare da soli
$p = Avvia
Start-Sleep -Seconds 20
Foto "a5-riavvio-dopo-kill"
TestiApp "a5-riavvio-dopo-kill" | Out-Null
$avDopo = @(Avanzi @($g))
Esito "riavvio dopo taskkill /F: temporanei cancellati" $(if ($avKill.Count -gt 0 -and $avDopo.Count -eq 0) { "OK" } elseif ($avKill.Count -eq 0) { "INFO" } else { "BUG" }) "prima $($avKill.Count) avanzi, dopo il riavvio $($avDopo.Count): $(($avDopo | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ')"
# Riposo finale (nuovo avvio, finestra aperta)
$r = Osserva "riposo-4-dopo-riavvio" 60
Esito "riposo dopo il riavvio (60 s)" $(if ($r.cpuTotMacchina -lt 1) { "OK" } else { "BUG" }) "CPU macchina $($r.cpuTotMacchina)% (app $($r.cpuAppCore)%, WebView2 $($r.cpuWvCore)% di un core) - memoria app $($r.wsAppFine) MB, WebView2 $($r.wsWvFine) MB"
Ferma
Raccogli
Log "fine parte A"
