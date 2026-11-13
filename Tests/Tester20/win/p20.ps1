# Tester20 · P20 «Telefono» (windows-2025): «Al telefono» con il server vero del motore (phone::share, come phone_share),
# la pagina aperta da un Chromium con misure di telefono (iPhone, Android), il file scaricato; poi il sito pubblico al telefono.
param([string]$Setup, [string]$Out)
$Profilo = "P20"
. "$PSScriptRoot\comune.ps1"
Info
$M = $env:T20_MOTORE
$exe = Installa $Setup
if (-not $exe) { Bug "L'installazione silenziosa non installa OrbitLR" "bloccante" @("OrbitLR-Windows-2.0.1-Setup.exe /S") "orbitlr.exe installata" "non installata" "diario.txt"; # Il sito pubblico al telefono
& node (Join-Path $PSScriptRoot "ui\p20-sito.mjs") (Join-Path $Out "sito") 2>&1 | ForEach-Object { Log "sito: $_" }
if (Test-Path (Join-Path $Out "sito\parte-p20sito.json")) { Copy-Item (Join-Path $Out "sito\parte-p20sito.json") $Out } else { NonEseguito "sito pubblico al telefono" "p20-sito.mjs non ha scritto il risultato" }
Salva "p20"; exit 0 }
$casa = Join-Path $env:USERPROFILE "Videos\Al telefono"; New-Item -ItemType Directory -Force $casa | Out-Null
$file = Join-Path $casa "Gita al lago è 🎉.mp4"
Video $file 10 | Out-Null
Nota "file da mandare: $file $((Get-Item $file).Length) byte"
if (-not $M -or -not (Test-Path $M)) {
  NonEseguito "«Al telefono» con il server vero" "manca t20-motore.exe (compilazione non riuscita)"
} else {
  $log = Join-Path $Out "condividi.txt"
  $p = Start-Process -FilePath $M -ArgumentList @("condividi", "`"$file`"", "300") -RedirectStandardOutput $log -PassThru -WindowStyle Hidden
  $url = $null
  for ($i = 0; $i -lt 40 -and -not $url; $i++) { Start-Sleep -Milliseconds 500; $l = Get-Content $log -ErrorAction SilentlyContinue | Where-Object { $_ -like "T20|*" } | Select-Object -First 1; if ($l) { $j = $l.Substring(4) | ConvertFrom-Json; if ($j.ok) { $url = $j.url } else { Log "condividi: $($j.errore)"; break } } }
  if (Passo "«Al telefono»: il server parte e dà un indirizzo nella rete di casa" ([bool]$url) "$url") {
    & node (Join-Path $PSScriptRoot "ui\p20-telefono.mjs") (Join-Path $Out "telefono") $url $file 2>&1 | ForEach-Object { Log "telefono: $_" }
    if (Test-Path (Join-Path $Out "telefono\parte-p20tel.json")) { Copy-Item (Join-Path $Out "telefono\parte-p20tel.json") $Out } else { NonEseguito "pagina del telefono" "p20-telefono.mjs non ha scritto il risultato" }
  } else {
    Bug "«Al telefono» non parte" "medio" @("Un video", "Al telefono") "Un codice QR con un indirizzo" "$(Get-Content $log -Raw)" "condividi.txt"
  }
  $p | Stop-Process -Force -ErrorAction SilentlyContinue
}
# Il sito pubblico al telefono
& node (Join-Path $PSScriptRoot "ui\p20-sito.mjs") (Join-Path $Out "sito") 2>&1 | ForEach-Object { Log "sito: $_" }
if (Test-Path (Join-Path $Out "sito\parte-p20sito.json")) { Copy-Item (Join-Path $Out "sito\parte-p20sito.json") $Out } else { NonEseguito "sito pubblico al telefono" "p20-sito.mjs non ha scritto il risultato" }
Salva "p20"
