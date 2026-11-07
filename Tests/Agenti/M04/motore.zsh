#!/bin/zsh
# M04 · Ogni azione audio del motore (LRConverter.zsh --run) sui file di prova.
# uso: motore.zsh <script del motore> <cartella file di prova> <cartella risultati> [solo-gruppo]
emulate zsh; setopt NO_NOMATCH
S=$1; FX=$2; R=$3; ONLY=$4
mkdir -p "$R"; TSV="$R/risultati.tsv"; [[ -f $TSV ]] || print -r -- "n	gruppo	azione	param	file	rc	secondi	righe	uscite" > "$TSV"
zmodload zsh/datetime
integer N=0
[[ -f $R/.n ]] && N=$(<"$R/.n")

info() {  # file → formato, codec, Hz, canali, bit, durata, byte
  local f=$1
  local s=$(ffprobe -v error -select_streams a:0 -show_entries stream=codec_name,sample_rate,channels,bits_per_raw_sample,sample_fmt -of default=nw=1 "$f" 2>/dev/null | tr '\n' ' ')
  local d=$(ffprobe -v error -show_entries format=format_name,duration -of default=nw=1 "$f" 2>/dev/null | tr '\n' ' ')
  print -r -- "{${f:t}: $s $d size=$(stat -f %z "$f" 2>/dev/null)}"
}

run() {  # gruppo, azione, parametro, file, [secondi max]
  local g=$1 a=$2 p=$3 f=$4 max=${5:-300}
  [[ -n $ONLY && $g != $ONLY ]] && return
  (( N += 1 )); print $N > "$R/.n"
  local od="$R/out/$N"; mkdir -p "$od"
  local t0=$EPOCHREALTIME
  LR_DESTPATH="$od" perl -e 'alarm shift; exec @ARGV' $max /bin/zsh "$S" --run "$a" "$p" "$f" > "$R/out/$N.txt" 2>&1
  local rc=$?
  local secs=$(printf '%.1f' $(( EPOCHREALTIME - t0 )))
  local lines=$(grep -v '^P	' "$R/out/$N.txt" | tr '\t' '|' | tr '\n' ' ')
  local outs="" o
  for o in "$od"/*(N); do outs+="$(info "$o") "; done
  print -r -- "$N	$g	$a	$p	${f:t}	$rc	$secs	$lines	$outs" >> "$TSV"
  print -r -- "[$N] $g $a '$p' ${f:t} → rc=$rc ${secs}s | $lines | $outs"
}

cd "$FX" || exit 1
# 1. Conversioni
for f in voce_vbr.mp3 hd_24_96.wav hd_24_96.flac voce.flac voce.m4a voce.ogg voce_24.aiff mono.wav surround51.wav surround51.flac surround51.m4a corto3s.wav; do
  [[ -f $f ]] || { print "manca $f"; continue }
  for t in mp3 m4a wav flac ogg; do [[ ${f:e} == $t ]] && continue; run conv to:$t "" "$FX/$f"; done
done
# 2. Strumenti su ogni formato
for f in voce_vbr.mp3 pause.wav voce.flac voce.m4a voce.ogg voce_24.aiff hd_24_96.wav surround51.flac; do
  [[ -f $f ]] || continue
  run tools cut "1.000|3.000" "$FX/$f"
  run tools normalize "" "$FX/$f"
  run tools voiceclean "" "$FX/$f"
  run tools silence "" "$FX/$f"
  run tools speed 2 "$FX/$f"
  run tools speed 0.5 "$FX/$f"
done
# 3. Casi limite del taglio
for f in corto3s.wav voce_vbr.mp3; do
  [[ -f $f ]] || continue
  run taglio cut "1.000|" "$FX/$f"
  run taglio cut "5.000|8.000" "$FX/$f"        # oltre la fine di un file da 3 s
  run taglio cut "2.500|1.000" "$FX/$f"        # fine prima dell'inizio
  run taglio cut "0.000|30.000" "$FX/$f"
done
# 4. Silenzi
for f in tutto_muto.wav tutto_muto.flac tutto_muto.ogg tutto_muto.m4a; do run silenzi silence "" "$FX/$f"; done
for f in voce.flac voce.ogg voce.m4a; do run taglio cut "50.000|60.000" "$FX/$f"; done
run silenzi silence "" "$FX/pause.wav"
# 5. Nomi con accenti e simboli
for f in "Caffè città — è già.wav" "L'ultima nota (versione 2).m4a" "-trattino iniziale.mp3" "Ciao 🎵 musica.flac" "$FX"/Perch*.wav(N:t); do
  [[ -f $f ]] || continue
  run nomi to:mp3 "" "$FX/$f"
  run nomi normalize "" "$FX/$f"
done
# 6. File rotti
run rotti to:wav "" "$FX/rotto.mp3" 60
run rotti normalize "" "$FX/rotto.mp3" 60
run rotti to:mp3 "" "$FX/vuoto.wav" 60
# 7. Due ore (tempo)
run lungo to:mp3 "" "$FX/lungo2h.m4a" 900
run lungo normalize "" "$FX/lungo2h.m4a" 900
run lungo silence "" "$FX/lungo2h.m4a" 900
run lungo cut "3600.000|3630.000" "$FX/lungo2h.m4a" 300
print "fatto: $N prove"
