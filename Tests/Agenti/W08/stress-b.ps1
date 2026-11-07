# W08 - parte B: due OrbitLR insieme, "Apri con OrbitLR" con 50 file selezionati in Esplora file,
# disco quasi pieno (disco virtuale VHDX), file tenuti aperti come fa un antivirus.
param([string]$Out = "w08-b")
. "$PSScriptRoot\comune.ps1"

Installa
$W = "C:\W08"
New-Item -ItemType Directory -Force -Path $W | Out-Null

function Contali() { "processi orbitlr $(@(Get-Process orbitlr -EA SilentlyContinue).Count), finestre 'OrbitLR' visibili $([W8]::CountMain())" }
function ChiudiBene() {
  $h = Finestra
  if ($h -ne [IntPtr]::Zero) { [W8]::PostMessage($h, 0x10, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null }
  $t = Get-Date
  while ((Get-Process orbitlr -EA SilentlyContinue) -and ((Get-Date) - $t).TotalSeconds -lt 10) { Start-Sleep -Milliseconds 300 }
  Ferma
}
# Aspetta che la cartella smetta di cambiare (il lavoro e' finito, riuscito o no)
function Stabile([string]$dir, [int]$quiete = 15, [int]$max = 240) {
  $t = Get-Date; $last = ""; $since = Get-Date
  while (((Get-Date) - $t).TotalSeconds -lt $max) {
    Start-Sleep -Seconds 1
    $now = (Get-ChildItem $dir -Force -File -EA SilentlyContinue | ForEach-Object { "$($_.Name)=$($_.Length)" }) -join "|"
    if ($now -ne $last) { $last = $now; $since = Get-Date }
    elseif (((Get-Date) - $since).TotalSeconds -ge $quiete -and -not (Get-Process ffmpeg -EA SilentlyContinue)) { break }
  }
  return [math]::Round(((Get-Date) - $t).TotalSeconds)
}

# Primo avvio: il benvenuto si chiude, cosi' non copre le prove dopo
$p = Avvia
Start-Sleep -Seconds 12
ChiudiBenvenuto
Start-Sleep -Seconds 2
ChiudiBene

# ---------------------------------------------------------------- 1. Due avvii insieme
$p1 = Avvia; $p2 = Avvia
Start-Sleep -Seconds 15
$c = Contali
Foto "b1-due-avvii"
Esito "due avvii nello stesso istante: una sola OrbitLR" $(if (@(Get-Process orbitlr -EA SilentlyContinue).Count -eq 1 -and [W8]::CountMain() -eq 1) { "OK" } else { "BUG" }) "$c - secondo: uscito $($p2.HasExited) codice $(if ($p2.HasExited) { $p2.ExitCode })"
$mp4 = "$W\uno.mp4"
& $script:FF -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=25" -t 3 -c:v mpeg4 -q:v 3 $mp4
$t = Get-Date
$p3 = Avvia @{} @($mp4)
$p3.WaitForExit(15000) | Out-Null
Start-Sleep -Seconds 3
Foto "b1-secondo-con-file"
$testi = TestiApp "b1-secondo-con-file"
Esito "secondo avvio con un file mentre OrbitLR e' aperta" $(if ($p3.HasExited -and @(Get-Process orbitlr -EA SilentlyContinue).Count -eq 1 -and ($testi -match "uno\.mp4|uno")) { "OK" } else { "BUG" }) "secondo uscito: $($p3.HasExited) dopo $([math]::Round(((Get-Date) - $t).TotalSeconds,1)) s - $(Contali) - il file compare nella pagina: $([bool]($testi -match 'uno'))"
ChiudiBene
$ps = @(); 1..10 | ForEach-Object { $ps += Avvia }
Start-Sleep -Seconds 25
$c = Contali
Foto "b1-dieci-avvii"
$rimasti = @($ps | Where-Object { -not $_.HasExited }).Count
Esito "10 avvii nello stesso istante" $(if (@(Get-Process orbitlr -EA SilentlyContinue).Count -eq 1 -and [W8]::CountMain() -eq 1) { "OK" } else { "BUG" }) "$c - avvii ancora vivi dopo 25 s: $rimasti/10 - WebView2 $(@(Get-Process msedgewebview2 -EA SilentlyContinue).Count) processi"
ChiudiBene

# ---------------------------------------------------------------- 2. 50 file: Esplora file, clic destro, "Apri con OrbitLR"
$d50 = "$W\cinquanta"
New-Item -ItemType Directory -Force -Path $d50 | Out-Null
& $script:FF -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=25" -frames:v 50 -q:v 3 "$d50\scatto %02d.jpg"
Log "50 file: $(@(Get-ChildItem $d50 -Filter *.jpg).Count) JPG"
$k = Get-ItemProperty 'HKCU:\Software\Classes\*\shell\OrbitLR' -EA SilentlyContinue
$kc = (Get-ItemProperty 'HKCU:\Software\Classes\*\shell\OrbitLR\command' -EA SilentlyContinue).'(default)'
Log "voce del menu: '$($k.'(default)')' MultiSelectModel=$($k.MultiSelectModel) comando: $kc"

$avvii = 0
try { Register-CimIndicationEvent -Query "SELECT * FROM Win32_ProcessStartTrace WHERE ProcessName='orbitlr.exe'" -SourceIdentifier "avvii" -ErrorAction Stop; $tracce = $true } catch { Log "traccia degli avvii non disponibile: $_"; $tracce = $false }
function Avvii() { if ($tracce) { $n = @(Get-Event -SourceIdentifier avvii -EA SilentlyContinue).Count; Get-Event -SourceIdentifier avvii -EA SilentlyContinue | Remove-Event; return $n } else { return -1 } }

$shell = New-Object -ComObject Shell.Application
function Esplora([string]$dir) {
  Start-Process explorer.exe $dir
  for ($i = 0; $i -lt 20; $i++) {
    Start-Sleep -Milliseconds 700
    foreach ($w in $shell.Windows()) { try { if ($w.Document.Folder.Self.Path -eq $dir) { return $w } } catch {} }
  }
  return $null
}
function Seleziona($win, [int]$n) {
  $items = $win.Document.Folder.Items()
  $sel = 0
  for ($i = 0; $i -lt [math]::Min($n, $items.Count); $i++) {
    $f = if ($i -eq 0) { 1 + 4 + 8 + 16 } else { 1 }
    try { $win.Document.SelectItem($items.Item($i), $f); $sel++ } catch {}
  }
  Start-Sleep -Milliseconds 500
  return $win.Document.SelectedItems().Count
}
function Menu([IntPtr]$hwnd, [string]$nome) {
  [W8]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [W8]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)
  [W8]::SetForegroundWindow($hwnd) | Out-Null
  Start-Sleep -Milliseconds 700
  [System.Windows.Forms.SendKeys]::SendWait("+{F10}")
  Start-Sleep -Seconds 3
  Foto $nome
  $root = [System.Windows.Automation.AutomationElement]::RootElement
  $c = New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::NameProperty, "Apri con OrbitLR")
  $t = Get-Date; $e = $null
  while (-not $e -and ((Get-Date) - $t).TotalSeconds -lt 8) { $e = $root.FindFirst([System.Windows.Automation.TreeScope]::Descendants, $c); if (-not $e) { Start-Sleep -Milliseconds 500 } }
  # Le voci del menu (per sapere cosa c'era)
  $voci = @()
  foreach ($m in $root.FindAll([System.Windows.Automation.TreeScope]::Children, (New-Object System.Windows.Automation.PropertyCondition([System.Windows.Automation.AutomationElement]::ClassNameProperty, "#32768")))) {
    foreach ($v in $m.FindAll([System.Windows.Automation.TreeScope]::Descendants, [System.Windows.Automation.Condition]::TrueCondition)) { try { if ($v.Current.Name) { $voci += $v.Current.Name } } catch {} }
  }
  $voci | Set-Content (Join-Path $Out "menu-$nome.txt") -Encoding utf8
  Log "menu $nome : $($voci.Count) voci: $($voci -join ' | ')"
  return $e
}
function Contati([string[]]$testi) { @($testi | Select-String -Pattern "scatto \d\d" -AllMatches | ForEach-Object { $_.Matches } | ForEach-Object { $_.Value } | Sort-Object -Unique).Count }

foreach ($caso in "fredda", "calda") {
  Ferma
  if ($caso -eq "calda") { $p = Avvia; Start-Sleep -Seconds 12 }
  Avvii | Out-Null
  $win = Esplora $d50
  if (-not $win) { Esito "Esplora file con 50 file ($caso)" "NON-PROVATO" "la finestra di Esplora file non si trova"; continue }
  $hw = [IntPtr]([long]$win.HWND)
  # Controllo della prova: con 2 file la voce c'e'?
  $n2 = Seleziona $win 2
  $e2 = Menu $hw "b2-menu-2-file-$caso"
  [System.Windows.Forms.SendKeys]::SendWait("{ESC}"); Start-Sleep -Milliseconds 600
  $n = Seleziona $win 50
  $e = Menu $hw "b2-menu-50-file-$caso"
  Log "selezionati $n2 poi $n - voce con 2 file: $([bool]$e2) - con 50: $([bool]$e)"
  if (-not $e) {
    [System.Windows.Forms.SendKeys]::SendWait("{ESC}")
    Esito "Esplora file: voce 'Apri con OrbitLR' con 50 file selezionati ($caso)" $(if ($e2) { "BUG" } else { "NON-PROVATO" }) "con $n2 file la voce c'e': $([bool]$e2) - con $n file: no (foto b2-menu-50-file-$caso)"
    try { $win.Quit() } catch {}
    continue
  }
  $t = Get-Date
  try { $e.GetCurrentPattern([System.Windows.Automation.InvokePattern]::Pattern).Invoke(); $come = "invoke" } catch { $e.SetFocus(); [System.Windows.Forms.SendKeys]::SendWait("{ENTER}"); $come = "invio" }
  $r = Osserva "esplora-50-$caso" 40
  $na = Avvii
  Start-Sleep -Seconds 2
  Davanti | Out-Null
  Start-Sleep -Seconds 1
  Foto "b2-app-dopo-50-$caso"
  $testi = TestiApp "esplora-50-$caso"
  $visti = Contati $testi
  $conta = @($testi | Where-Object { $_ -match "\b\d+ (file|foto|immagini)\b" }) -join " / "
  $nproc = @(Get-Process orbitlr -EA SilentlyContinue).Count
  Esito "Esplora file: 'Apri con OrbitLR' con 50 file selezionati ($caso)" $(if ($nproc -eq 1 -and [W8]::CountMain() -eq 1 -and $visti -ge 50 -and -not $r.morta) { "OK" } else { "BUG" }) "voce premuta ($come) - avvii di orbitlr.exe: $na - $(Contali) - nomi 'scatto NN' visti nella pagina: $visti - testi con un conteggio: $conta - finestra bloccata $($r.campioniBloccata) campioni (max $($r.bloccataMaxSec) s) - memoria app max $($r.wsAppMax) MB, WebView2 $($r.wsWvMax) MB"
  try { $win.Quit() } catch {}
  ChiudiBene
}

# Come fa Esplora file con il comando "%1": 50 avvii, uno per file, tutti insieme
foreach ($caso in "fredda", "calda") {
  Ferma
  if ($caso -eq "calda") { $p = Avvia; Start-Sleep -Seconds 12 }
  Avvii | Out-Null
  $ps = @()
  foreach ($f in Get-ChildItem $d50 -Filter *.jpg) { $ps += Avvia @{} @($f.FullName) }
  $r = Osserva "cinquanta-avvii-$caso" 45
  Davanti | Out-Null
  Foto "b2-cinquanta-avvii-$caso"
  $testi = TestiApp "cinquanta-avvii-$caso"
  $visti = Contati $testi
  $vivi = @($ps | Where-Object { -not $_.HasExited }).Count
  Esito "50 avvii con un file ciascuno ($caso)" $(if (@(Get-Process orbitlr -EA SilentlyContinue).Count -eq 1 -and $visti -ge 50 -and -not $r.morta) { "OK" } else { "BUG" }) "$(Contali) - avvii non usciti: $vivi/50 - nomi visti nella pagina: $visti - finestra bloccata $($r.campioniBloccata) campioni (max $($r.bloccataMaxSec) s) - CPU app $($r.cpuAppCore)% di un core - memoria app max $($r.wsAppMax) MB"
  ChiudiBene
}
if ($tracce) { Unregister-Event -SourceIdentifier avvii -EA SilentlyContinue }

# ---------------------------------------------------------------- 3. Disco quasi pieno (VHDX da 700 MB, lettera R:)
$vhd = "$W\piccolo.vhdx"
@"
create vdisk file="$vhd" maximum=700 type=fixed
select vdisk file="$vhd"
attach vdisk
create partition primary
format fs=ntfs quick label=PICCOLO
assign letter=R
"@ | Set-Content "$W\dp.txt" -Encoding ascii
& diskpart.exe /s "$W\dp.txt" 2>&1 | ForEach-Object { Log "diskpart: $_" }
Start-Sleep -Seconds 3
if (-not (Test-Path R:\)) {
  Esito "disco quasi pieno" "NON-PROVATO" "il disco virtuale R: non si e' creato"
} else {
  $R = "R:\prove"
  New-Item -ItemType Directory -Force -Path $R | Out-Null
  & $script:FF -hide_banner -loglevel error -y -f lavfi -i "nullsrc=s=3000x2000,geq=lum='random(1)*255':cb='random(2)*255':cr='random(3)*255'" -frames:v 12 -q:v 2 "$R\foto %02d.jpg"
  & $script:FF -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=30" -t 30 -c:v rawvideo -pix_fmt yuv420p "$R\Film.mkv"
  function Libero() { [math]::Round((Get-PSDrive R).Free / 1MB, 1) }
  Log "R: sorgenti $((Get-ChildItem $R | ForEach-Object { "$($_.Name) $([math]::Round($_.Length/1MB,1))MB" }) -join ', ') - libero $(Libero) MB"
  $free = (Get-PSDrive R).Free
  & fsutil.exe file createnew R:\riempi.bin ([int64]($free - 80MB)) | Out-Null
  Log "riempito: libero $(Libero) MB"

  # L1: 12 foto JPG -> PNG (ogni PNG ~15-20 MB): a un certo punto il disco e' pieno
  $jp = (Get-ChildItem $R -Filter *.jpg | ForEach-Object FullName) -join ";"
  $p = Avvia @{ ORBIT_PROVA_FILE = $jp; ORBIT_PROVA_SCHEDA = "image"; ORBIT_PROVA_AZIONE = "to:png" }
  $s = Stabile $R 15 300
  Davanti | Out-Null; Foto "b3-disco-pieno-png"
  $testi = TestiApp "b3-disco-pieno-png"
  $pngs = @(Get-ChildItem $R -Filter *.png)
  $av = @(Avanzi @($R))
  $err = @($testi | Where-Object { $_ -match "spazio|disco|space|disk|os error|errore" }) | Select-Object -First 6
  Esito "disco pieno durante JPG->PNG (12 foto, 80 MB liberi)" $(if ($av.Count -eq 0 -and (Get-Process orbitlr -EA SilentlyContinue)) { "OK" } else { "BUG" }) "PNG fatti $($pngs.Count) ($((($pngs | ForEach-Object { [math]::Round($_.Length/1MB,1) }) -join ', ')) MB) in $s s - avanzi: $(($av | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ') - libero dopo $(Libero) MB - messaggi: $($err -join ' / ') - registro: $(Registro)"
  ChiudiBene
  $pngs | Remove-Item -Force -EA SilentlyContinue; $av | Remove-Item -Force -EA SilentlyContinue

  # L2: Comprimi il video (controlla lo spazio prima)
  $p = Avvia @{ ORBIT_PROVA_FILE = "$R\Film.mkv"; ORBIT_PROVA_SCHEDA = "video"; ORBIT_PROVA_AZIONE = "vcompress"; ORBIT_PROVA_PARAMETRO = "best" }
  $s = Stabile $R 15 240
  Davanti | Out-Null; Foto "b3-disco-pieno-vcompress"
  $testi = TestiApp "b3-disco-pieno-vcompress"
  $made = @(Get-ChildItem $R -Filter "*.mp4")
  $av = @(Avanzi @($R))
  $err = @($testi | Where-Object { $_ -match "spazio|disco|space|disk|os error|liberi" }) | Select-Object -First 6
  Esito "disco quasi pieno: Comprimi video (80 MB liberi)" $(if ($av.Count -eq 0) { "OK" } else { "BUG" }) "creati: $(($made | ForEach-Object { "$($_.Name) $([math]::Round($_.Length/1MB,1)) MB" }) -join ', ') in $s s - avanzi: $(($av | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ') - libero $(Libero) MB - messaggi: $($err -join ' / ')"
  ChiudiBene
  $made | Remove-Item -Force -EA SilentlyContinue; $av | Remove-Item -Force -EA SilentlyContinue

  # L3: Converti in MKV (copia senza ricodifica di 311 MB su 80 MB liberi: nessun controllo prima)
  $p = Avvia @{ ORBIT_PROVA_FILE = "$R\Film.mkv"; ORBIT_PROVA_SCHEDA = "video"; ORBIT_PROVA_AZIONE = "to:mkv" }
  $s = Stabile $R 20 300
  Davanti | Out-Null; Foto "b3-disco-pieno-mkv"
  $testi = TestiApp "b3-disco-pieno-mkv"
  $made = @(Get-ChildItem $R -Filter "Film (*).mkv")
  $av = @(Avanzi @($R))
  $err = @($testi | Where-Object { $_ -match "spazio|disco|space|disk|os error|liberi|errore|riuscit" }) | Select-Object -First 6
  $minfo = if ($made -and (Test-Path $script:FP)) { (& $script:FP -v error -show_entries format=duration:stream=codec_name -of compact $made[0].FullName) -join " ; " } else { "" }
  Esito "disco quasi pieno: Converti in MKV (311 MB su 80 MB liberi)" $(if ($av.Count -eq 0 -and (Get-Process orbitlr -EA SilentlyContinue)) { "OK" } else { "BUG" }) "creati: $(($made | ForEach-Object { "$($_.Name) $([math]::Round($_.Length/1MB,1)) MB" }) -join ', ') $minfo in $s s - avanzi: $(($av | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ') - libero $(Libero) MB - messaggi: $($err -join ' / ')"
  ChiudiBene
  $made | Remove-Item -Force -EA SilentlyContinue; $av | Remove-Item -Force -EA SilentlyContinue

  # L4: disco pieno del tutto (meno di 1 MB): una foto JPG -> PNG
  $free = (Get-PSDrive R).Free
  & fsutil.exe file createnew R:\riempi2.bin ([int64]($free - 256KB)) | Out-Null
  Log "pieno: libero $([math]::Round((Get-PSDrive R).Free / 1KB)) KB"
  $p = Avvia @{ ORBIT_PROVA_FILE = "$R\foto 01.jpg"; ORBIT_PROVA_SCHEDA = "image"; ORBIT_PROVA_AZIONE = "to:png" }
  $s = Stabile $R 15 120
  Davanti | Out-Null; Foto "b3-disco-pieno-del-tutto"
  $testi = TestiApp "b3-disco-pieno-del-tutto"
  $av = @(Avanzi @($R))
  $err = @($testi | Where-Object { $_ -match "spazio|disco|space|disk|os error|errore" }) | Select-Object -First 6
  Esito "disco pieno del tutto: JPG->PNG" $(if ($av.Count -eq 0 -and (Get-Process orbitlr -EA SilentlyContinue)) { "OK" } else { "BUG" }) "avanzi: $(($av | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ') - messaggi: $($err -join ' / ') - registro: $(Registro)"
  ChiudiBene
  # Dopo il riavvio i nomi riservati vuoti rimasti si tolgono?
  $p = Avvia; Start-Sleep -Seconds 15
  $av2 = @(Avanzi @($R))
  Esito "disco pieno: avanzi dopo un riavvio" $(if ($av2.Count -eq 0) { "OK" } else { "BUG" }) "prima $($av.Count), dopo il riavvio $($av2.Count): $(($av2 | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ')"
  ChiudiBene
  Get-ChildItem R:\ -Recurse -Force -EA SilentlyContinue | ForEach-Object { "$($_.FullName) $($_.Length)" } | Set-Content (Join-Path $Out "disco-R.txt") -Encoding utf8
}

# ---------------------------------------------------------------- 4. File tenuti aperti (come un antivirus)
$K = "$W\blocchi"
New-Item -ItemType Directory -Force -Path $K | Out-Null
$clip = "$K\Clip.mkv"
& $script:FF -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x360:rate=25" -f lavfi -i "sine=frequency=330" -t 20 -c:v rawvideo -pix_fmt yuv420p -c:a pcm_s16le $clip
$vc = @{ ORBIT_PROVA_FILE = $clip; ORBIT_PROVA_SCHEDA = "video"; ORBIT_PROVA_AZIONE = "vcompress"; ORBIT_PROVA_PARAMETRO = "best" }

# K1: il file di partenza aperto in esclusiva (FileShare None) prima del lavoro
$fs = [IO.File]::Open($clip, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
$p = Avvia $vc
$r = Osserva "blocco-sorgente" 40
Davanti | Out-Null; Foto "b4-sorgente-bloccata"
$testi = TestiApp "b4-sorgente-bloccata"
$fs.Close()
$av = @(Avanzi @($K))
$err = @($testi | Where-Object { $_ -match "non riesco|usato|occupato|another process|errore|non .* aprire|Clip" }) | Select-Object -First 8
Esito "file di partenza aperto in esclusiva da un altro programma" $(if (-not $r.morta -and $r.campioniBloccata -eq 0 -and $av.Count -eq 0) { "OK" } else { "BUG" }) "app viva: $(-not $r.morta) - finestra bloccata $($r.campioniBloccata) campioni - avanzi $($av.Count) - testi: $($err -join ' / ')"
ChiudiBene

# K2/K3: il file temporaneo del risultato tenuto aperto (senza permesso di rinomina) per 8 s e per 1 s dopo che ffmpeg ha finito
foreach ($hold in 8, 1) {
  Get-ChildItem $K -Force | Where-Object { $_.Name -ne "Clip.mkv" } | Remove-Item -Force -EA SilentlyContinue
  $logf = Join-Path $Out "blocca-$hold.txt"
  $lk = Start-Process powershell.exe -ArgumentList "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", "`"$PSScriptRoot\blocca.ps1`"", "-Dir", "`"$K`"", "-Hold", $hold, "-Max", 150, "-LogFile", "`"$logf`"" -PassThru -WindowStyle Hidden
  Start-Sleep -Seconds 2
  $p = Avvia $vc
  $r = Osserva "blocco-temporaneo-$hold" 120 { (Get-Content $logf -EA SilentlyContinue) -match "^.* chiuso " -and -not (Get-Process ffmpeg -EA SilentlyContinue) }
  Start-Sleep -Seconds 6
  Davanti | Out-Null; Foto "b4-temporaneo-bloccato-$hold"
  $testi = TestiApp "b4-temporaneo-bloccato-$hold"
  $lk | Stop-Process -Force -EA SilentlyContinue
  $made = @(Get-ChildItem $K -Filter "Clip (*).mp4" | Where-Object Length -gt 0)
  $av = @(Avanzi @($K))
  $err = @($testi | Where-Object { $_ -match "non riesco|usato|occupato|another process|Accesso|negato|denied|os error|errore" }) | Select-Object -First 6
  Log "blocca $hold : $((Get-Content $logf -EA SilentlyContinue) -join ' | ')"
  Log "cartella dopo: $((Get-ChildItem $K -Force | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ' | ') - registro: $(Registro)"
  ChiudiBene
  # Al riavvio gli avanzi si cancellano?
  $p = Avvia; Start-Sleep -Seconds 15
  $av2 = @(Avanzi @($K))
  ChiudiBene
  if ($hold -eq 1) {
    Esito "temporaneo tenuto aperto 1 s da un 'antivirus': il risultato arriva lo stesso" $(if ($made.Count -ge 1 -and $av.Count -eq 0) { "OK" } else { "BUG" }) "risultato: $(($made | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ') - avanzi $($av.Count): $(($av | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ') - testi: $($err -join ' / ')"
  } else {
    Esito "temporaneo tenuto aperto 8 s da un 'antivirus': cosa resta" $(if ($av.Count -eq 0 -or $av2.Count -eq 0) { "OK" } else { "BUG" }) "risultato: $(($made | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ') - avanzi subito $($av.Count): $(($av | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ') - dopo un riavvio $($av2.Count): $(($av2 | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ') - messaggi: $($err -join ' / ')"
  }
}
Raccogli
Log "fine parte B"
