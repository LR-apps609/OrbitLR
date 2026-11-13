# Tester20 · P19W «Rete assente» (windows-2025): OrbitLR bloccata dal Firewall di Windows (uscita) e poi sbloccata.
# Avvio, controllo aggiornamenti, Audio/Video Downloader, primo scaricamento del modello dell'IA.
param([string]$Setup, [string]$Out)
$Profilo = "P19W"
. "$PSScriptRoot\comune.ps1"
Info
$M = $env:T20_MOTORE
$exe = Installa $Setup
if (-not $exe) { Bug "L'installazione silenziosa non installa OrbitLR" "bloccante" @("OrbitLR-Windows-2.0.1-Setup.exe /S") "orbitlr.exe installata" "non installata" "diario.txt"; Salva "p19"; exit 0 }
$dati = "$env:LOCALAPPDATA\it.ledion.orbitlr"
function Motore([string[]]$a) {
  if (-not $M -or -not (Test-Path $M)) { return $null }
  $lines = & $M @a 2>&1 | ForEach-Object { "$_" }
  $lines | ForEach-Object { Log "motore: $_" }
  @($lines | Where-Object { $_ -like "T20|*" } | ForEach-Object { $_.Substring(4) | ConvertFrom-Json }) | Select-Object -First 1
}

# ── Il blocco: Firewall di Windows, regole in uscita sui programmi di OrbitLR (e su WebView2, che fa le richieste della pagina)
$fw = Get-NetFirewallProfile | ForEach-Object { "$($_.Name)=$($_.Enabled)/$($_.DefaultOutboundAction)" }
Nota "Firewall prima: $($fw -join ' ') · servizio mpssvc $((Get-Service mpssvc).Status)"
Set-NetFirewallProfile -All -Enabled True -ErrorAction SilentlyContinue
$prog = @($exe) + @(Get-ChildItem (Split-Path $exe) -Recurse -Filter *.exe | ForEach-Object FullName) + @(Get-ChildItem "${env:ProgramFiles(x86)}\Microsoft\EdgeWebView\Application" -Recurse -Filter msedgewebview2.exe -ErrorAction SilentlyContinue | ForEach-Object FullName)
if ($M) { $prog += $M }
$prog += "$env:WINDIR\System32\curl.exe"   # controllo che il blocco funzioni davvero
$prog = $prog | Select-Object -Unique
function Blocca() {
  $i = 0
  foreach ($p in $prog) { $i++; New-NetFirewallRule -DisplayName "T20 blocco $i" -Group "T20" -Direction Outbound -Program $p -Action Block -Profile Any -ErrorAction SilentlyContinue | Out-Null }
  # La cartella dei dati: yt-dlp e il motore dell'IA arrivano lì (bloccati con una regola per programma quando ci sono)
  Log "bloccati in uscita: $($prog.Count) programmi"
}
function Sblocca() { Get-NetFirewallRule -Group "T20" -ErrorAction SilentlyContinue | Remove-NetFirewallRule }
Blocca
Start-Sleep -Seconds 3
$curl = & curl.exe -s -o NUL -m 15 -w "%{http_code}" https://github.com 2>&1
$ctrl = try { (Invoke-WebRequest https://github.com -UseBasicParsing -TimeoutSec 20).StatusCode } catch { "errore $_" }
Log "verifica blocco: curl (bloccato) → «$curl» · pwsh (non bloccato) → $ctrl"
if (-not (Passo "il blocco del Firewall funziona (curl bloccato, il resto no)" (($curl -notmatch "^200|^30") -and $ctrl -eq 200) "curl «$curl», pwsh $ctrl")) {
  NonEseguito "prove con la rete bloccata" "il Firewall di Windows non blocca i programmi su questo computer (curl «$curl»): le prove sotto non dicono niente sulla rete assente"
}

# ── 1. Avvio senza rete: si apre, il controllo aggiornamenti (dopo 4 s) non disturba
$r = Avvia "1-avvio-senza-rete" @{} 30 -Resta
$t = Ocr $r.foto; Log "OCR: $($t -replace "`n", ' | ')"
Passo "senza rete OrbitLR si apre e risponde" ($r.viva -and -not $r.bloccata) "finestra a $($r.finestra_s) s" | Out-Null
if ($script:OcrOk -and $t -match "(?i)aggiornamento non riuscito|errore|error") { Confuso "avvio senza rete" "all'avvio compare un messaggio d'errore: $($t -replace "`n", ' ')" }
Ferma
$c = Motore @("controlla")
if ($c) {
  if (-not $c.ok) { Tecnico "controllo aggiornamenti senza rete" $c.errore }
  if (-not (Passo "controllo aggiornamenti senza rete: risponde presto con un errore" ((-not $c.ok) -and $c.secondi -lt 60) "$([math]::Round($c.secondi,1)) s · «$($c.errore)»")) {
    if ($c.ok) { NonEseguito "controllo aggiornamenti senza rete" "il controllo è riuscito: il blocco non ha fermato t20-motore" } else { Bug "Senza rete il controllo aggiornamenti resta appeso a lungo" "basso" @("Rete assente", "OrbitLR controlla gli aggiornamenti") "Risposta in pochi secondi" "$([math]::Round($c.secondi)) s" "diario (motore)" }
  }
} else { NonEseguito "controllo aggiornamenti (motore)" "manca t20-motore.exe" }

# ── 2. Audio/Video Downloader senza rete (il primo uso scarica anche yt-dlp)
$dl = Join-Path $env:USERPROFILE "Downloads"; New-Item -ItemType Directory -Force $dl | Out-Null
$prima = @(Get-ChildItem $dl -File | ForEach-Object Name)
$segnaposto = Join-Path $env:TEMP "t20-link.txt"; Set-Content $segnaposto "link"
$r = Avvia "2-downloader-senza-rete" @{ ORBIT_PROVA_FILE = $segnaposto; ORBIT_PROVA_SCHEDA = "convert"; ORBIT_PROVA_AZIONE = "link"; ORBIT_PROVA_PARAMETRO = '{"link":"https://www.youtube.com/watch?v=jNQXAC9IVRw","mode":"audio"}' } 75 -Resta
$t = Ocr $r.foto; Log "OCR downloader: $($t -replace "`n", ' | ')"
$nuovi = @(Get-ChildItem $dl -File | Where-Object { $prima -notcontains $_.Name })
Passo "downloader senza rete: app aperta, nessun file a metà nei Download" ($r.viva -and $nuovi.Count -eq 0) "$(($nuovi | ForEach-Object Name) -join ', ')" | Out-Null
$yt = Get-ChildItem $dati -Recurse -Filter "yt-dlp*" -ErrorAction SilentlyContinue
Passo "downloader senza rete: nessun yt-dlp a metà nei dati" (-not ($yt | Where-Object { $_.Length -lt 1MB })) "$(($yt | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ')" | Out-Null
Ferma
$l = Motore @("link", "https://www.youtube.com/watch?v=jNQXAC9IVRw", $dati, $dl, $script:Motori)
if ($l) {
  if (-not $l.ok) { Tecnico "downloader senza rete" $l.errore }
  Nota "downloader senza rete · motore: $(if ($l.ok) { 'RIUSCITO?' } else { "«$($l.errore)»" }) in $([math]::Round($l.secondi, 1)) s"
  if (-not $l.ok -and $l.secondi -gt 120) { Bug "Downloader senza rete: l'errore arriva dopo più di 2 minuti" "basso" @("Rete assente", "Audio/Video Downloader con un link") "Un messaggio in pochi secondi" "$([math]::Round($l.secondi)) s" "diario (motore)" }
  if (-not $l.ok -and $l.errore -notmatch "(?i)internet|rete|connession|collegat") { Confuso "downloader senza rete" "il messaggio «$($l.errore)» non dice che manca la connessione" }
}

# ── 3. Il primo scaricamento del modello dell'IA (Rimuovi lo sfondo) senza rete
$casa = Join-Path $env:USERPROFILE "Pictures\Senza rete"; New-Item -ItemType Directory -Force $casa | Out-Null
Immagine "$casa\Ritratto.png" "800x1000" | Out-Null
$r = Avvia "3-ia-senza-rete" @{ ORBIT_PROVA_FILE = "$casa\Ritratto.png"; ORBIT_PROVA_SCHEDA = "image"; ORBIT_PROVA_AZIONE = "removebg"; ORBIT_PROVA_PARAMETRO = "" } 90 -Resta
$t = Ocr $r.foto; Log "OCR IA senza rete: $($t -replace "`n", ' | ')"
$mod = @(Get-ChildItem "$dati\modelli" -Recurse -File -ErrorAction SilentlyContinue)
Passo "IA senza rete: app aperta e nessun risultato finto" ($r.viva -and -not (Get-ChildItem $casa -Filter "Ritratto *" -ErrorAction SilentlyContinue)) | Out-Null
if (-not (Passo "IA senza rete: nessun modello a metà lasciato nei dati" (-not ($mod | Where-Object { $_.Length -lt 150MB })) "$(($mod | ForEach-Object { "$($_.Name) $($_.Length)" }) -join ', ')")) {
  Bug "Senza rete resta un modello dell'IA a metà" "medio" @("Rete assente", "Immagini → Rimuovi lo sfondo (prima volta)") "Nessun file a metà; la prossima volta riscarica" "$(($mod | ForEach-Object { "$($_.Name) $($_.Length) byte" }) -join ', ')" "elenco di modelli"
}
if ($script:OcrOk) { Nota "IA senza rete, cosa dice la finestra (OCR): $($t -replace "`n", ' ')" }
Ferma
$m = Motore @("lavoro", "removebg", "null", $script:Motori, $dati, "$casa\Ritratto.png")
if ($m) {
  if (-not $m.ok) { Tecnico "IA senza rete (Rimuovi lo sfondo)" $m.errore }
  Nota "IA senza rete · motore: $(if ($m.ok) { 'RIUSCITO?' } else { "«$($m.errore)»" }) in $([math]::Round($m.secondi, 1)) s"
  if (-not $m.ok -and $m.errore -notmatch "(?i)internet|rete|connession|collegat|scaric") { Confuso "IA senza rete" "il messaggio «$($m.errore)» non dice che serve internet per il primo scaricamento" }
  if (-not $m.ok -and $m.secondi -gt 120) { Bug "Senza rete l'IA aspetta più di 2 minuti prima di dire che non riesce" "basso" @("Rete assente", "Rimuovi lo sfondo") "Un messaggio in pochi secondi" "$([math]::Round($m.secondi)) s" "diario (motore)" }
}

# ── 4. La rete torna: tutto riparte (il modello si scarica e la foto si fa)
Sblocca
Start-Sleep -Seconds 3
$r = Avvia "4-ia-rete-tornata" @{ ORBIT_PROVA_FILE = "$casa\Ritratto.png"; ORBIT_PROVA_SCHEDA = "image"; ORBIT_PROVA_AZIONE = "removebg"; ORBIT_PROVA_PARAMETRO = "" } 300 { [bool](Get-ChildItem $casa -Filter "Ritratto *" -ErrorAction SilentlyContinue | Where-Object { $_.Name -notlike "*.orbitlr-*" }) }
if (-not (Passo "rete tornata: Rimuovi lo sfondo scarica il modello e funziona" ([bool]$r.finito_s) "$($r.finito_s) s")) {
  Bug "Dopo un tentativo senza rete, l'IA non funziona più neanche con la rete" "alto" @("Rimuovi lo sfondo senza rete", "Rete di nuovo collegata", "Rimuovi lo sfondo") "Il modello si scarica e la foto si fa" "nessun risultato in 5 minuti" "$($r.nome).png"
}
Salva "p19"
