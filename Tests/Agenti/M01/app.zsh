#!/bin/zsh
# M01 · Apre OrbitLR con dei file (come «Apri con» / trascinarli sull'icona) e fotografa le finestre.
# Uso: app.zsh FIXTURES USCITA FINESTRA(programma)
emulate zsh
setopt NO_NOMATCH
FX=$1 OUT=$2 FIN=$3
t() { perl -e 'alarm shift; exec @ARGV' "$@"; }
mkdir -p "$OUT"
R="$OUT/risultato.txt"; : > "$R"
say() { print -r -- "$*" | tee -a "$R"; }
D=it.ledion.OrbitLR
V=$(defaults read /Applications/OrbitLR.app/Contents/Info.plist CFBundleShortVersionString 2>/dev/null)
say "versione: $V"
defaults write $D welcomeDone -bool true
defaults write $D launchScreen -bool false
defaults write $D tips -bool false
defaults write $D lastLaunchVersion -string "$V"
( cd "$FX" && find . -type f -print0 | xargs -0 shasum -a 256 | sort ) > "$OUT/prima.sha"
ls -la ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -ci orbit > "$OUT/crash-prima.txt"
quit() { t 15 osascript -e 'quit app "OrbitLR"' >/dev/null 2>&1; sleep 2; pkill -x OrbitLR; sleep 1; }
shot() {  # nome
  local W; W=$(t 20 "$FIN" --tutte); say "  finestra: ${W:-nessuna}"
  [[ -n $W ]] && t 20 screencapture -x -o -l"${W%% *}" "$OUT/$1-finestra.png"
  t 20 screencapture -x "$OUT/$1-schermo.png"
  t 20 "$FIN" --elenco | grep -i orbit | sed 's/^/  /' | tee -a "$R"
}
prova() {  # nome, file…
  local n=$1; shift
  quit
  say "=== $n: $# file"
  local s=$EPOCHREALTIME
  t 30 open -a /Applications/OrbitLR.app "$@"; say "  open: uscita $?"
  sleep 14
  if pgrep -x OrbitLR >/dev/null; then say "  processo vivo: sì"; else say "  processo vivo: NO"; fi
  # risponde? (una domanda via AppleScript con tempo massimo)
  local s2=$EPOCHREALTIME
  t 20 osascript -e 'tell application "System Events" to get name of every window of process "OrbitLR"' > "$OUT/$n-finestre.txt" 2>&1
  say "  risposta di System Events: $? in $(printf '%.1f' $(( EPOCHREALTIME - s2 ))) s · $(head -c 200 "$OUT/$n-finestre.txt")"
  shot "$n"
}
cd "$FX"
prova una "$FX/gps.jpg"
prova cinque "$FX/gps.jpg" "$FX/alpha.png" "$FX/orient6.jpg" "$FX/deep16.tiff" "$FX/cmyk.jpg"
prova nomi "$FX/foto 😀 mare.png" "$FX/l'estate \"2025\".jpg" "$FX/\$(touch PWNED).jpg" "$FX/a;b&c|d.png" "$FX/Città è perché.jpg" "$FX"/aaaa*.jpg
prova grande "$FX/huge.jpg"
prova rotte "$FX/rotta.jpg" "$FX/vuota.png"
prova bloccata "$FX/bloccata/dentro.jpg"
prova tutte "$FX"/*(.N)
prova gif-webp-heic "$FX/anim.gif" "$FX/photo.webp" "$FX/gps.heic"
quit
( cd "$FX" && find . -type f -print0 | xargs -0 shasum -a 256 | sort ) > "$OUT/dopo.sha"
if cmp -s "$OUT/prima.sha" "$OUT/dopo.sha"; then say "file di prova: nessun cambiamento"
else say "file di prova: CAMBIATI"; diff "$OUT/prima.sha" "$OUT/dopo.sha" | head -n 40 | tee -a "$R"; fi
say "PWNED: $(find "$FX" "$HOME" -maxdepth 4 -name PWNED 2>/dev/null | wc -l | tr -d ' ')"
mkdir -p "$OUT/crash"
cp ~/Library/Logs/DiagnosticReports/OrbitLR* "$OUT/crash/" 2>/dev/null
say "rapporti di arresto: $(ls "$OUT/crash" | wc -l | tr -d ' ')"
cp ~/Library/Logs/LRConverter.log "$OUT/" 2>/dev/null
ls ~/Desktop | sed 's/^/  scrivania: /' | tee -a "$R"
cp ~/Desktop/*.txt "$OUT/crash/" 2>/dev/null
exit 0
