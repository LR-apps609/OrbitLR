#!/bin/bash
# M08 - sequenze di stress e blocchi per OrbitLR (Mac). Uso: stress.sh <cartella_uscita> [scenari...]
set -u
OUT="$1"; shift
HERE="$(cd "$(dirname "$0")" && pwd)"
APP=/Applications/OrbitLR.app
F="$RUNNER_TEMP/m08"          # file di prova
SUP="$HOME/Library/Application Support/LRConverter"
mkdir -p "$OUT" "$F"
PROBE="python3 $HERE/probe.py"
SCEN="${*:-s01 s02 s03 s04 s05 s06 s07 s08 s09 s10 s11 s12 s13}"

note() { echo "== $*"; echo "$(date +%H:%M:%S) $*" >> "$OUT/diario.txt"; }

shot() {
  local W ID; W=$(swift "$GITHUB_WORKSPACE/Tools/finestra.swift" 2>/dev/null || true); ID=${W%% *}
  if [ -n "$ID" ]; then screencapture -x -o -l"$ID" "$OUT/$1.png" 2>/dev/null; else screencapture -x "$OUT/$1-schermo.png" 2>/dev/null; fi
}

engines() { ps -axo pid,ppid,etime,command | grep -E "LRConverter.zsh|/sips |ffmpeg|qlmanage" | grep -v grep || true; }

quitapp() {
  if pgrep -x OrbitLR >/dev/null; then
    osascript -e 'with timeout of 8 seconds' -e 'tell application id "it.ledion.OrbitLR" to quit' -e 'end timeout' >/dev/null 2>&1 || true
    for i in 1 2 3 4 5 6; do pgrep -x OrbitLR >/dev/null || break; sleep 1; done
    if pgrep -x OrbitLR >/dev/null; then note "uscita: non si chiude con quit, uso kill"; pkill -9 -x OrbitLR; sleep 2; fi
  fi
  pkill -f LRConverter.zsh 2>/dev/null || true
  # un rapporto del guardiano (6.0.3) si conserva, poi si toglie per non mostrare la domanda allo scenario dopo
  for f in "$SUP"/problema.txt "$SUP"/ultimo-problema.txt "$SUP"/in-corso.txt; do
    [ -f "$f" ] && cp "$f" "$OUT/guardiano-$(basename "$f" .txt)-$CUR.txt"
  done
  rm -f "$SUP/problema.txt" "$SUP/in-corso.txt"
  rm -f "$SUP/watch.json" "$SUP/watch-seen.json"
}

launch() {
  open "$APP"
  for i in $(seq 1 30); do pgrep -x OrbitLR >/dev/null && break; sleep 1; done
  sleep 8
}

openfiles() {   # apre dei file come "Apri con" / trascinati sull'icona; misura quanto ci mette `open`
  local t0 t1 rc
  t0=$(python3 -c 'import time;print(time.time())')
  open -a "$APP" "$@" 2>>"$OUT/open-err.txt"; rc=$?
  t1=$(python3 -c 'import time;print(time.time())')
  note "$CUR: open ${#} elementi rc=$rc in $(python3 -c "print(round($t1-$t0,2))") s"
}

watchrule() {   # cartella sorvegliata: regola immagini -> JPG (avvia un lavoro vero senza clic)
  mkdir -p "$SUP"
  cat > "$SUP/watch.json" <<EOF
[{"id":"6F1C2B9E-6B0A-4C35-9E57-3E2A9D1B0A01","folder":"$1","kind":"img","actionId":"to:jpg","param":"","output":"sub","outputPath":"","enabled":true,"processed":0,"exts":["heic","png"]}]
EOF
}

# ---------- file di prova ----------
note "preparo i file"
python3 - "$F" <<'PY'
import sys, zlib, struct, os
d = sys.argv[1]
def png(path, w, h, seed=0):
    raw = bytearray()
    for y in range(h):
        raw.append(0)
        row = bytes(((x * 7 + y * 3 + seed) & 255, (x ^ y) & 255, (y * 5 + seed) & 255) for x in range(w))
        raw += row
    def chunk(t, b): return struct.pack(">I", len(b)) + t + b + struct.pack(">I", zlib.crc32(t + b) & 0xffffffff)
    open(path, "wb").write(b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 2, 0, 0, 0))
                           + chunk(b"IDAT", zlib.compress(bytes(raw), 6)) + chunk(b"IEND", b""))
png(os.path.join(d, "base.png"), 2400, 1600)
png(os.path.join(d, "tiny.png"), 24, 16)
PY
sips -s format jpeg "$F/tiny.png" --out "$F/tiny.jpg" >/dev/null
sips -s format heic "$F/base.png" --out "$F/base.heic" >/dev/null 2>&1 || cp "$F/base.png" "$F/base.heic"
ls -la "$F"

# 5.000 file piccoli in una cartella (con sottocartelle)
mkdir -p "$F/cinquemila"
for s in 0 1 2 3 4; do mkdir -p "$F/cinquemila/sotto$s"; for i in $(seq 1 1000); do cp "$F/tiny.jpg" "$F/cinquemila/sotto$s/f$i.jpg"; done; done
# 300 foto
mkdir -p "$F/trecento"; for i in $(seq 1 300); do cp "$F/base.heic" "$F/trecento/foto$i.heic"; done
note "file pronti: $(find "$F/cinquemila" -type f | wc -l) piccoli, $(ls "$F/trecento" | wc -l) foto"

run_s01() { # cartella di 5.000 file piccoli
  launch; openfiles "$F/cinquemila"; $PROBE s01 25 "$OUT"; shot s01-5000-file; }

run_s02() { # cartella di sistema enorme (come trascinare la cartella Inizio o una libreria)
  launch; openfiles /System/Library/Frameworks; $PROBE s02 35 "$OUT"; shot s02-cartella-enorme; }

run_s03() { # 300 foto aperte insieme
  launch; openfiles "$F"/trecento/*.heic; $PROBE s03 30 "$OUT"; shot s03-300-foto; }

run_s04() { # file da 3 GB (sparso): video e immagine
  mkfile -n 3g "$F/grande.mp4"; mkfile -n 3g "$F/grande.jpg"; ls -la "$F"/grande.*
  launch; openfiles "$F/grande.mp4"; $PROBE s04a 25 "$OUT"; shot s04-3gb-video
  openfiles "$F/grande.jpg"; $PROBE s04b 20 "$OUT"; shot s04-3gb-foto
  rm -f "$F"/grande.*; }

run_s05() { # lavoro vero su 300 foto (cartella sorvegliata), con l'app che aspetta
  rm -rf "$F/sorv"; mkdir -p "$F/sorv"; watchrule "$F/sorv"
  launch; cp "$F"/trecento/*.heic "$F/sorv/"; note "s05: 300 foto nella cartella sorvegliata"
  $PROBE s05 75 "$OUT"; shot s05-lavoro-300
  note "s05: creati $(ls "$F/sorv/Convertiti" 2>/dev/null | wc -l) jpg"; engines >> "$OUT/motori-s05.txt"; }

run_s06() { # file che spariscono a meta' lavoro
  rm -rf "$F/spar"; mkdir -p "$F/spar"; watchrule "$F/spar"
  launch; cp "$F"/trecento/*.heic "$F/spar/"
  for i in $(seq 1 40); do [ -d "$F/spar/Convertiti" ] && [ "$(ls "$F/spar/Convertiti" | wc -l)" -ge 5 ] && break; sleep 1; done
  note "s06: lavoro partito ($(ls "$F/spar/Convertiti" 2>/dev/null | wc -l) fatti), cancello gli originali e la cartella risultati"
  rm -f "$F"/spar/*.heic; rm -rf "$F/spar/Convertiti"
  $PROBE s06 40 "$OUT"; shot s06-file-spariti; engines >> "$OUT/motori-s06.txt"; }

run_s07() { # disco lento/sola lettura (immagine disco)
  rm -f "$F/lento.dmg"
  hdiutil create -size 300m -fs HFS+ -volname M08Lento -srcfolder "$F/trecento" "$F/lento.dmg" >/dev/null 2>&1 || hdiutil create -size 300m -fs HFS+ -volname M08Lento "$F/lento.dmg"
  MNT=$(hdiutil attach -readonly -nobrowse "$F/lento.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1)
  note "s07: montato in sola lettura: $MNT ($(ls "$MNT" | wc -l) file)"
  launch; openfiles "$MNT"; $PROBE s07a 20 "$OUT"; shot s07-dmg-aperto
  # cartella sorvegliata in sola lettura: il risultato non si puo' scrivere li'
  quitapp; watchrule "$MNT"; launch; $PROBE s07b 40 "$OUT"; shot s07-dmg-sorvegliato
  quitapp; hdiutil detach "$MNT" -force >/dev/null 2>&1 || true; }

run_s08() { # file la cui lettura si blocca: FIFO con estensione video/foto; file e cartella senza permessi
  rm -rf "$F/blocchi"; mkdir -p "$F/blocchi/chiusa"; mkfifo "$F/blocchi/tubo.mp4" "$F/blocchi/tubo.jpg"
  cp "$F/base.heic" "$F/blocchi/chiusa/dentro.heic"; cp "$F/base.heic" "$F/blocchi/vietata.heic"
  chmod 000 "$F/blocchi/vietata.heic" "$F/blocchi/chiusa"
  launch; openfiles "$F/blocchi/tubo.mp4"; $PROBE s08a 25 "$OUT"; shot s08-fifo-video
  openfiles "$F/blocchi/tubo.jpg"; $PROBE s08b 20 "$OUT"; shot s08-fifo-foto
  openfiles "$F/blocchi/vietata.heic" "$F/blocchi/chiusa"; $PROBE s08c 15 "$OUT"; shot s08-senza-permessi
  openfiles "$F/blocchi"; $PROBE s08d 15 "$OUT"; shot s08-cartella-con-fifo
  chmod 755 "$F/blocchi/chiusa"; chmod 644 "$F/blocchi/vietata.heic"; }

run_s09() { # percorso di piu' di 1.000 caratteri
  local seg base d; seg=$(printf 'cartella_lunga_%.0s' $(seq 1 12)); base="$F/lungo"; rm -rf "$base"; mkdir -p "$base"
  ( cd "$base" && for i in 1 2 3 4 5 6; do mkdir "$seg$i" && cd "$seg$i" || exit 1; done; cp "$F/base.heic" ./foto.heic; cp "$F/tiny.jpg" ./piccola.jpg )
  d="$base"; for i in 1 2 3 4 5 6; do d="$d/$seg$i"; done
  note "s09: lunghezza percorso $(( ${#d} + 10 )) caratteri"
  launch; openfiles "$d/foto.heic"; $PROBE s09a 15 "$OUT"; shot s09-percorso-lungo-file
  openfiles "$base"; $PROBE s09b 15 "$OUT"; shot s09-percorso-lungo-cartella; }

run_s10() { # «open» due volte di fila, ad app chiusa (e poi aperta)
  open -a "$APP" "$F/trecento/foto1.heic" & open -a "$APP" "$F/trecento/foto2.heic" & wait
  sleep 6; note "s10: processi OrbitLR dopo doppio open ad app chiusa: $(pgrep -x OrbitLR | wc -l)"
  ps -axo pid,etime,command | grep -i "OrbitLR.app" | grep -v grep >> "$OUT/s10-processi.txt"
  $PROBE s10a 15 "$OUT"; shot s10-doppio-open-chiusa
  open -a "$APP" "$F/trecento/foto3.heic" & open -a "$APP" "$F/trecento/foto4.heic" & wait
  $PROBE s10b 12 "$OUT"; note "s10: processi dopo doppio open ad app aperta: $(pgrep -x OrbitLR | wc -l)"; shot s10-doppio-open-aperta; }

run_s11() { # uscire durante un lavoro
  rm -rf "$F/esci"; mkdir -p "$F/esci"; watchrule "$F/esci"
  launch; cp "$F"/trecento/*.heic "$F/esci/"
  for i in $(seq 1 40); do [ -d "$F/esci/Convertiti" ] && [ "$(ls "$F/esci/Convertiti" | wc -l)" -ge 3 ] && break; sleep 1; done
  note "s11: lavoro in corso ($(ls "$F/esci/Convertiti" 2>/dev/null | wc -l) fatti): chiedo di uscire"
  osascript -e 'with timeout of 6 seconds' -e 'tell application id "it.ledion.OrbitLR" to quit' -e 'end timeout' > "$OUT/s11-quit.txt" 2>&1; echo "rc=$?" >> "$OUT/s11-quit.txt"
  sleep 2; shot s11-domanda-uscita; $PROBE s11a 10 "$OUT"
  note "s11: dopo quit: processi $(pgrep -x OrbitLR | wc -l); fatti $(ls "$F/esci/Convertiti" 2>/dev/null | wc -l)"
  pkill -TERM -x OrbitLR; sleep 4
  note "s11: dopo SIGTERM: processi $(pgrep -x OrbitLR | wc -l)"; engines >> "$OUT/motori-s11.txt"
  N1=$(ls "$F/esci/Convertiti" 2>/dev/null | wc -l); sleep 10; N2=$(ls "$F/esci/Convertiti" 2>/dev/null | wc -l)
  note "s11: file creati dopo la chiusura: $N1 -> $N2 (se cresce, un motore lavora ancora senza app)"
  ls -la "$F/esci/Convertiti" 2>/dev/null | tail -5 >> "$OUT/motori-s11.txt"
  launch; $PROBE s11b 10 "$OUT"; shot s11-riapertura; }

run_s12() { # cartella sorvegliata con 5.000 file (scansione ogni 3 s) + apertura di 300 foto insieme
  rm -rf "$F/sorv5k"; cp -R "$F/cinquemila/sotto0" "$F/sorv5k"; for s in 1 2 3 4; do for f in "$F"/cinquemila/sotto$s/*.jpg; do cp "$f" "$F/sorv5k/s${s}_$(basename "$f")"; done; done
  watchrule "$F/sorv5k"; launch; openfiles "$F"/trecento/*.heic; $PROBE s12 40 "$OUT"; shot s12-sorveglia-5000; }

run_s13() { # progetto video aperto le cui clip stanno su un'immagine disco poi scollegata (pista C01)
  local PID_ UUID_ MNT
  rm -f "$F/clip.dmg"; mkdir -p "$F/clipsrc"; for i in $(seq 1 20); do head -c 200000 /dev/urandom > "$F/clipsrc/clip$i.mp4"; done
  hdiutil create -size 50m -fs HFS+ -volname M08Clip -srcfolder "$F/clipsrc" "$F/clip.dmg" >/dev/null
  MNT=$(hdiutil attach -nobrowse "$F/clip.dmg" | awk -F'\t' '/\/Volumes\//{print $NF}' | tail -1); note "s13: clip in $MNT"
  UUID_=$(uuidgen); mkdir -p "$SUP/Progetti video"
  swift "$HERE/segnalibri.swift" "$SUP/Progetti video/$UUID_.json" "$MNT"/clip*.mp4 | tee -a "$OUT/diario.txt"
  defaults write it.ledion.OrbitLR video.openProject -string "$UUID_"; defaults write it.ledion.OrbitLR video.cleanExit -bool true
  hdiutil detach "$MNT" >/dev/null; note "s13a: disco scollegato, immagine ancora presente"
  launch; $PROBE s13a 25 "$OUT"; shot s13a-progetto-disco-scollegato
  note "s13a: immagine rimontata dall'app? $(mount | grep -c M08Clip)"; mount | grep M08Clip >> "$OUT/diario.txt"
  quitapp; for m in $(mount | awk '/M08Clip/{print $3}'); do hdiutil detach "$m" -force >/dev/null; done
  defaults write it.ledion.OrbitLR video.openProject -string "$UUID_"; rm -f "$F/clip.dmg"
  note "s13b: anche l'immagine disco cancellata"
  launch; $PROBE s13b 20 "$OUT"; shot s13b-progetto-disco-sparito
  defaults delete it.ledion.OrbitLR video.openProject 2>/dev/null; rm -rf "$SUP/Progetti video"; }

for s in $SCEN; do
  CUR=$s; note "---- inizio $s"
  quitapp
  "run_$s"
  quitapp
  note "---- fine $s (crash: $(ls ~/Library/Logs/DiagnosticReports 2>/dev/null | grep -ci orbit))"
done
cat "$OUT/riassunto.tsv" 2>/dev/null
