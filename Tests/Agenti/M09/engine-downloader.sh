#!/bin/zsh
# M09 · Il motore del Downloader con gli argomenti esatti dell'app, il ffmpeg dentro OrbitLR e il server locale.
# Uso: engine-downloader.sh <cartella-uscita> <cartella-fixture> <porta> <OrbitLR.app>
OUT=$1; FX=$2; PORT=$3; APP=$4; H=${0:A:h}
E="$OUT/motore"; mkdir -p "$E"; R="$E/risultato.txt"; : > "$R"
say() { echo "$*" | tee -a "$R"; }
MOT="$APP/Contents/Resources/Motori"
say "Motori nell'app: $(ls "$MOT" 2>&1 | tr '\n' ' ')"
# il motore come lo prende l'app: elenco delle impronte + file, impronta controllata
B=https://github.com/yt-dlp/yt-dlp/releases/latest/download
curl -fsSL -o "$E/SUMS" $B/SHA2-256SUMS && curl -fsSL -o "$E/yt-dlp" $B/yt-dlp_macos && chmod +x "$E/yt-dlp"
WANT=$(awk '$2=="yt-dlp_macos"{print $1}' "$E/SUMS"); GOT=$(shasum -a 256 "$E/yt-dlp" | cut -d' ' -f1)
say "impronta: $([ "$WANT" = "$GOT" ] && echo uguale || echo DIVERSA) · versione $("$E/yt-dlp" --version 2>&1)"
python3 -I "$H/server.py" "$FX" $PORT 2> "$E/server.log" & SP=$!; sleep 1
W="$E/w"; mkdir -p "$W"
run() { local name=$1 mode=$2 link=$3; local s=$(date +%s)
  zsh "$H/dl.sh" "$E/yt-dlp" "$MOT" $mode "$link" "$W/$name"
  say "--- $name ($mode) uscita $(cat "$W/$name.code") in $(( $(date +%s)-s )) s"
  for f in "$W/$name"/*(N); do say "  file: ${f:t} · $(stat -f %z "$f") byte · $(printf %s "${f:t}" | wc -c | tr -d ' ') byte di nome"
    "$MOT/ffprobe" -v error -show_entries format=duration:stream=codec_name -of compact "$f" 2>&1 | head -n 4 | sed 's/^/    /' | tee -a "$R"; done
  tail -n 4 "$W/$name.err" | sed -E 's#/Users/[^/ ]+#~#g; s/^/  stderr: /' | tee -a "$R"
  python3 -I "$H/friendly.py" "$W/$name.err" | sed 's/^/  /' | tee -a "$R"; }
run valido-video video "http://127.0.0.1:$PORT/video.mp4"
run valido-audio audio "http://127.0.0.1:$PORT/video.mp4"
run valido-best videoBest "http://127.0.0.1:$PORT/video.mp4"
run senza-video video "http://127.0.0.1:$PORT/muto.html"
run mancante video "http://127.0.0.1:$PORT/mancante.mp4"
run porta-chiusa video "http://127.0.0.1:9/video.mp4"
run nome-inesistente video "http://nessuno.invalid/video.mp4"
run titolo-lungo video "http://127.0.0.1:$PORT/lungo.html"
run titolo-lungo-audio audio "http://127.0.0.1:$PORT/lungo.html"
# rete staccata a metà
( zsh "$H/dl.sh" "$E/yt-dlp" "$MOT" video "http://127.0.0.1:$PORT/lento/video.mp4" "$W/taglio" ) & DP=$!
sleep 8; kill $SP; T0=$(date +%s); wait $DP
say "--- taglio: il motore si ferma $(( $(date +%s)-T0 )) s dopo lo spegnimento del server, uscita $(cat "$W/taglio.code")"
grep -a "%" "$W/taglio.out" | tail -n 1 | sed 's/^/  ultimo avanzamento: /' | tee -a "$R"
tail -n 2 "$W/taglio.err" | sed 's/^/  stderr: /' | tee -a "$R"
python3 -I "$H/friendly.py" "$W/taglio.err" | sed 's/^/  /' | tee -a "$R"
ls -la "$W/taglio" | tail -n +2 | sed 's/^/  resta: /' | tee -a "$R"
# due insieme, stesso link
python3 -I "$H/server.py" "$FX" $PORT 2>> "$E/server.log" & SP=$!; sleep 1
s=$(date +%s)
zsh "$H/dl.sh" "$E/yt-dlp" "$MOT" video "http://127.0.0.1:$PORT/lento/video.mp4" "$W/par1" &
zsh "$H/dl.sh" "$E/yt-dlp" "$MOT" video "http://127.0.0.1:$PORT/lento/video.mp4" "$W/par2" &
wait %2 %3 2>/dev/null; wait
say "--- due insieme: uscite $(cat "$W/par1.code") e $(cat "$W/par2.code") in $(( $(date +%s)-s )) s; file: $(ls "$W/par1" "$W/par2" | tr '\n' ' ')"
cmp "$W/par1/video.mp4" "$FX/video.mp4" && cmp "$W/par2/video.mp4" "$FX/video.mp4" && say "  tutti e due identici all'originale"
kill $SP 2>/dev/null
# un video vero con licenza libera da Wikimedia Commons (piccolo), se raggiungibile
Q='https://commons.wikimedia.org/w/api.php?action=query&format=json&generator=search&gsrnamespace=6&gsrsearch=filetype:video%20filesize:<3000%20incategory:CC-BY-SA-4.0&gsrlimit=5&prop=imageinfo&iiprop=url|size'
CC=$(curl -fsSL -A "OrbitLR-test/1.0" "$Q" | python3 -I -c 'import json,sys
d=json.load(sys.stdin)["query"]["pages"]
v=sorted(d.values(), key=lambda p:p["imageinfo"][0]["size"])
print(v[0]["imageinfo"][0]["descriptionurl"]+" "+v[0]["imageinfo"][0]["url"])' 2>/dev/null)
say "--- Commons: ${CC:-non raggiungibile}"
if [ -n "$CC" ]; then run commons-pagina video "${CC%% *}"; run commons-diretto video "${CC##* }"; fi
