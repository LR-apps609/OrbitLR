#!/bin/zsh
# M07 · Giro corto del motore classico (LRConverter.zsh dentro l'app): un'azione per categoria,
# come la chiama l'app (--run AZIONE PARAMETRO file…, con i motori dell'app e nient'altro).
# Uso: motore.sh CARTELLA_USCITA CARTELLA_FIXTURE
emulate zsh
setopt NO_NOMATCH
OUT=$1; FX=$2
APPDIR=/Applications/OrbitLR.app
S="$APPDIR/Contents/Resources/LRConverter.zsh"
M="$APPDIR/Contents/Resources/Motori"
ESITI="$OUT/esiti.tsv"
W="$HOME/Desktop/M07-motore"; rm -rf "$W"; mkdir -p "$W"
esito() { print -r -- "$1"$'\t'"$2"$'\t'"$3" >> "$ESITI"; print -r -- "$1: $2 — $3"; }

# Ogni prova: nome, azione, parametro, file d'ingresso, controllo sul file creato (comando con {} = file)
prova() {  # nome azione parametro ingresso
  local n=$1 a=$2 p=$3 f=$4
  local d="$W/$n"; mkdir -p "$d"; cp "$FX/$f" "$d/"
  local t0=$(date +%s)
  LR_MOTORI="$M" LR_LANG=it LR_SUBDIR=Convertiti perl -e 'alarm shift; exec @ARGV' 240 \
    /bin/zsh "$S" --run "$a" "$p" "$d/$f" > "$OUT/motore/$n.out" 2>&1
  local rc=$? t=$(( $(date +%s) - t0 ))
  local made=$(find "$d" -type f ! -name "$f" | head -n 1)
  local riga=$(grep -E "^(OK|FAIL)"$'\t' "$OUT/motore/$n.out" | head -n 1 | tr '\t' ' ')
  local fine=$(grep -E "^END"$'\t' "$OUT/motore/$n.out" | tail -n 1 | tr '\t' ' ')
  local info=""
  if [[ -n $made ]]; then
    info="$(stat -f %z "$made") byte, $(file -b "$made" | cut -c1-70)"
    case $made in
      *.mp4|*.mp3|*.m4a|*.wav|*.mov|*.webm|*.gif) info+=", $("$M/ffprobe" -v error -show_entries format=duration:stream=codec_name,width,height -of compact=p=0:nk=1 "$made" 2>&1 | tr '\n' ' ' | cut -c1-90)" ;;
      *.png|*.jpg|*.webp|*.heic|*.tiff) info+=", $(sips -g pixelWidth -g pixelHeight "$made" 2>/dev/null | awk '/pixel/ {printf "%s ", $2}')" ;;
    esac
    print -r -- "$made" >> "$OUT/motore/creati.txt"
  fi
  if (( rc == 142 )); then esito "motore-$n" FALLITO "$a: bloccato oltre 240 s"
  elif [[ $riga == OK* && -n $made ]]; then esito "motore-$n" OK "$a in ${t}s → ${made:t} ($info)"
  elif [[ $riga == FAIL* ]]; then esito "motore-$n" ERRORE-SPIEGATO "$a (rc $rc, ${t}s): ${riga#FAIL } | $fine"
  else esito "motore-$n" FALLITO "$a (rc $rc, ${t}s): nessuna riga OK/FAIL; file: ${made:-nessuno}; $(tail -n 3 "$OUT/motore/$n.out" | tr '\n' ' ')"
  fi
}

# Controllo automatico del motore (lo stesso che si lancia dal Terminale)
LR_MOTORI="$M" perl -e 'alarm shift; exec @ARGV' 300 /bin/zsh "$S" --test > "$OUT/motore/selftest.out" 2>&1
esito motore-selftest $([[ $? == 0 ]] && print OK || print FALLITO) "$(grep -ciE 'errore|fail|✗' "$OUT/motore/selftest.out") righe con errore; ultime: $(tail -n 2 "$OUT/motore/selftest.out" | tr '\n' ' ' | cut -c1-160)"

prova img-webp     to:webp   ""      foto.png
prova img-resize   resize    web     grande.jpg
prova img-strip    strip     ""      grande.jpg
prova video-mp4    to:mp4    ""      clip.mkv
prova video-comp   vcompress 1       clip.mp4
prova video-gif    gifcut    "0|2"   clip.mp4
prova audio-mp3    to:mp3    ""      suono.wav
prova audio-norm   normalize ""      suono.wav
prova pdf-unisci   merge     ""      doc.pdf
prova pdf-comp     pdfcompress medium doc.pdf
prova pdf-testo    pdftext   ""      doc.pdf
prova doc-docx     to:docx   ""      testo.rtf
prova doc-txt      to:txt    ""      testo.rtf
prova testo-html   to:html   ""      note.md
prova foglio-pdf   to:pdf    ""      tabella.csv
cp ~/Library/Logs/LRConverter.log "$OUT/motore/LRConverter.log" 2>/dev/null
exit 0
