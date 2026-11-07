#!/bin/zsh
# M04 · Trascrizione del motore: senza Whisper, senza modello (offline), poi con il modello vero.
# uso: trascrivi.zsh <script del motore> <cartella file di prova> <cartella risultati>
emulate zsh; setopt NO_NOMATCH
S=$1; FX=$2; R=$3; mkdir -p "$R"
zmodload zsh/datetime
M="$HOME/Library/Application Support/LRConverter/models"
P="$HOME/Library/Application Support/LRConverter/prefs"
t() {  # etichetta, secondi max, file, [env…]
  local lab=$1 max=$2 f=$3; shift 3
  local od="$R/tr-$lab"; mkdir -p "$od"
  local t0=$EPOCHREALTIME
  env LR_DESTPATH="$od" "$@" perl -e 'alarm shift; exec @ARGV' $max /bin/zsh "$S" --run transcribe "" "$f" > "$od.txt" 2>&1
  local rc=$?
  print -r -- "== $lab (${f:t}) rc=$rc $(printf '%.1f' $(( EPOCHREALTIME - t0 )))s"
  grep -v '^P	' "$od.txt" | tr '\t' '|'
  for o in "$od"/*(N); do print -r -- "  -> ${o:t} ($(stat -f %z "$o") byte)"; [[ $o == *.txt ]] && sed 's/^/     /' "$o"; done
}
print "whisper-cli: $(command -v whisper-cli) whisper-cpp: $(command -v whisper-cpp)"
if [[ $4 == senza ]]; then t senza-whisper 120 "$FX/voce_it.wav"; exit 0; fi
mkdir -p "$M"
rm -f "$M"/ggml-*.bin*
# Modello mancante e niente rete: deve dire chiaramente cosa succede, senza restare fermo
t offline 300 "$FX/voce_it.wav" HTTPS_PROXY=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9
ls -la "$M"
# Modello vero (si scarica da solo, come fa l'app)
t scarica 900 "$FX/voce_it.wav"
ls -la "$M"
t en 300 "$FX/voce_en.wav"
t pause 300 "$FX/pause.wav"
t muto 300 "$FX/tutto_muto.wav"
t accenti 300 "$FX/Caffè città — è già.wav"
# Lingua fissata nelle impostazioni
print "wlang=it" >> "$P"; t lingua-it 300 "$FX/voce_it.wav"
sed -i '' 's/^wlang=.*/wlang=en/' "$P"; t lingua-en 300 "$FX/voce_en.wav"
sed -i '' '/^wlang=/d' "$P"
# Modello troncato (download interrotto a metà, poi rinominato a mano)
mv "$M/ggml-small.bin" "$M/ggml-small.full"; head -c 1000000 "$M/ggml-small.full" > "$M/ggml-small.bin"
t modello-rotto 300 "$FX/voce_it.wav"
mv -f "$M/ggml-small.full" "$M/ggml-small.bin"
