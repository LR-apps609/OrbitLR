# Tester20 · P04 «Torna e aggiorna» (windows-2025): l'aggiornamento con il motore vero (controllo firmato, scarica,
# «Interrompi», «Riprova», passaggio all'installatore vero), i dati restano; «Aggiorna adesso / Interrompi / Riprova»
# nell'interfaccia vera in Chromium (p04-ui.mjs).
param([string]$Setup, [string]$Out)
$Profilo = "P04"
. "$PSScriptRoot\comune.ps1"
Info
$M = $env:T20_MOTORE
function Motore([string[]]$a) {
  $lines = & $M @a 2>&1 | ForEach-Object { "$_" }
  $lines | ForEach-Object { Log "motore: $_" }
  @($lines | Where-Object { $_ -like "T20|*" } | ForEach-Object { $_.Substring(4) | ConvertFrom-Json })
}
NonEseguito "aggiornamento da una 2.0 installata davvero" "l'installatore 2.0.0 non è più tra i file di windows-anteprima (solo 2.0.1): si prova il percorso con la 2.0.1 installata (motore vero, installatore vero, finta «versione vecchia» nel confronto delle versioni) come in agenti/W01"

$exe = Installa $Setup
if (-not $exe) { Bug "L'installazione silenziosa non installa OrbitLR" "bloccante" @("OrbitLR-Windows-2.0.1-Setup.exe /S") "orbitlr.exe installata" "non installata" "diario.txt"; Salva "p04"; exit 0 }
$dati = "$env:LOCALAPPDATA\it.ledion.orbitlr"; $conf = "$env:APPDATA\it.ledion.orbitlr"

# 1. Un primo uso: dati dell'utente (impostazioni della pagina, una cartella automatica, un file nella cartella dell'app)
$auto = Join-Path $env:USERPROFILE "Documents\Da convertire"; New-Item -ItemType Directory -Force $auto | Out-Null
New-Item -ItemType Directory -Force $conf | Out-Null
$regola = @(@{ id = "t20"; kind = "foto"; path = $auto; param = ""; enabled = $true }) | ConvertTo-Json -AsArray
Set-Content "$conf\cartelle.json" $regola -Encoding utf8
$r = Avvia "1-primo-uso" @{} 15
New-Item -ItemType Directory -Force $dati | Out-Null
Set-Content "$dati\t20-segno.txt" "dati dell'utente prima dell'aggiornamento" -Encoding utf8
$prima = @{
  cartelle = (Get-FileHash "$conf\cartelle.json").Hash
  pagina = (Test-Path "$dati\EBWebView\Default\Local Storage\leveldb")
  n = (Get-ChildItem $dati, $conf -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch "Cache|GPUCache|Crashpad|\.log$|LOCK$" }).Count
}
Log "prima: cartelle.json $($prima.cartelle) · memoria della pagina $($prima.pagina) · $($prima.n) file"
Passo "primo uso: OrbitLR si apre e si chiude" $r.viva | Out-Null

if (-not $M -or -not (Test-Path $M)) {
  NonEseguito "aggiornamento con il motore vero" "manca il programma di prova t20-motore.exe (compilazione non riuscita)"
} else {
  # 2. Controllo firmato, scarica, «Interrompi» al 20%, «Riprova»
  $agg = Motore @("aggiorna", "$dati\aggiornamento")
  foreach ($x in $agg) {
    switch ($x.passo) {
      "controlla" { Passo "controllo aggiornamenti: manifesto firmato letto" $x.ok "$($x.versione) build $($x.build) $($x.misura) byte in $([math]::Round($x.secondi,1)) s $($x.errore)" | Out-Null }
      "offerta a una versione più vecchia (2.0.0)" { if (-not (Passo "una 2.0 vede l'aggiornamento" $x.ok)) { Bug "Una OrbitLR 2.0 non vede l'aggiornamento 2.0.1" "alto" @("OrbitLR 2.0 aperta", "aspetta il controllo aggiornamenti") "«Nuovo aggiornamento disponibile»" "is_newer(manifesto, 2.0.0) = falso" "diario.txt (motore)" } }
      "non offerta a sé stessa" { Passo "la 2.0.1 non si offre a sé stessa" $x.ok | Out-Null }
      "interrompi" {
        if (-not (Passo "«Interrompi» durante lo scaricamento: si ferma e non lascia file" $x.ok "fermato al $([math]::Round($x.fermato_a * 100)) % · $($x.errore) · rimasti: $($x.file_rimasti -join ',')")) {
          Bug "«Interrompi» sull'aggiornamento lascia file o non si ferma" "medio" @("Aggiorna adesso", "Interrompi al 20%") "Scaricamento fermato, nessun file a metà" "errore «$($x.errore)», file rimasti: $($x.file_rimasti -join ', ')" "diario.txt (motore)"
        }
      }
      "riprova" {
        if (-not (Passo "«Riprova»: scarica tutto, impronta giusta" $x.ok "$($x.misura) byte in $([math]::Round($x.secondi,1)) s · $($x.errore)")) {
          Bug "«Riprova» dopo «Interrompi» non scarica l'aggiornamento" "alto" @("Aggiorna adesso", "Interrompi", "Riprova") "Aggiornamento scaricato e controllato" "$($x.errore)" "diario.txt (motore)"
        } else { $script:SetupScaricato = $x.file }
      }
    }
  }

  # 3. Il passaggio all'installatore vero (come update_install): OrbitLR si chiude, si installa /S, si riapre da sola
  if ($script:SetupScaricato) {
    $r = Avvia "2-prima-del-passaggio" @{} 12 -Resta
    $t0 = Get-Date
    $pp = Motore @("passaggio", $script:SetupScaricato, $exe)
    Log "chiusura dell'app (come app.exit dopo il passaggio): $(ChiudiBene)"
    $setupVisto = $false; $riaperta = $null
    for ($i = 0; $i -lt 90; $i++) {
      Start-Sleep -Seconds 2
      if (Get-Process | Where-Object { $_.Path -eq $script:SetupScaricato }) { $setupVisto = $true }
      $p = Get-CimInstance Win32_Process -Filter "Name='orbitlr.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CreationDate -gt $t0 } | Select-Object -First 1
      if ($p -and -not (Get-Process | Where-Object { $_.Path -eq $script:SetupScaricato })) { $riaperta = $p; break }
    }
    Start-Sleep -Seconds 6
    $f = Foto "3-dopo-aggiornamento"
    $sec = [math]::Round(((Get-Date) - $t0).TotalSeconds)
    if (Passo "dopo l'installazione OrbitLR si riapre da sola" ([bool]$riaperta) "$sec s · installatore visto: $setupVisto · $($riaperta.CommandLine)") {
      Passo "riaperta senza «aggiornamento non riuscito»" ($riaperta.CommandLine -notmatch "aggiornamento-non-riuscito") | Out-Null
    } else {
      Bug "Dopo «Aggiorna adesso» OrbitLR non si riapre" "alto" @("Aggiorna adesso", "aspetta la fine dello scaricamento") "OrbitLR si chiude, si aggiorna e si riapre" "dopo $sec s nessuna OrbitLR aperta (installatore visto: $setupVisto)" "3-dopo-aggiornamento.png"
    }
    $t = Ocr $f; Log "OCR dopo l'aggiornamento: $($t -replace "`n", ' | ')"
    Ferma
    # 4. I dati restano
    $dopo = @{
      cartelle = (Get-FileHash "$conf\cartelle.json" -ErrorAction SilentlyContinue).Hash
      pagina = (Test-Path "$dati\EBWebView\Default\Local Storage\leveldb")
      segno = (Test-Path "$dati\t20-segno.txt")
    }
    $ok = ($dopo.cartelle -eq $prima.cartelle) -and ($dopo.pagina -eq $prima.pagina) -and $dopo.segno
    if (-not (Passo "dopo l'aggiornamento i dati restano (cartelle automatiche, memoria della pagina, file dell'utente)" $ok "cartelle.json uguale: $($dopo.cartelle -eq $prima.cartelle) · memoria pagina: $($dopo.pagina) · segno: $($dopo.segno)")) {
      Bug "L'aggiornamento cancella dati dell'utente" "alto" @("Configura una cartella automatica", "Aggiorna adesso") "Impostazioni e cartelle automatiche come prima" "cartelle.json uguale: $($dopo.cartelle -eq $prima.cartelle) · memoria della pagina: $($dopo.pagina) · file dell'utente: $($dopo.segno)" "diario.txt"
    }
    $av = @(Get-ChildItem "$dati\aggiornamento" -ErrorAction SilentlyContinue)
    Nota "cartella aggiornamento dopo: $(($av | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ')"
    if ($av.Count) { Confuso "spazio occupato dopo l'aggiornamento" "l'installatore scaricato ($([math]::Round(($av | Measure-Object Length -Sum).Sum / 1MB)) MB) resta in %LOCALAPPDATA%\it.ledion.orbitlr\aggiornamento" }

    # 5. Installatore che non riesce: OrbitLR si riapre e lo dice (correzione 2.0.1)
    $rotto = Join-Path $env:TEMP "t20rotto\OrbitLR-Windows-9.9.9-Setup.exe"
    New-Item -ItemType Directory -Force (Split-Path $rotto) | Out-Null
    Copy-Item "$env:WINDIR\System32\where.exe" $rotto -Force   # «where /S» esce con errore: un installatore che non riesce
    $r = Avvia "4-prima-del-passaggio-rotto" @{} 12 -Resta
    $t0 = Get-Date
    Motore @("passaggio", $rotto, $exe) | Out-Null
    Log "chiusura: $(ChiudiBene)"
    $riaperta = $null
    for ($i = 0; $i -lt 30 -and -not $riaperta; $i++) { Start-Sleep -Seconds 2; $riaperta = Get-CimInstance Win32_Process -Filter "Name='orbitlr.exe'" -ErrorAction SilentlyContinue | Where-Object { $_.CreationDate -gt $t0 } | Select-Object -First 1 }
    Start-Sleep -Seconds 6
    $f = Foto "5-installatore-non-riuscito"
    $t = Ocr $f; Log "OCR: $($t -replace "`n", ' | ')"
    if (Passo "installatore che non riesce: OrbitLR si riapre con «non riuscito»" ([bool]$riaperta -and $riaperta.CommandLine -match "aggiornamento-non-riuscito") "$($riaperta.CommandLine)") {
      if ($script:OcrOk) {
        if (-not (Passo "e lo dice nella finestra («non è riuscito», «Riprova»)" ($t -match "(?i)non (è )?riuscit|riprova"))) { Confuso "aggiornamento non riuscito" "OrbitLR si è riaperta con --aggiornamento-non-riuscito ma nella foto (OCR) non si legge il motivo né «Riprova»" }
      }
    } else {
      Bug "Se l'installatore dell'aggiornamento non riesce, OrbitLR non si riapre" "alto" @("Aggiorna adesso con un installatore che fallisce") "OrbitLR si riapre e dice «aggiornamento non riuscito»" "nessuna OrbitLR riaperta in 60 s" "5-installatore-non-riuscito.png"
    }
    Ferma
  }
}

# 6. L'interfaccia: «Aggiorna adesso», «Interrompi», «Riprova» (Chromium, finto Tauri)
$ui = Join-Path $Out "ui"
& node (Join-Path $PSScriptRoot "ui\p04-ui.mjs") $ui 2>&1 | ForEach-Object { Log "ui: $_" }
if (Test-Path "$ui\parte-p04ui.json") { Copy-Item "$ui\parte-p04ui.json" $Out } else { NonEseguito "«Aggiorna adesso / Interrompi / Riprova» nell'interfaccia" "p04-ui.mjs non ha scritto il risultato" }
Salva "p04"
