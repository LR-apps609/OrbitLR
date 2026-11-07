# W08 - fa come un antivirus: apre i file temporanei di OrbitLR (.orbitlr-*) appena compaiono,
# in lettura, condividendo lettura e scrittura ma NON la cancellazione/rinomina, e li tiene aperti
# finche' non sono fermi da $Hold secondi.
param([string]$Dir, [double]$Hold = 8, [int]$Max = 240, [string]$LogFile)
function L([string]$m) { Add-Content -Path $LogFile -Value "$(Get-Date -Format HH:mm:ss.fff) $m" -Encoding utf8 }
$open = @{}
$t0 = Get-Date
L "inizio: cartella $Dir, tengo $Hold s dopo che il file e' fermo"
while (((Get-Date) - $t0).TotalSeconds -lt $Max) {
  foreach ($f in Get-ChildItem $Dir -Force -Filter ".orbitlr-*" -ErrorAction SilentlyContinue) {
    if (-not $open.ContainsKey($f.FullName)) {
      try {
        $h = [IO.File]::Open($f.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        $open[$f.FullName] = @{ h = $h; size = -1; changed = Get-Date }
        L "aperto $($f.Name)"
      } catch { L "non riesco ad aprire $($f.Name): $($_.Exception.Message)"; $open[$f.FullName] = @{ h = $null } }
    }
  }
  foreach ($k in @($open.Keys)) {
    $e = $open[$k]
    if (-not $e.h) { continue }
    $s = try { $e.h.Length } catch { -2 }
    if ($s -ne $e.size) { $e.size = $s; $e.changed = Get-Date }
    elseif (((Get-Date) - $e.changed).TotalSeconds -ge $Hold) { $e.h.Close(); $e.h = $null; L "chiuso $(Split-Path $k -Leaf) (fermo da $Hold s a $s byte)" }
  }
  Start-Sleep -Milliseconds 100
}
foreach ($k in @($open.Keys)) { if ($open[$k].h) { $open[$k].h.Close(); L "chiuso alla fine $k" } }
L "fine"
