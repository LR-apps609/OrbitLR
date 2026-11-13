# Tester20 · P06 «Esperto» (windows-2025): Ctrl+Alt+C da Esplora file, «Apri con OrbitLR» con l'app aperta,
# Cartelle automatiche (HEIC → JPG, cartella che sparisce per un attimo), «Rinomina tutti».
param([string]$Setup, [string]$Out)
$Profilo = "P06"
. "$PSScriptRoot\comune.ps1"
Info
$exe = Installa $Setup
if (-not $exe) { Bug "L'installazione silenziosa non installa OrbitLR" "bloccante" @("OrbitLR-Windows-2.0.1-Setup.exe /S") "orbitlr.exe installata" "non installata" "diario.txt"; Salva "p06"; exit 0 }
$casa = Join-Path $env:USERPROFILE "Documents\Esperto"
New-Item -ItemType Directory -Force $casa | Out-Null
Immagine "$casa\Foto esperto uno.png" | Out-Null
Immagine "$casa\Foto esperto due.png" "800x600" | Out-Null

# ── 1. Ctrl+Alt+C: i file selezionati in Esplora file vanno in OrbitLR
$r = Avvia "1-app-aperta" @{} 12 -Resta
$app = FinestraApp
[T20W]::ShowWindow($app, 6) | Out-Null   # ridotta a icona, come quando si lavora in Esplora file
# La combinazione è presa da OrbitLR? (se sì, un altro programma non la può registrare)
$libera = [T20W]::RegisterHotKey([IntPtr]::Zero, 7720, 0x0003, 0x43)
if ($libera) { [T20W]::UnregisterHotKey([IntPtr]::Zero, 7720) | Out-Null }
if (-not (Passo "Ctrl+Alt+C registrata da OrbitLR" (-not $libera))) {
  Bug "Ctrl+Alt+C non è registrata da OrbitLR" "medio" @("Apri OrbitLR", "Prova a registrare Ctrl+Alt+C da un altro programma") "Combinazione occupata da OrbitLR" "la combinazione è libera: OrbitLR non la ascolta" "RegisterHotKey riuscita mentre OrbitLR è aperta"
}
Start-Process explorer.exe $casa
$sh = New-Object -ComObject Shell.Application
$w = $null
for ($i = 0; $i -lt 30 -and -not $w; $i++) { Start-Sleep -Milliseconds 500; $w = @($sh.Windows()) | Where-Object { try { $_.Document.Folder.Self.Path -eq $casa } catch { $false } } | Select-Object -First 1 }
if (-not $w) {
  NonEseguito "Ctrl+Alt+C da Esplora file" "la finestra di Esplora file non si trova con Shell.Application su questo computer"
} else {
  $doc = $w.Document
  $doc.SelectItem($doc.Folder.ParseName("Foto esperto uno.png"), 1 + 4 + 8 + 16)
  $doc.SelectItem($doc.Folder.ParseName("Foto esperto due.png"), 1)
  $hw = [IntPtr]$w.HWND
  [T20W]::Keys(@(0x12)) # Alt: permette di portare in primo piano
  [T20W]::SetForegroundWindow($hw) | Out-Null
  Start-Sleep -Milliseconds 800
  $fg = [T20W]::GetForegroundWindow()
  Log "Esplora file $hw in primo piano: $($fg -eq $hw) (primo piano: $fg «$([T20W]::Title($fg))»)"
  # (a) Lo stesso comando che OrbitLR usa per leggere la selezione (main.rs explorer_selection)
  $cmdSel = "[Console]::OutputEncoding=[Text.Encoding]::UTF8; `$h=$fg; foreach(`$w in (New-Object -ComObject Shell.Application).Windows()){ try { if(`$w.HWND -eq `$h){ foreach(`$i in `$w.Document.SelectedItems()){ `$i.Path } } } catch {} }"
  $sel = & powershell -NoProfile -NonInteractive -ExecutionPolicy Bypass -Command $cmdSel 2>&1 | Out-String
  $n = @($sel -split "`r?`n" | Where-Object { $_ -match "Foto esperto" }).Count
  Passo "Ctrl+Alt+C, lettura della selezione di Esplora file (stesso comando di OrbitLR)" ($n -eq 2) ($sel.Trim() -replace "`r?`n", " | ") | Out-Null
  # (b) La combinazione vera
  $t0 = Get-Date
  [T20W]::Keys(@(0x11, 0x12, 0x43))
  $ok = $false
  for ($i = 0; $i -lt 40; $i++) { Start-Sleep -Milliseconds 500; if ([T20W]::GetForegroundWindow() -eq (FinestraApp)) { $ok = $true; break } }
  Start-Sleep -Seconds 3
  $f = Foto "2-dopo-ctrl-alt-c"
  $t = Ocr $f; Log "OCR dopo Ctrl+Alt+C: $($t -replace "`n", ' | ')"
  if (Passo "Ctrl+Alt+C porta in primo piano OrbitLR" $ok "$([math]::Round(((Get-Date) - $t0).TotalSeconds, 1)) s") {
    if ($script:OcrOk) {
      $visti = ($t -match "(?i)esperto uno") -and ($t -match "(?i)esperto due")
      if (-not (Passo "Ctrl+Alt+C: i due file selezionati sono in OrbitLR" $visti)) {
        if ($t -match "(?i)esperto") { Nota "Ctrl+Alt+C: l'OCR legge solo uno dei due nomi" } else {
          Bug "Ctrl+Alt+C apre OrbitLR ma senza i file selezionati in Esplora file" "medio" @("In Esplora file seleziona due foto", "Premi Ctrl+Alt+C") "OrbitLR in primo piano con le due foto" "OrbitLR in primo piano, i nomi delle foto non si vedono (OCR)" "2-dopo-ctrl-alt-c.png, .ocr.txt"
        }
      }
    }
  } else {
    Bug "Ctrl+Alt+C da Esplora file non apre OrbitLR" "medio" @("OrbitLR aperta e ridotta a icona", "In Esplora file seleziona due foto", "Premi Ctrl+Alt+C") "OrbitLR in primo piano con le foto" "dopo 20 s in primo piano c'è «$([T20W]::Title([T20W]::GetForegroundWindow()))»" "2-dopo-ctrl-alt-c.png"
  }
  try { $w.Quit() } catch {}
}

# ── 2. «Apri con OrbitLR» mentre è già aperta: niente seconda OrbitLR, il file arriva nella finestra
$prima = @(Get-Process orbitlr -ErrorAction SilentlyContinue).Count
Start-Process -FilePath $exe -ArgumentList "`"$casa\Foto esperto due.png`""
Start-Sleep -Seconds 5
$dopo = @(Get-Process orbitlr -ErrorAction SilentlyContinue).Count
Passo "«Apri con OrbitLR» con l'app aperta: una sola OrbitLR" ($dopo -le [math]::Max(1, $prima)) "processi prima $prima, dopo $dopo" | Out-Null
Foto "3-apri-con" | Out-Null
Ferma

# ── 3. Cartelle automatiche: HEIC → JPG; la cartella sparisce per un attimo
$auto = Join-Path $env:USERPROFILE "Pictures\Dal telefono"
New-Item -ItemType Directory -Force $auto | Out-Null
$heic = Join-Path $PSScriptRoot "..\..\..\Windows\engine\tests\fixtures\iphone-gps.heic"
Copy-Item $heic "$auto\Vecchia gia qui.heic"
$conf = "$env:APPDATA\it.ledion.orbitlr"; New-Item -ItemType Directory -Force $conf | Out-Null
@(@{ id = "t20foto"; kind = "foto"; path = $auto; param = ""; enabled = $true }) | ConvertTo-Json -AsArray | Set-Content "$conf\cartelle.json" -Encoding utf8
$r = Avvia "4-cartella-automatica" @{} 10 -Resta
Start-Sleep -Seconds 8
Copy-Item $heic "$auto\Dal telefono 1.heic"
$t0 = Get-Date; $jpg = $null
for ($i = 0; $i -lt 40 -and -not $jpg; $i++) { Start-Sleep -Seconds 1; $jpg = Get-ChildItem $auto -Filter "Dal telefono 1*.jpg" -ErrorAction SilentlyContinue | Select-Object -First 1 }
if (Passo "cartella automatica: la HEIC nuova diventa JPG" ([bool]$jpg) "$(if ($jpg) { "$($jpg.Name) $($jpg.Length) byte in $([math]::Round(((Get-Date) - $t0).TotalSeconds)) s" } else { 'nessun JPG in 40 s' })") {
  $pj = Probe $jpg.FullName
  Passo "il JPG è un'immagine valida" ([bool]($pj.streams | Where-Object { $_.width -gt 0 })) | Out-Null
} else {
  Bug "Cartelle automatiche: una foto HEIC nuova non diventa JPG" "alto" @("Cartelle automatiche → «Foto in JPG» su una cartella", "Copia una foto HEIC nella cartella") "Il JPG accanto alla HEIC in pochi secondi" "nessun JPG dopo 40 s" "4-cartella-automatica.png, cartelle.json"
}
$vecchia = Get-ChildItem $auto -Filter "Vecchia gia qui*.jpg" -ErrorAction SilentlyContinue
if (-not (Passo "la foto che c'era già non si tocca" (-not $vecchia))) { Bug "Cartelle automatiche: converte anche le foto che c'erano già" "basso" @("Cartella con una HEIC già dentro", "Attiva la cartella automatica") "Solo i file arrivati dopo" "creato $($vecchia.Name)" "elenco della cartella" }
# Sparisce per 8 s (scheda SD tolta, rinominata da un altro programma, OneDrive)
$n1 = @(Get-ChildItem $auto -Filter *.jpg).Count
Rename-Item $auto "$auto (spostata)"
Start-Sleep -Seconds 8
Rename-Item "$auto (spostata)" $auto
Start-Sleep -Seconds 12
$n2 = @(Get-ChildItem $auto -Filter *.jpg).Count
if (-not (Passo "cartella sparita per un attimo: al ritorno non rifà le foto già fatte" ($n2 -eq $n1) "JPG prima $n1, dopo $n2: $((Get-ChildItem $auto | ForEach-Object Name) -join ', ')")) {
  Bug "Cartelle automatiche: quando la cartella sparisce per un attimo, al ritorno rifà le foto" "medio" @("Cartella automatica attiva con una foto già convertita", "Rinomina la cartella e rimettila com'era dopo 8 s") "Nessun file nuovo" "JPG da $n1 a $n2" "elenco nel diario"
}
Copy-Item $heic "$auto\Dal telefono 2.heic"
$jpg2 = $null
for ($i = 0; $i -lt 40 -and -not $jpg2; $i++) { Start-Sleep -Seconds 1; $jpg2 = Get-ChildItem $auto -Filter "Dal telefono 2*.jpg" -ErrorAction SilentlyContinue | Select-Object -First 1 }
if (-not (Passo "dopo il ritorno della cartella le foto nuove si convertono ancora" ([bool]$jpg2))) {
  Bug "Cartelle automatiche: dopo che la cartella è sparita per un attimo non lavora più" "alto" @("Cartella automatica attiva", "Rinomina la cartella e rimettila", "Copia una HEIC nuova") "Il JPG compare" "nessun JPG in 40 s" "diario"
}
$f = Foto "5-cartella-dopo"
Passo "nessun file a metà nella cartella automatica" ((Avanzi $auto).Count -eq 0) | Out-Null
Passo "OrbitLR ancora aperta" ([bool](Get-Process orbitlr -ErrorAction SilentlyContinue)) | Out-Null
Ferma
Remove-Item "$conf\cartelle.json" -Force -ErrorAction SilentlyContinue

# ── 4. Rinomina tutti
$ren = Join-Path $env:USERPROFILE "Pictures\Da rinominare"
New-Item -ItemType Directory -Force $ren | Out-Null
$orig = @("IMG_0003.jpg", "IMG_0001.jpg", "IMG_0010.jpg", "IMG_0002.jpg", "foto è.jpg")
$hash = @{}
$k = 0
foreach ($o in $orig) { $k++; Immagine "$ren\$o" "$(300 + 10 * $k)x200" | Out-Null; $hash[(Get-FileHash "$ren\$o").Hash] = $o }
Immagine "$ren\Vacanze 002.jpg" "123x77" | Out-Null   # un file che c'è già e non è scelto
$hEstraneo = (Get-FileHash "$ren\Vacanze 002.jpg").Hash
$lista = ($orig | ForEach-Object { "$ren\$_" }) -join ";"
$r = Avvia "6-rinomina" @{ ORBIT_PROVA_FILE = $lista; ORBIT_PROVA_SCHEDA = "image"; ORBIT_PROVA_AZIONE = "rename"; ORBIT_PROVA_PARAMETRO = "Vacanze" } 40 { -not (Test-Path "$ren\IMG_0001.jpg") -and -not (Test-Path "$ren\foto è.jpg") }
$dopo = Get-ChildItem $ren -File | Sort-Object Name
Log "dopo Rinomina tutti: $(($dopo | ForEach-Object { "$($_.Name)=$($hash[(Get-FileHash $_.FullName).Hash])" }) -join ' · ')"
$nuovi = @($dopo | Where-Object { $hash.ContainsKey((Get-FileHash $_.FullName).Hash) })
$tuttiRinominati = ($nuovi.Count -eq 5) -and -not ($nuovi | Where-Object { $_.Name -notlike "Vacanze *" })
if (-not (Passo "Rinomina tutti: 5 file diventano «Vacanze …», nessuna copia" ($tuttiRinominati -and $dopo.Count -eq 6) "$(($dopo | ForEach-Object Name) -join ', ')")) {
  Bug "Rinomina tutti non rinomina tutti i file scelti" "medio" @("Scegli 5 foto in Immagini", "Rinomina tutti → «Vacanze»") "Vacanze 001…005 al posto degli originali" "$(($dopo | ForEach-Object Name) -join ', ')" "diario"
}
$estraneo = Get-ChildItem $ren -File | Where-Object { (Get-FileHash $_.FullName).Hash -eq $hEstraneo }
if (-not (Passo "il «Vacanze 002.jpg» che c'era già non viene sovrascritto" ([bool]$estraneo) "ora si chiama $($estraneo.Name)")) {
  Bug "Rinomina tutti sovrascrive un file che c'era già con lo stesso nome" "alto" @("Nella cartella c'è già «Vacanze 002.jpg» (non scelto)", "Rinomina tutti altre 5 foto in «Vacanze»") "Il file che c'era resta" "il file «Vacanze 002.jpg» originale non c'è più" "impronte nel diario"
}
# Ordine: per nome (IMG_0001, IMG_0002, IMG_0003, IMG_0010, foto è)
$ordine = @($nuovi | Sort-Object { [int]($_.BaseName -replace '\D', '') } | ForEach-Object { $hash[(Get-FileHash $_.FullName).Hash] })
$atteso = @("IMG_0001.jpg", "IMG_0002.jpg", "IMG_0003.jpg", "IMG_0010.jpg", "foto è.jpg")
if (-not (Passo "Rinomina tutti segue l'ordine dei nomi" (($ordine -join "|") -eq ($atteso -join "|")) "numeri dati a: $($ordine -join ', ')")) {
  Confuso "ordine di Rinomina tutti" "l'aiuto dice «in ordine di nome» ma i numeri vanno a: $($ordine -join ', ')"
}
Salva "p06"
