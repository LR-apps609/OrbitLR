#!/bin/zsh
# M06 · Mac Intel senza finestra: motori inclusi, --test, giro di azioni, avvio dell'app, tempi.
# Uso: zsh prova.zsh <cartella-risultati> <percorso-OrbitLR.app>
emulate zsh
setopt NO_NOMATCH
zmodload zsh/datetime
R=${1:?cartella risultati}; SRC_APP=${2:?app}
mkdir -p "$R"
SUM="$R/riassunto.tsv"; : > "$SUM"
APP=/Applications/OrbitLR.app
M="$APP/Contents/Resources/Motori"
ENG="$APP/Contents/Resources/LRConverter.zsh"
FX="$R/fixture"; mkdir -p "$FX"
HIDE="/private/tmp/m06-nascosti"; sudo mkdir -p "$HIDE"

# Tempo massimo per un comando (gruppo di processi): 124 = scaduto
to() {
  perl -e 'my $t=shift; my $pid=fork(); if($pid==0){setpgrp(0,0); exec @ARGV; exit 127}
    $SIG{ALRM}=sub{kill "TERM",-$pid; sleep 3; kill "KILL",-$pid; exit 124}; alarm $t; waitpid($pid,0);
    my $s=$?; exit(($s & 127) ? 128+($s & 127) : ($s >> 8))' "$@"
}
now() { print -r -- $EPOCHREALTIME }
secs() { printf '%.2f' $(( EPOCHREALTIME - $1 )) }
rec() { print -r -- "${(j:\t:)@}" >> "$SUM"; print -r -- "== ${(j: | :)@}" }

phase() { print ""; print "######## $1  ($(date '+%T'))"; }

# ── 0. Il Mac ──────────────────────────────────────────────────────────
phase "Mac"
{ sw_vers; uname -m; sysctl -n machdep.cpu.brand_string; sysctl -n hw.ncpu hw.memsize
  system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Chipset|Metal|VRAM|Resolution" ; } | tee "$R/mac.txt"
rec mac "$(sw_vers -productVersion)" "$(uname -m)" "$(system_profiler SPDisplaysDataType 2>/dev/null | grep -m1 Metal | xargs)"

# ── 1. Installo ────────────────────────────────────────────────────────
phase "Installo"
t=$(now)
sudo rm -rf "$APP"; ditto "$SRC_APP" "$APP"; xattr -dr com.apple.quarantine "$APP" 2>/dev/null
rec installa "$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)" "$(secs $t)s"

# ── 2. Motori: architetture, librerie, versione minima ─────────────────
phase "Motori (statico)"
for b in "$APP/Contents/MacOS/OrbitLR" "$M"/*(N*) "$APP/Contents/PlugIns/"*.appex/Contents/MacOS/*(N*); do
  print -r -- "--- ${b:t}"
  file "$b"; lipo -info "$b"
  for a in $(lipo -archs "$b"); do
    print -r -- "[$a] minos: $(vtool -arch $a -show-build "$b" 2>/dev/null | awk '/minos/{print $2}' | head -1)"
    otool -arch $a -L "$b" | tail -n +2 | grep -v -E '^\s*/(System|usr/lib)/' | sed "s/^/[$a] FUORI DAL SISTEMA: /"
  done
done 2>&1 | tee "$R/motori-statico.txt"
for b in ffmpeg ffprobe orbit-vector; do
  ext=$(otool -arch x86_64 -L "$M/$b" 2>/dev/null | tail -n +2 | grep -v -E '^\s*/(System|usr/lib)/' | awk '{print $1}' | xargs)
  rec "motore-statico" "$b" "$(lipo -archs "$M/$b")" "librerie-esterne-x86_64: ${ext:-nessuna}"
done
ls -la /usr/local/opt/xz /usr/local/opt/libx11 2>&1 | head -4 | tee -a "$R/motori-statico.txt"

# Motori in esecuzione (Mac di GitHub, Homebrew presente)
phase "Motori con Homebrew presente"
for c in "ffmpeg -hide_banner -version" "ffprobe -hide_banner -version"; do
  t=$(now); out=$(to 60 "$M/${c%% *}" ${=c#* } 2>&1); rc=$?
  rec "motore-con-brew" "${c%% *}" "rc=$rc" "$(secs $t)s" "$(print -r -- $out | head -1)"
done
"$M/ffmpeg" -hide_banner -encoders 2>/dev/null | grep -E "videotoolbox|libx26|mp3|opus|vpx|webp" > "$R/codificatori.txt"

# ── 3. File di prova (con l'ffmpeg che funziona ora) ───────────────────
phase "File di prova"
FF="$M/ffmpeg"; "$FF" -hide_banner -version >/dev/null 2>&1 || FF=$(command -v ffmpeg)
PROBE="$M/ffprobe"; "$PROBE" -hide_banner -version >/dev/null 2>&1 || PROBE=$(command -v ffprobe)
print "ffmpeg per i file di prova: $FF"
{
  "$FF" -nostdin -loglevel error -y -f lavfi -i "testsrc2=size=1600x1200" -frames:v 1 "$FX/foto.png"
  sips -s format jpeg "$FX/foto.png" --out "$FX/foto.jpg"
  sips -s format heic "$FX/foto.png" --out "$FX/foto.heic"
  print -r -- '<svg xmlns="http://www.w3.org/2000/svg" width="200" height="120"><rect width="200" height="120" fill="#2a5"/><circle cx="60" cy="60" r="40" fill="#fc0"/></svg>' > "$FX/disegno.svg"
  for i in {1..40}; do print "Riga di prova numero $i con lettere accentate àèéìòù."; done > "$FX/testo.txt"
  cupsfilter "$FX/testo.txt" > "$FX/doc.pdf"
  for i in {1..160}; do print "Pagina lunga, riga $i."; done > "$FX/lungo.txt"
  cupsfilter "$FX/lungo.txt" > "$FX/tre-pagine.pdf"
  "$FF" -nostdin -loglevel error -y -f lavfi -i "sine=frequency=440:duration=8" "$FX/suono.wav"
  "$FF" -nostdin -loglevel error -y -i "$FX/suono.wav" -c:a libmp3lame -q:a 4 "$FX/suono.mp3"
  "$FF" -nostdin -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30:duration=6" -f lavfi -i "sine=frequency=660:duration=6" \
       -c:v h264_videotoolbox -allow_sw 1 -b:v 3M -pix_fmt yuv420p -c:a aac -shortest "$FX/video.mp4"
  "$FF" -nostdin -loglevel error -y -i "$FX/video.mp4" -c copy "$FX/video.mov"
} > "$R/fixture.log" 2>&1
ls -la "$FX" | tee -a "$R/fixture.log"

# ── 4. Mac «pulito» come quello di un utente: niente Homebrew ──────────
nascondi() {
  for p in /usr/local/opt /usr/local/Cellar /opt/homebrew; do
    [[ -e $p ]] && sudo mv "$p" "$HIDE/${p//\//_}"
  done
  for x in ffmpeg ffprobe magick convert gs exiftool pandoc soffice whisper-cli rsvg-convert yt-dlp; do
    [[ -e /usr/local/bin/$x || -L /usr/local/bin/$x ]] && sudo mv "/usr/local/bin/$x" "$HIDE/bin_$x"
  done
  print "nascosti: $(ls $HIDE | xargs)"
}
rimetti() {
  for f in "$HIDE"/*(N); do
    n=${f:t}
    if [[ $n == bin_* ]]; then sudo mv "$f" "/usr/local/bin/${n#bin_}"; else sudo mv "$f" "${n//_//}"; fi
  done
  print "rimessi"
}
phase "Mac pulito (Homebrew nascosto)"
nascondi | tee "$R/nascosti.txt"
for c in "ffmpeg -hide_banner -version" "ffprobe -hide_banner -version" "orbit-vector --help"; do
  t=$(now); out=$(to 60 "$M/${c%% *}" ${=c#* } 2>&1); rc=$?
  print -r -- "$out" > "$R/motore-pulito-${c%% *}.txt"
  rec "motore-pulito" "${c%% *}" "rc=$rc" "$(secs $t)s" "$(print -r -- $out | grep -m1 -E 'Library not loaded|version|Usage|uso|orbit' )"
done
t=$(now); to 60 "$M/orbit-vector" "$FX/foto.png" "$R/vettore.svg" > "$R/vettore.log" 2>&1; rc=$?
rec "motore-pulito" "orbit-vector png->svg" "rc=$rc" "$(secs $t)s" "$(wc -c < "$R/vettore.svg" 2>/dev/null) byte"

# ── 5. Controllo automatico dell'app (--test) su Mac pulito ────────────
phase "--test (Mac pulito)"
rm -rf ~/Library/Application\ Support/LRConverter ~/Library/Caches/LRConverter ~/Library/Logs/LRConverter.log
t=$(now); to 900 /bin/zsh "$ENG" --test > "$R/test-pulito.txt" 2>&1; rc=$?
cat "$R/test-pulito.txt"
rec "--test pulito" "rc=$rc" "$(secs $t)s" "$(grep -a 'Totale' "$R/test-pulito.txt")"
grep -a "❌" "$R/test-pulito.txt" | while read -r l; do rec "--test pulito ❌" "$l"; done
cp ~/Library/Logs/LRConverter.log "$R/LRConverter-test-pulito.log" 2>/dev/null

# ── 6. Giro di azioni con --run (come le chiama l'app) ─────────────────
# corri NOME AZIONE PARAMETRO file…  → riga in riassunto, uscite in $R/giro-<fase>/<NOME>
corri() {
  local nome=$1 act=$2 par=$3; shift 3
  local d="$R/giro-$FASE/$nome"; mkdir -p "$d"
  local -a fs=(); local f
  for f in "$@"; do cp "$FX/$f" "$d/"; fs+=("$d/$f"); done
  local t=$(now)
  LR_LANG=it LR_SUBDIR=Convertiti LR_MOTORI="$M" to 300 /bin/zsh "$ENG" --run "$act" "$par" $fs > "$d/uscita.txt" 2>&1
  local rc=$? s=$(secs $t)
  local outs=$(awk -F'\t' '$1=="OUT"{print $2}' "$d/uscita.txt")
  local fails=$(awk -F'\t' '$1=="FAIL"{print $3}' "$d/uscita.txt" | head -2 | xargs)
  local end=$(awk -F'\t' '$1=="END"{print $2"/"$3}' "$d/uscita.txt")
  local info="" o
  for o in ${(f)outs}; do
    [[ -f $o ]] || { info+=" [manca ${o:t}]"; continue }
    info+=" ${o:t}=$(wc -c < "$o" | xargs)B"
  done
  local esito=OK
  (( rc == 124 )) && esito=SCADUTO
  [[ -n $fails || -z $outs ]] && [[ $esito == OK ]] && esito=FALLITO
  rec "giro-$FASE" "$nome" "$esito" "rc=$rc" "${s}s" "END=$end" "${fails:-}" "$info"
  [[ $esito != OK ]] && { print "   uscita di $nome:"; sed 's/^/     | /' "$d/uscita.txt" | cut -c1-260 | head -12 }
  print -r -- "$outs" > "$d/uscite.lst"
}
giro_av() {
  corri "audio-wav-mp3"   to:mp3     ""        suono.wav
  corri "audio-mp3-m4a"   to:m4a     ""        suono.mp3
  corri "audio-normalizza" normalize ""        suono.mp3
  corri "audio-velocita"  speed      1.5       suono.mp3
  corri "audio-taglia"    cut        "1.000|3.000" suono.wav
  corri "video-mov-mp4"   to:mp4     ""        video.mov
  corri "video-comprimi"  vcompress  1         video.mp4
  corri "video-720p"      vresize    720       video.mp4
  corri "video-hevc"      vresize    hevc      video.mp4
  corri "video-gif"       to:gif     ""        video.mp4
  corri "video-solo-audio" to:mp3    ""        video.mp4
  corri "video-taglia"    cut        "1.000|4.000" video.mp4
}
giro_img_pdf() {
  corri "img-png-jpg"     to:jpg     ""        foto.png
  corri "img-png-webp"    to:webp    ""        foto.png
  corri "img-heic-jpg"    to:jpg     ""        foto.heic
  corri "img-resize"      resize     1280      foto.jpg
  corri "img-metadati"    strip      ""        foto.jpg
  corri "img-svg-png"     to:png     ""        disegno.svg
  corri "pdf-png"         to:png     ""        doc.pdf
  corri "pdf-comprimi"    pdfcompress medium   doc.pdf
  corri "pdf-unisci"      merge      ""        doc.pdf tre-pagine.pdf foto.jpg
  corri "pdf-dividi"      split      ""        tre-pagine.pdf
  corri "pdf-testo"       pdftext    ""        doc.pdf
}
phase "Giro di azioni (Mac pulito)"
FASE=pulito; giro_av; giro_img_pdf
cp ~/Library/Logs/LRConverter.log "$R/LRConverter-giro-pulito.log" 2>/dev/null

# ── 7. Avvio dell'app (Mac pulito): parte? si blocca? si chiude? ───────
avvio() {  # nome, modo (diretto|open)
  local nome=$1 modo=$2 d="$R/avvio-$1"; mkdir -p "$d"
  pkill -9 -x OrbitLR 2>/dev/null; sleep 1
  local t=$(now) pid
  if [[ $modo == diretto ]]; then
    "$APP/Contents/MacOS/OrbitLR" > "$d/stdout.txt" 2>&1 &
    pid=$!
  else
    open "$APP"; sleep 2; pid=$(pgrep -x OrbitLR | head -1)
  fi
  local i alive=0
  for i in {1..12}; do
    sleep 5
    if [[ -n $pid ]] && kill -0 $pid 2>/dev/null; then alive=1
      print -r -- "$(( i * 5 ))s $(ps -o %cpu=,rss=,stat= -p $pid)" >> "$d/ps.txt"
    else alive=0; print "$(( i * 5 ))s uscita" >> "$d/ps.txt"; break; fi
  done
  local rc="vivo"
  if (( ! alive )); then wait $pid 2>/dev/null; rc="uscito rc=$?"; fi
  rec "avvio-$nome" "$modo" "$rc" "dopo $(secs $t)s" "$(tail -1 "$d/ps.txt")" "$(grep -m1 -v '^\s*$' "$d/stdout.txt" 2>/dev/null | cut -c1-160)"
  swift "$GITHUB_WORKSPACE/Tools/finestra.swift" > "$d/finestra.txt" 2>&1 || true
  screencapture -x "$d/schermo.png" 2>/dev/null || true
  if (( alive )); then
    sample $pid 3 -file "$d/sample.txt" >/dev/null 2>&1
    # Il filo principale: dove sta?
    awk '/com.apple.main-thread/{f=1} f{print} /^ *$/{if(f)exit}' "$d/sample.txt" | head -40 > "$d/filo-principale.txt"
    print "   filo principale ($nome):"; sed 's/^/     | /' "$d/filo-principale.txt" | cut -c1-200 | head -30
    print "   cima delle pile ($nome):"; sed -n '/Sort by top of stack/,/^ *$/p' "$d/sample.txt" | head -14 | sed 's/^/     | /'
    print "   stdout ($nome):"; sed 's/^/     | /' "$d/stdout.txt" 2>/dev/null | cut -c1-200 | head -20
    print "   finestra: $(cat "$d/finestra.txt" 2>/dev/null)"
    # Chiusura gentile: «Esci»
    t=$(now)
    to 20 osascript -e 'tell application id "it.ledion.OrbitLR" to quit' > "$d/quit.txt" 2>&1; local qrc=$?
    for i in {1..20}; do kill -0 $pid 2>/dev/null || break; sleep 1; done
    if kill -0 $pid 2>/dev/null; then
      rec "chiusura-$nome" "NON SI CHIUDE con Esci" "osascript rc=$qrc" "$(secs $t)s"
      sample $pid 3 -file "$d/sample-dopo-esci.txt" >/dev/null 2>&1
      print "   osascript: $(cat "$d/quit.txt")"
      print "   filo principale dopo Esci:"
      awk '/com.apple.main-thread/{f=1} f{print} /^ *$/{if(f)exit}' "$d/sample-dopo-esci.txt" | cut -c1-200 | head -45 | sed 's/^/     | /'
      sed -n '/Sort by top of stack/,/^ *$/p' "$d/sample-dopo-esci.txt" | head -14 | sed 's/^/     top| /'
      log show --last 1m --style compact --predicate 'process == "tccd" OR process == "OrbitLR"' 2>/dev/null | grep -i -E "osascript|AppleEvent|quit|terminat|deny|prompt" | tail -15 | cut -c1-220 | sed 's/^/     tcc| /'
      kill -TERM $pid; for i in {1..10}; do kill -0 $pid 2>/dev/null || break; sleep 1; done
      if kill -0 $pid 2>/dev/null; then rec "chiusura-$nome" "NON SI CHIUDE neanche con TERM"; kill -9 $pid; else rec "chiusura-$nome" "chiusa con TERM"; fi
    else
      rec "chiusura-$nome" "chiusa con Esci" "osascript rc=$qrc" "$(secs $t)s"
    fi
  fi
}
phase "Avvio dell'app (Mac pulito)"
open -a TextEdit; sleep 5; t=$(now)
to 20 osascript -e 'tell application id "com.apple.TextEdit" to quit' > "$R/quit-textedit.txt" 2>&1; rc=$?
sleep 2; rec "controllo-esci TextEdit" "osascript rc=$rc" "$(secs $t)s" "ancora aperta: $(pgrep -x TextEdit >/dev/null && echo si || echo no)" "$(head -1 "$R/quit-textedit.txt")"
pkill -x TextEdit
D=it.ledion.OrbitLR
defaults delete $D 2>/dev/null
avvio "primo-diretto" diretto          # primo avvio vero: benvenuto
avvio "secondo-diretto" diretto
defaults write $D welcomeDone -bool true; defaults write $D launchScreen -bool false; defaults write $D tips -bool false
defaults write $D lastLaunchVersion -string "$(defaults read "$APP/Contents/Info" CFBundleShortVersionString)"
avvio "open-senza-benvenuto" open
ls -la ~/Desktop > "$R/scrivania.txt" 2>&1
mkdir -p "$R/desktop"; cp ~/Desktop/*OrbitLR* ~/Desktop/*blocc* ~/Desktop/*Rapporto* "$R/desktop/" 2>/dev/null

# ── 8. Senza strumenti per sviluppatori (niente swiftc, come molti utenti) ──
phase "Senza strumenti per sviluppatori"
XS=$(xcode-select -p); print "xcode-select: $XS"
for p in /Library/Developer/CommandLineTools /Applications/Xcode*.app(N); do sudo mv "$p" "$HIDE/dev_${p:t}"; done
ls /Applications | grep -i xcode
t=$(now); to 30 swiftc --version > "$R/swiftc-senza.txt" 2>&1; rec "swiftc senza strumenti" "rc=$?" "$(secs $t)s" "$(head -1 "$R/swiftc-senza.txt" | cut -c1-140)"
rm -rf ~/Library/Application\ Support/LRConverter
FASE=senzaxcode
corri "pdf-unisci" merge "" doc.pdf tre-pagine.pdf foto.jpg
corri "pdf-png"    to:png "" doc.pdf
corri "img-png-jpg" to:jpg "" foto.png
avvio "senza-xcode" open
for f in "$HIDE"/dev_*(N); do n=${f:t}; n=${n#dev_}; if [[ $n == Xcode* ]]; then sudo mv "$f" "/Applications/$n"; else sudo mv "$f" "/Library/Developer/$n"; fi; done
sudo xcode-select -s "$XS" 2>/dev/null

# ── 9. Di nuovo con le librerie di Homebrew (per vedere il resto dei problemi) ──
phase "Con Homebrew rimesso"
rimetti
FASE=conbrew; giro_av
cp ~/Library/Logs/LRConverter.log "$R/LRConverter-finale.log" 2>/dev/null

# ── 10. Controllo delle uscite (dimensioni, durata) ────────────────────
phase "Controllo uscite"
for l in "$R"/giro-*/*/uscite.lst(N); do
  for o in ${(f)"$(<$l)"}; do
    [[ -f $o ]] || continue
    case ${o:e} in
      png|jpg|webp|heic|tiff) print -r -- "${o#$R/}  $(sips -g pixelWidth -g pixelHeight "$o" 2>/dev/null | awk '/pixel/{printf "%s ", $2}')" ;;
      pdf) print -r -- "${o#$R/}  pagine~$(grep -a -c '/Type */Page[^s]' "$o")" ;;
      *) print -r -- "${o#$R/}  $("$PROBE" -v error -show_entries format=duration:stream=codec_name,width,height -of csv=p=0 "$o" 2>&1 | xargs)" ;;
    esac
  done
done | tee "$R/uscite-controllo.txt"

# Rapporti di arresto e righe di sistema
mkdir -p "$R/arresti"
cp ~/Library/Logs/DiagnosticReports/*OrbitLR* ~/Library/Logs/DiagnosticReports/*ffmpeg* ~/Library/Logs/DiagnosticReports/*ffprobe* "$R/arresti/" 2>/dev/null
sudo cp /Library/Logs/DiagnosticReports/*OrbitLR* "$R/arresti/" 2>/dev/null; sudo chmod -R a+r "$R/arresti"
log show --last 40m --style compact --predicate 'process == "OrbitLR"' 2>/dev/null | tail -n 400 > "$R/log-sistema.txt"
print ""; print "RIASSUNTO"; cat "$SUM"
