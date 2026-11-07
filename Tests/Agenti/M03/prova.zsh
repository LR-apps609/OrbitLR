#!/bin/zsh
# M03 · Esegue il motore come fa l'app: zsh LRConverter.zsh --run AZIONE PARAMETRO file…
# Uso: prova.zsh MOTORE.zsh CARTELLA_MOTORI(o "-") FIXTURE PIANO USCITA [LIMITE_SECONDI]
zmodload zsh/datetime
ENG=$1; MOT=$2; FIX=$3; PLAN=$4; OUT=$5; LIM=${6:-600}
mkdir -p "$OUT"
RES="$OUT/grezzi.tsv"; : > "$RES"
n=0
while IFS=$'\t' read -r act param f1 f2; do
  [[ -n $act ]] || continue
  (( n += 1 ))
  J="$OUT/j$n"; mkdir -p "$J/out"
  files=("$FIX/$f1"); [[ -n $f2 ]] && files+=("$FIX/$f2")
  # la stessa cartella del sorgente non va bene: tanti lavori sullo stesso file → uscite separate
  env_extra=(LR_DESTPATH="$J/out")
  [[ $MOT != - ]] && env_extra+=(LR_MOTORI="$MOT")
  t0=$EPOCHREALTIME
  env $env_extra perl -e 'alarm shift; exec @ARGV' $LIM /bin/zsh "$ENG" --run "$act" "$param" $files < /dev/null > "$J/stdout.txt" 2> "$J/stderr.txt"
  rc=$?
  (( rc == 142 )) && { pkill -9 -x ffmpeg; pkill -9 -x ffprobe; }
  secs=$(printf '%.2f' $(( EPOCHREALTIME - t0 )))
  # avanzi lasciati accanto al sorgente?
  print -r -- "$n"$'\t'"$act"$'\t'"$param"$'\t'"$f1"$'\t'"$rc"$'\t'"$secs" >> "$RES"
  printf '%3d %-12s %-16s %-36s rc=%-3d %6ss  %s\n' $n "$act" "$param" "$f1" $rc $secs "$(grep -E '^(OK|FAIL|NOTE|MISSING|CANCEL)' "$J/stdout.txt" | cut -f1,3 | tr '\t\n' ' ' | cut -c1-140)"
done < "$PLAN"
ls -la "$FIX" > "$OUT/fixture-dopo.txt"
