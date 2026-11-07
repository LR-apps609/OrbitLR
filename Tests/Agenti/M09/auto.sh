#!/bin/zsh
# M09 · Cartelle automatiche, azioni salvate e link orbitlr:// sull'app vera.
# Uso: auto.sh <cartella-uscita> <OrbitLR.app>
OUT=$1; APP=$2; H=${0:A:h}
A="$OUT/auto"; mkdir -p "$A"; R="$A/risultato.txt"; : > "$R"
say() { echo "$*" | tee -a "$R"; }
t() { perl -e 'alarm shift; exec @ARGV' "$@"; }
FF="$APP/Contents/Resources/Motori/ffmpeg"
S="$HOME/Library/Application Support/LRConverter"; P="$HOME/Prova"
quit_app() { t 20 osascript -e 'quit app "OrbitLR"' >/dev/null 2>&1; sleep 3; pkill -x OrbitLR; sleep 1; }
open_app() { open "$APP"; sleep 15; pgrep -x OrbitLR >/dev/null && say "  app aperta" || say "  APP NON APERTA"; }
shot() { t 20 screencapture -x "$A/$1.png" 2>/dev/null; }
alive() { pgrep -x OrbitLR >/dev/null && echo viva || echo CHIUSA; }
snap() {   # elenco dei file in tutte le cartelle di prova
  say "  [$1] $(cd "$P" && find . -type f ! -name '.*' | sort | tr '\n' ' ')"; }
count() { find "$1" -type f ! -name '.*' 2>/dev/null | wc -l | tr -d ' '; }

quit_app
rm -rf "$P"; mkdir -p "$P"/{Foto,A,B,Video,Preset,Lenta,Orfana}
img() { "$FF" -v error -y -f lavfi -i "testsrc2=size=$2:rate=1" -frames:v 1 "$1"; }
mkdir -p "$A/fx"; for n in uno due tre; do img "$A/fx/$n.png" 1200x900; done
img "$A/fx/grande.png" 4000x3000
"$FF" -v error -y -f lavfi -i testsrc2=size=1280x720:rate=30 -f lavfi -i sine=f=440 -t 6 -c:v h264_videotoolbox -b:v 6M -c:a aac -shortest "$A/fx/clip.mp4" \
  || "$FF" -v error -y -f lavfi -i testsrc2=size=1280x720:rate=30 -t 6 -c:v mpeg4 -q:v 2 "$A/fx/clip.mp4"
ls -la "$A/fx" | tee -a "$R"
PID=$(uuidgen); MISS=$(uuidgen)
u() { uuidgen; }
cat > "$S/presets.json" <<J
[{"id":"$PID","name":"Prova 1280","kind":"img","actionId":"resize","param":"1280"}]
J
rule() { # cartella kind azione param output outputPath
  printf '{"id":"%s","folder":"%s","kind":"%s","actionId":"%s","param":"%s","output":"%s","outputPath":"%s","enabled":true,"processed":0}' \
    "$(u)" "$1" "$2" "$3" "$4" "$5" "$6"; }
{ echo "["; rule "$P/Foto" img to:jpg "" sub ""; echo ","
  rule "$P/A" img to:png "" fixed "$P/B"; echo ","
  rule "$P/B" img to:jpg "" fixed "$P/A"; echo ","
  rule "$P/Video" video vcompress best sub ""; echo ","
  rule "$P/Preset" img "preset:$PID" "" sub ""; echo ","
  rule "$P/Lenta" img to:jpg "" sub ""; echo ","
  rule "$P/Orfana" img "preset:$MISS" "" sub ""; echo "]"; } > "$S/watch.json"
python3 -I -m json.tool "$S/watch.json" > /dev/null && say "watch.json valido (7 regole)"
rm -f "$S/watch-seen.json"
defaults write it.ledion.OrbitLR lastTab -string "Automazioni"
open_app; shot a00-pagina
say "=== C1 tre PNG in Foto, uno in A (A→B, B→A: giro), un video, uno con azione salvata, uno con azione salvata che non c'è più"
cp "$A/fx/uno.png" "$A/fx/due.png" "$A/fx/tre.png" "$P/Foto/"
cp "$A/fx/uno.png" "$P/A/"
cp "$A/fx/clip.mp4" "$P/Video/"
cp "$A/fx/grande.png" "$P/Preset/"
cp "$A/fx/uno.png" "$P/Orfana/"
# copia lenta: 12 s per un file (come da rete o da iCloud)
( python3 -I - "$A/fx/grande.png" "$P/Lenta/lento.png" <<'PY'
import sys, time
d = open(sys.argv[1], "rb").read(); n = len(d); step = n // 12
with open(sys.argv[2], "wb") as f:
    for i in range(0, n, step): f.write(d[i:i+step]); f.flush(); time.sleep(1)
PY
) &
for i in 1 2 3 4 5 6 7 8 9; do sleep 10; snap "+$((i*10)) s"; done
shot a01-dopo-90s
say "  Foto/Convertiti: $(count "$P/Foto") file in Foto (atteso 3 originali + 3 JPG = 6)"
say "  A: $(count "$P/A") · B: $(count "$P/B") (atteso A=1, B=1: nessun giro)"
say "  Video: $(count "$P/Video") (atteso 2) · Preset: $(count "$P/Preset") (atteso 2) · Lenta: $(count "$P/Lenta") (atteso 2) · Orfana: $(count "$P/Orfana") (1 = non fa niente)"
for f in "$P"/Preset/*/*(N) "$P"/Lenta/*/*(N); do say "  $(sips -g pixelWidth -g pixelHeight "$f" | tail -n 2 | tr -s ' \n' ' ') · ${f#$P/}"; done
say "=== C2 riavvio: niente rielaborato"
quit_app; open_app; sleep 30; snap "dopo il riavvio"
say "=== C3 stesso nome, file nuovo (sovrascritto) in Foto"
cp "$A/fx/due.png" "$P/Foto/uno.png"; touch "$P/Foto/uno.png"; sleep 30; snap "dopo la sovrascrittura"
say "=== C4 «Svuota la cronologia» (history.json vuoto ad app chiusa, come forgetAll) e riapertura: il giro A/B riparte?"
quit_app; cp "$S/history.json" "$A/history-prima.json" 2>/dev/null; echo "[]" > "$S/history.json"
open_app
for i in 1 2 3 4 5 6; do sleep 10; snap "C4 +$((i*10)) s"; done
say "  A: $(count "$P/A") · B: $(count "$P/B") (se crescono: i risultati sono stati rielaborati)"
shot a02-dopo-cronologia
cp "$S/watch.json" "$S/watch-seen.json" "$A/" 2>/dev/null
grep -a -iE "automat|watch|cartell" "$HOME/Library/Logs/LRConverter.log" 2>/dev/null | tail -n 20 | sed -E 's#/Users/[^/ ]+#~#g' > "$A/registro-auto.txt"

say "=== orbitlr://"
defaults write it.ledion.OrbitLR lastTab -string "Conversione"
mkdir -p "$P/Link"; cp "$A/fx/uno.png" "$P/Link/uno.png"; cp "$A/fx/due.png" "$P/Link/nome con spazi 🎬 è.png"
enc() { python3 -I -c 'import sys,urllib.parse;print(urllib.parse.quote(sys.argv[1]))' "$1"; }
O() { local n=$1 l=$2; t 15 open "$l"; local c=$?; sleep 4; shot "o-$n"; say "  $n: open uscita $c · app $(alive) · finestre: $(t 10 osascript -e 'tell application "System Events" to get name of every window of process "OrbitLR"' 2>&1)"; }
O 1-file "orbitlr://open?f=$(enc "$P/Link/uno.png")"
O 2-spazi-emoji "orbitlr://open?f=$(enc "$P/Link/nome con spazi 🎬 è.png")"
O 3-inesistente "orbitlr://open?f=$(enc "$P/Link/non-esiste.png")"
O 4-vuoto "orbitlr://open?f="
O 5-senza-niente "orbitlr://"
O 6-altro-comando "orbitlr://elimina?f=$(enc "$P/Link/uno.png")"
O 7-cartella "orbitlr://open?f=$(enc "$P")"
O 8-stesso-tre-volte "orbitlr://open?f=$(enc "$P/Link/uno.png")&f=$(enc "$P/Link/uno.png")&f=$(enc "$P/Link/uno.png")"
O 9-relativo "orbitlr://open?f=Prova/Link/uno.png"
L="orbitlr://open?"; for i in $(seq 1 400); do L="${L}f=$(enc "$P/Link/uno.png")&"; done
O 10-lunghissimo "$L"
ls -la "$P/Link" | sed 's/^/  Link: /' | tee -a "$R"
t 10 osascript -e 'tell application "System Events" to get entire contents of window 1 of process "OrbitLR"' 2>&1 | tr ',' '\n' | grep -ciE "uno" | sed 's/^/  elementi con «uno» nella finestra: /' | tee -a "$R"
quit_app
