#!/bin/zsh
# M09 · Il Downloader dalla finestra vera (scheda Audio), con il server locale.
# Uso: ui-downloader.sh <cartella-uscita> <cartella-fixture> <porta>
OUT=$1; FX=$2; PORT=$3; H=${0:A:h}
mkdir -p "$OUT/ui"; R="$OUT/ui/risultato.txt"; : > "$R"
say() { echo "$*" | tee -a "$R"; }
t() { perl -e 'alarm shift; exec @ARGV' "$@"; }
ax() { t 60 osascript "$H/ax.applescript" "$@" 2>&1; }
shot() { t 20 screencapture -x "$OUT/ui/$1.png" 2>/dev/null; }
srv_start() { python3 -I "$H/server.py" "$FX" $PORT 2>>"$OUT/ui/server.log" & echo $! > "$OUT/ui/srv.pid"; sleep 1; }
srv_stop() { kill $(cat "$OUT/ui/srv.pid") 2>/dev/null; sleep 1; }
dl() { ls -1 ~/Downloads 2>/dev/null | grep -v '^prova$'; }
# una sequenza: link negli appunti → «Scarica» nella barra (si apre la finestrella con il link) → Invio
start_link() {
  printf '%s' "$1" | pbcopy
  say "  barra: $(ax click Scarica)"; sleep 2
  t 10 osascript -e 'tell application "System Events" to keystroke return'
}
close_sheet() { say "  chiudo: $(ax click Annulla)"; sleep 1; }
# foto ogni 2 s per $2 secondi; si ferma quando compare un file nuovo in Download
watch_shots() { local name=$1 secs=$2 before=$(dl | wc -l) i=0
  while (( i*2 < secs )); do shot "$name-$(printf %02d $i)"; sleep 2; i=$((i+1))
    (( $(dl | wc -l) > before )) && { sleep 3; shot "$name-fine"; say "  file nuovo dopo ~$((i*2)) s"; return 0; }
  done; return 1; }

say "--- accessibilità: $(ax dump | head -c 0; echo prova)"
ax dump > "$OUT/ui/albero-ax.txt"; say "  elementi nell'albero: $(wc -l < "$OUT/ui/albero-ax.txt")"
shot 00-scheda-audio

srv_start
say "=== U1 link valido (file lento, 25 s; la prima volta scarica anche il motore)"
start_link "http://127.0.0.1:$PORT/lento/video.mp4"
watch_shots u1 150 || say "  U1: nessun file dopo 150 s"
dl | sed 's/^/  in Download: /' | tee -a "$R"
ax dump > "$OUT/ui/albero-dopo-u1.txt"

say "=== U2 rete staccata a metà"
start_link "http://127.0.0.1:$PORT/lento/video.mp4"
sleep 9; shot u2-prima-del-taglio; ax dump > "$OUT/ui/albero-u2-durante.txt"
srv_stop; say "  server spento a $(date +%T)"
for i in 1 2 3 4 5 6 7 8; do sleep 3; shot u2-dopo-$i; done
ax dump > "$OUT/ui/albero-u2-errore.txt"
grep -iE "AXStaticText" "$OUT/ui/albero-u2-errore.txt" | grep -viE "Solo contenuti|Funziona con|Audio Downloader" | tail -n 8 | sed 's/^/  testo: /' | tee -a "$R"
close_sheet; srv_start

say "=== U3 pagina senza video"
start_link "http://127.0.0.1:$PORT/muto.html"; sleep 15; shot u3-errore
ax dump > "$OUT/ui/albero-u3.txt"; grep -E "AXStaticText" "$OUT/ui/albero-u3.txt" | grep -viE "Solo contenuti|Funziona con|Audio Downloader" | tail -n 6 | sed 's/^/  testo: /' | tee -a "$R"
close_sheet

say "=== U4 file che non esiste (404)"
start_link "http://127.0.0.1:$PORT/mancante.mp4"; sleep 15; shot u4-errore
ax dump > "$OUT/ui/albero-u4.txt"; grep -E "AXStaticText" "$OUT/ui/albero-u4.txt" | grep -viE "Solo contenuti|Funziona con|Audio Downloader" | tail -n 6 | sed 's/^/  testo: /' | tee -a "$R"
close_sheet

say "=== U5 link non valido (testo qualsiasi, e localhost)"
printf '%s' "ciao questo non è un link" | pbcopy
say "  barra: $(ax click Scarica)"; sleep 2; shot u5-finestrella-vuota
t 10 osascript -e 'tell application "System Events" to keystroke "ciao"'; sleep 1; shot u5-testo
say "  Scarica nella finestrella: $(ax click Scarica)"; sleep 2; shot u5-dopo-clic
close_sheet
printf '%s' "http://localhost:$PORT/video.mp4" | pbcopy
say "  barra (localhost negli appunti): $(ax click Scarica)"; sleep 2; shot u5-localhost
ax dump > "$OUT/ui/albero-u5-localhost.txt"; grep -c "localhost" "$OUT/ui/albero-u5-localhost.txt" | sed 's/^/  righe con localhost nella finestrella: /' | tee -a "$R"
close_sheet

say "=== U6 titolo lunghissimo con emoji"
start_link "http://127.0.0.1:$PORT/lungo.html"
watch_shots u6 60 || say "  U6: nessun file dopo 60 s"
dl | sed 's/^/  in Download: /' | tee -a "$R"
for f in ~/Downloads/*; do [ -f "$f" ] && say "  $(printf %s "${f:t}" | wc -c | tr -d ' ') byte · ${f:t}"; done

say "=== U7 due scaricamenti insieme (si prova ad aprirne un secondo mentre il primo va)"
start_link "http://127.0.0.1:$PORT/lento/video.mp4"; sleep 6
printf '%s' "http://127.0.0.1:$PORT/video.mp4" | pbcopy
say "  secondo clic sulla barra durante il primo: $(ax click Scarica)"; sleep 2; shot u7-secondo
watch_shots u7 60 || true
dl | sed 's/^/  in Download: /' | tee -a "$R"
srv_stop
say "--- registro dell'app (Downloader)"; grep -a "Downloader" ~/Library/Logs/LRConverter.log 2>/dev/null | tail -n 20 | sed -E 's#/Users/[^/ ]+#~#g' | tee -a "$R"
