# Tester20 · P18W «File cattivi» (windows-2025): nomi con emoji e cirillico, percorsi oltre 260 caratteri, un file da 3 GB,
# file rovinati, cartella in sola lettura, TEMP / utente con lettere non latine, un file tolto durante un lavoro su più file.
param([string]$Setup, [string]$Out)
$Profilo = "P18W"
. "$PSScriptRoot\comune.ps1"
Info
$M = $env:T20_MOTORE
$exe = Installa $Setup
if (-not $exe) { Bug "L'installazione silenziosa non installa OrbitLR" "bloccante" @("OrbitLR-Windows-2.0.1-Setup.exe /S") "orbitlr.exe installata" "non installata" "diario.txt"; Salva "p18"; exit 0 }
$dati = "$env:LOCALAPPDATA\it.ledion.orbitlr"
function Motore([string[]]$a) {
  if (-not $M -or -not (Test-Path $M)) { return $null }
  $lines = & $M @a 2>&1 | ForEach-Object { "$_" }
  $lines | ForEach-Object { Log "motore: $_" }
  @($lines | Where-Object { $_ -like "T20|*" } | ForEach-Object { $_.Substring(4) | ConvertFrom-Json }) | Select-Object -First 1
}
# Un lavoro dentro l'app; $dir: dove guardare; $pat: il risultato atteso
function Lavoro([string]$nome, [string]$file, [string]$scheda, [string]$azione, [string]$param, [string]$dir, [string]$pat, [int]$attesa = 120) {
  $prima = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | ForEach-Object Name)
  $script:LavDir = $dir; $script:LavPat = $pat; $script:LavPrima = $prima
  $r = Avvia $nome @{ ORBIT_PROVA_FILE = $file; ORBIT_PROVA_SCHEDA = $scheda; ORBIT_PROVA_AZIONE = $azione; ORBIT_PROVA_PARAMETRO = $param } $attesa { [bool](Get-ChildItem -LiteralPath $script:LavDir -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -like $script:LavPat -and $script:LavPrima -notcontains $_.Name -and $_.Name -notlike "*.orbitlr-*" -and $_.Length -gt 0 }) } -Resta
  Start-Sleep -Seconds 2
  $nuovi = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $prima -notcontains $_.Name })
  $r | Add-Member nuovi $nuovi
  $r | Add-Member ocr (Ocr $r.foto)
  Log "«$nome»: nuovi file: $(($nuovi | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ') · OCR: $($r.ocr -replace "`n", ' | ')"
  Ferma
  return $r
}

$casa = Join-Path $env:USERPROFILE "Documents\File cattivi"
New-Item -ItemType Directory -Force $casa | Out-Null
Video "$casa\base.mp4" 6 | Out-Null
Immagine "$casa\base.png" "1200x900" | Out-Null

# ── 1. Nomi con emoji e cirillico (anche la cartella)
$emo = Join-Path $casa "Праздник 🎉 фото"
New-Item -ItemType Directory -Force $emo | Out-Null
Copy-Item "$casa\base.mp4" (Join-Path $emo "Видео 🎂 Ёлка.mp4")
Copy-Item "$casa\base.png" (Join-Path $emo "照片 😀 Ёж.png")
$r = Lavoro "1-video-emoji-cirillico" (Join-Path $emo "Видео 🎂 Ёлка.mp4") "video" "vcompress" "best" $emo "Видео 🎂 Ёлка *.mp4"
if (-not (Passo "video con emoji e cirillico nel nome e nella cartella: compresso, nome intatto" ($r.nuovi | Where-Object { $_.Name -like "Видео 🎂 Ёлка *.mp4" }) "$(($r.nuovi | ForEach-Object Name) -join ', ')")) {
  Bug "Comprimi non riesce con emoji e lettere cirilliche nel nome" "alto" @("Un video «Видео 🎂 Ёлка.mp4» in «Праздник 🎉 фото»", "Video → Comprimi") "«Видео 🎂 Ёлка (compresso).mp4» accanto" "nuovi file: $(($r.nuovi | ForEach-Object Name) -join ', '); OCR: $($r.ocr -replace "`n", ' ')" "$($r.nome).png"
}
$r = Lavoro "2-foto-emoji-cinese" (Join-Path $emo "照片 😀 Ёж.png") "image" "to:jpg" "" $emo "照片 😀 Ёж*.jpg" 60
if (-not (Passo "foto con emoji e cinese nel nome: PNG → JPG, nome intatto" ($r.nuovi | Where-Object { $_.Name -like "照片 😀 Ёж*.jpg" }) "$(($r.nuovi | ForEach-Object Name) -join ', ')")) {
  Bug "PNG → JPG non riesce con emoji e lettere cinesi nel nome" "alto" @("«照片 😀 Ёж.png»", "Immagini → Cambia formato → JPG") "«照片 😀 Ёж.jpg»" "nuovi file: $(($r.nuovi | ForEach-Object Name) -join ', ')" "$($r.nome).png"
}

# ── 2. Percorso oltre 260 caratteri (con LongPathsEnabled com'è sul computer, poi a 0)
$lp = (Get-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -ErrorAction SilentlyContinue).LongPathsEnabled
$lungo = "C:\T20 lunghi"
for ($i = 1; $i -le 6; $i++) { $lungo = Join-Path $lungo ("Cartella con un nome davvero molto lungo numero $i " + ("x" * 12)) }
New-Item -ItemType Directory -Force -Path "\\?\$lungo" | Out-Null
$fl = Join-Path $lungo "Foto in fondo al percorso lungo.png"
Copy-Item "$casa\base.png" -Destination "\\?\$fl"
Copy-Item "$casa\base.mp4" -Destination "\\?\$(Join-Path $lungo 'Video in fondo.mp4')"
Nota "percorso lungo: $($fl.Length) caratteri · LongPathsEnabled=$lp"
foreach ($val in @($lp, 0) | Select-Object -Unique) {
  Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value $val -ErrorAction SilentlyContinue
  $r = Lavoro "3-percorso-lungo-lp$val" $fl "image" "to:jpg" "" "\\?\$lungo" "Foto in fondo al percorso lungo*.jpg" 60
  if (-not (Passo "percorso di $($fl.Length) caratteri (LongPathsEnabled=$val): PNG → JPG" ($r.nuovi | Where-Object { $_.Name -like "*.jpg" }) "$(($r.nuovi | ForEach-Object Name) -join ', ')")) {
    Bug "Percorso più lungo di 260 caratteri: la foto non si converte (LongPathsEnabled=$val)" "medio" @("Una foto in una cartella con percorso di $($fl.Length) caratteri", "Immagini → Cambia formato → JPG") "Il JPG accanto alla foto" "nessun JPG; app $(if ($r.viva) { 'aperta' } else { 'chiusa' }); OCR: $($r.ocr -replace "`n", ' ')" "$($r.nome).png"
  }
  $r = Lavoro "4-video-percorso-lungo-lp$val" (Join-Path $lungo "Video in fondo.mp4") "video" "vcompress" "best" "\\?\$lungo" "Video in fondo *.mp4" 120
  if (-not (Passo "percorso lungo (LongPathsEnabled=$val): video compresso" ($r.nuovi | Where-Object { $_.Name -like "*.mp4" }))) {
    Bug "Percorso più lungo di 260 caratteri: il video non si comprime (LongPathsEnabled=$val)" "medio" @("Un video in una cartella con percorso di $($fl.Length) caratteri", "Video → Comprimi") "Il video compresso accanto" "nessun file nuovo; OCR: $($r.ocr -replace "`n", ' ')" "$($r.nome).png"
  }
}
Set-ItemProperty HKLM:\SYSTEM\CurrentControlSet\Control\FileSystem -Name LongPathsEnabled -Value $lp -ErrorAction SilentlyContinue

# ── 3. File rovinati: l'app resta aperta, nessun file vuoto o a metà, un messaggio
$rov = Join-Path $casa "Rovinati"; New-Item -ItemType Directory -Force $rov | Out-Null
$b = [IO.File]::ReadAllBytes("$casa\base.mp4"); [IO.File]::WriteAllBytes("$rov\Video tagliato.mp4", $b[0..([math]::Min(60000, $b.Length - 1))])
$rnd = New-Object byte[] 300000; (New-Object Random 7).NextBytes($rnd); [IO.File]::WriteAllBytes("$rov\Foto finta.jpg", $rnd)
[IO.File]::WriteAllBytes("$rov\Documento rotto.pdf", [Text.Encoding]::ASCII.GetBytes("%PDF-1.4`n1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj`ngarbage garbage`n%%EOF"))
[IO.File]::WriteAllBytes("$rov\Vuoto.mp3", @())
$casi = @(
  @{ f = "Video tagliato.mp4"; s = "video"; a = "vcompress"; p = "best" },
  @{ f = "Foto finta.jpg"; s = "image"; a = "to:png"; p = "" },
  @{ f = "Documento rotto.pdf"; s = "pdf"; a = "pdfcompress"; p = "medium" },
  @{ f = "Vuoto.mp3"; s = "audio"; a = "to:wav"; p = "" }
)
foreach ($c in $casi) {
  $r = Lavoro "5-rovinato-$($c.f -replace '\W', '')" "$rov\$($c.f)" $c.s $c.a $c.p $rov "*" 25
  $vuoti = @($r.nuovi | Where-Object { $_.Length -eq 0 -or $_.Name -like "*.orbitlr-*" })
  $msg = Motore @("lavoro", $c.a, "`"$($c.p)`"", $script:Motori, $dati, "$rov\$($c.f)")
  $testo = if ($msg) { "motore: $(if ($msg.ok) { 'RIUSCITO ' + (($msg.uscite | ForEach-Object name) -join ',') } else { $msg.errore })" } else { "" }
  Passo "file rovinato «$($c.f)» ($($c.a)): l'app resta aperta" ($r.viva -and -not $r.bloccata) | Out-Null
  if (-not $r.viva) { Bug "OrbitLR si chiude con un file rovinato («$($c.f)»)" "alto" @("Un file «$($c.f)» rovinato", "$($c.s) → $($c.a)") "Un messaggio d'errore, l'app resta aperta" "OrbitLR si è chiusa (codice $($r.codice))" "$($r.nome).png" }
  if (-not (Passo "file rovinato «$($c.f)»: nessun file vuoto o a metà" ($vuoti.Count -eq 0) "$(($r.nuovi | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ') · $testo")) {
    Bug "Con un file rovinato («$($c.f)») resta un file vuoto o a metà" "medio" @("«$($c.f)» rovinato", "$($c.s) → $($c.a)") "Nessun file nuovo" "$(($vuoti | ForEach-Object { "$($_.Name) $($_.Length) byte" }) -join ', ')" "elenco della cartella"
  }
  if ($r.nuovi.Count -and -not $vuoti.Count) { Nota "file rovinato «$($c.f)»: creato comunque $(($r.nuovi | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ')" }
  if ($msg -and -not $msg.ok -and $msg.errore -match "(?i)ffmpeg|error|invalid|panic|stream|moov|0x") { Confuso "messaggio per «$($c.f)»" "il motore risponde «$($msg.errore)»: parole tecniche per chi non è pratico" }
  if ($msg -and -not $msg.ok) { Tecnico "file rovinato «$($c.f)»" $msg.errore }
  if ($msg -and -not $msg.ok) { Nota "messaggio per «$($c.f)»: $($msg.errore)" }
}
if (-not $M -or -not (Test-Path $M)) { NonEseguito "messaggio d'errore esatto per i file rovinati" "manca t20-motore.exe: visto solo dall'OCR delle foto" }

# ── 4. Cartella in sola lettura (risultati accanto all'originale: non si può scrivere)
$ro = Join-Path $casa "Sola lettura"; New-Item -ItemType Directory -Force $ro | Out-Null
Copy-Item "$casa\base.png" "$ro\Foto protetta.png"
$leggibile = try { [IO.File]::ReadAllBytes("$ro\Foto protetta.png").Length } catch { 0 }
& icacls $ro /deny "$($env:USERNAME):(OI)(CI)(W,AD,WD,DC)" 2>&1 | ForEach-Object { Log "icacls: $_" }
$r = Lavoro "6-sola-lettura" "$ro\Foto protetta.png" "image" "to:jpg" "" $ro "*.jpg" 25
$msg = Motore @("lavoro", "to:jpg", "null", $script:Motori, $dati, "$ro\Foto protetta.png")
Passo "cartella in sola lettura: l'app resta aperta" $r.viva | Out-Null
Passo "cartella in sola lettura: nessun file creato altrove a sorpresa" ($r.nuovi.Count -eq 0) | Out-Null
if ($msg) {
  Nota "sola lettura · motore: $(if ($msg.ok) { 'riuscito: ' + (($msg.uscite | ForEach-Object path) -join ',') } else { $msg.errore })"
  if (-not $msg.ok) { Tecnico "cartella in sola lettura" $msg.errore }
  $leggibile2 = try { [IO.File]::ReadAllBytes("$ro\Foto protetta.png").Length } catch { "no: $_" }
  Nota "la foto nella cartella protetta si legge ancora: $leggibile2 byte"
  if (-not $msg.ok -and $msg.errore -match "non trovo" -and $leggibile2 -is [int] -and $leggibile2 -gt 0) {
    Bug "Cartella in sola lettura: OrbitLR dice «non trovo il file (spostato o cancellato?)» ma il file c'è" "basso" @("Una foto in una cartella dove non si può scrivere (permessi di Windows)", "Immagini → Cambia formato → JPG (risultati accanto all'originale)") "Un messaggio che dice che nella cartella non si può scrivere (e di scegliere un'altra cartella)" "«$($msg.errore)»; il file si legge ($leggibile2 byte)" "diario (motore t20-motore lavoro to:jpg)"
  }
  if (-not $msg.ok -and $msg.errore -notmatch "(?i)permess|sola lettura|scriv") { Confuso "cartella in sola lettura" "il messaggio «$($msg.errore)» non dice che la cartella non si può scrivere" }
}
if ($script:OcrOk -and $r.ocr -notmatch "(?i)permess|scriv|cartella|permission|write|folder|access") { Nota "sola lettura: nella foto (OCR) non si legge un motivo chiaro: $($r.ocr -replace "`n", ' ')" }
& icacls $ro /remove:d "$env:USERNAME" 2>&1 | Out-Null

# ── 5. Un file tolto durante un lavoro su più file
$lot = Join-Path $casa "Lotto"; New-Item -ItemType Directory -Force $lot | Out-Null
Video "$lot\clip0.mp4" 20 "1920x1080" | Out-Null
for ($i = 1; $i -le 6; $i++) { Copy-Item "$lot\clip0.mp4" "$lot\Clip $i.mp4" }
Remove-Item "$lot\clip0.mp4"
$lista = (1..6 | ForEach-Object { "$lot\Clip $_.mp4" }) -join ";"
$script:Lot = $lot
$r = Avvia "7-lotto" @{ ORBIT_PROVA_FILE = $lista; ORBIT_PROVA_SCHEDA = "video"; ORBIT_PROVA_AZIONE = "vcompress"; ORBIT_PROVA_PARAMETRO = "best" } 120 { [bool](Get-ChildItem $script:Lot -Filter "Clip 1 *.mp4" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*.orbitlr-*" }) } -Resta
$tolto = $false
try { Remove-Item "$lot\Clip 5.mp4" -Force -ErrorAction Stop; $tolto = $true } catch { Log "Clip 5 non si toglie: $_" }
Log "tolto Clip 5 durante il lavoro: $tolto"
$fine = $null
for ($i = 0; $i -lt 150; $i++) {
  Start-Sleep -Seconds 2
  $fatti = @(Get-ChildItem $lot -Filter "Clip * *.mp4" | Where-Object { $_.Name -notlike "*.orbitlr-*" })
  if ($fatti | Where-Object { $_.Name -like "Clip 6 *" }) { $fine = $fatti; break }
}
Start-Sleep -Seconds 3
$f = Foto "7-lotto-fine"; $t = Ocr $f
$fatti = @(Get-ChildItem $lot -Filter "Clip * *.mp4" | Where-Object { $_.Name -notlike "*.orbitlr-*" } | ForEach-Object Name)
Log "lotto: risultati $($fatti -join ', ') · OCR: $($t -replace "`n", ' | ')"
Passo "file tolto durante il lavoro: l'app resta aperta" ([bool](Get-Process orbitlr -ErrorAction SilentlyContinue)) | Out-Null
if (-not (Passo "file tolto durante il lavoro: gli altri 5 vanno avanti" ($fatti.Count -ge 5) "$($fatti.Count) risultati: $($fatti -join ', ')")) {
  Bug "Lavoro su più video: se un file viene tolto a metà, gli altri non vengono fatti" "medio" @("Video → 6 video → Comprimi", "Durante il lavoro cancella il quinto video") "Gli altri 5 compressi e un messaggio per quello mancante" "$($fatti.Count) risultati: $($fatti -join ', ')" "7-lotto-fine.png"
}
Passo "file tolto durante il lavoro: nessun file a metà" ((Avanzi $lot).Count -eq 0) (((Avanzi $lot) | ForEach-Object Name) -join ", ") | Out-Null
Ferma

# ── 6. Un file da 3 GB
$big = Join-Path $casa "Grande 3GB.mkv"
$drive = (Get-PSDrive C).Free
if ($drive -lt 12GB) { NonEseguito "file da 3 GB" "spazio libero su C: solo $([math]::Round($drive / 1GB, 1)) GB" } else {
  $t0 = Get-Date
  FF @("-f", "lavfi", "-i", "testsrc2=size=1280x720:rate=30:duration=80", "-f", "lavfi", "-i", "sine=frequency=440:duration=80", "-c:v", "rawvideo", "-pix_fmt", "yuv420p", "-c:a", "pcm_s16le", $big)
  $gb = [math]::Round((Get-Item $big -ErrorAction SilentlyContinue).Length / 1GB, 2)
  Nota "file grande: $gb GB in $([math]::Round(((Get-Date) - $t0).TotalSeconds)) s"
  $r = Lavoro "8-grande-3GB" $big "video" "vcompress" "best" $casa "Grande 3GB *.mp4" 900
  $o = $r.nuovi | Where-Object { $_.Name -like "Grande 3GB *" -and $_.Name -notlike "*.orbitlr-*" } | Select-Object -First 1
  if (Passo "file da $gb GB: Comprimi riesce" ([bool]$o) "$(if ($o) { "$($o.Name) $([math]::Round($o.Length / 1MB, 1)) MB in $($r.finito_s) s" } else { 'nessun risultato in 15 minuti' })") {
    $po = Probe $o.FullName
    Passo "file da 3 GB: durata giusta" ([math]::Abs([double]$po.format.duration - 80) -lt 1) "$($po.format.duration) s" | Out-Null
  } else {
    Bug "Un video da 3 GB non si comprime" "medio" @("Video da $gb GB (non compresso, 80 s)", "Video → Comprimi") "Il video compresso" "nessun risultato in 15 minuti; app $(if ($r.viva) { 'aperta' } else { 'chiusa' }); OCR: $($r.ocr -replace "`n", ' ')" "$($r.nome).png"
  }
  Remove-Item $big -Force -ErrorAction SilentlyContinue
}

# ── 7. Utente con lettere non latine: TEMP con lettere non ANSI (un secondo utente Windows non si apre nella sessione dei computer di GitHub)
NonEseguito "secondo utente Windows con nome non latino" "su GitHub Actions la sessione è una sola: un'app con finestra non si apre come un altro utente (W01 ci ha provato: installazione «riuscita» senza file). Provato TEMP non ANSI; il bug della trascrizione con nome utente accentato è già provato da W05"
$tmpNA = "C:\Temp Иван 测试\Tmp ё"
New-Item -ItemType Directory -Force $tmpNA | Out-Null
$r = Avvia "9-temp-non-latino" @{ TEMP = $tmpNA; TMP = $tmpNA; ORBIT_PROVA_FILE = "$casa\base.mp4"; ORBIT_PROVA_SCHEDA = "video"; ORBIT_PROVA_AZIONE = "vcompress"; ORBIT_PROVA_PARAMETRO = "best" } 120 { [bool](Get-ChildItem $casa -Filter "base *.mp4" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*.orbitlr-*" }) }
if (-not (Passo "TEMP con lettere cirilliche e cinesi: Comprimi riesce" ([bool]$r.finito_s) "$($r.finito_s) s")) {
  Bug "Con la cartella TEMP con lettere non latine Comprimi non riesce" "medio" @("TEMP=C:\Temp Иван 测试\Tmp ё (come un utente con nome non latino)", "Video → Comprimi") "Il video compresso" "nessun risultato in 2 minuti" "$($r.nome).png"
}
Get-ChildItem $tmpNA -Recurse -ErrorAction SilentlyContinue | ForEach-Object { Log "in TEMP: $($_.FullName) $($_.Length)" }

$ew = ErroriWindows
Passo "nessun errore di Windows su OrbitLR" ($ew.Count -eq 0) ($ew -join " || ") | Out-Null
Salva "p18"
