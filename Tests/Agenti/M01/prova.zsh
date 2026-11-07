#!/bin/zsh
# M01 · Prova ogni azione sulle immagini, un file alla volta, come fa l'app.
# Uso: prova.zsh FASE MOTORE(engine|nativo) PROGRAMMA FIXTURES RADICE
#   engine: PROGRAMMA = percorso di LRConverter.zsh (si lancia con «--run AZIONE PARAMETRO file»)
#   nativo: PROGRAMMA = banco di prova compilato (nativo AZIONE PARAMETRO file cartella)
# Per ogni azione: una copia nuova delle foto di prova in RADICE/FASE/<azione>, i registri in RADICE/_log/FASE/<azione>
emulate zsh
setopt NO_NOMATCH
FASE=$1 MOT=$2 PROG=$3 FX=$4 ROOT=$5
t() { perl -e 'alarm shift; exec @ARGV' "$@"; }     # tempo massimo per ogni lancio: niente attese infinite
typeset -a ACTS
ACTS=(to:jpg: to:png: to:heic: to:webp: to:tiff: to:pdf: to:ico: resize:half resize:3840 resize:1920 resize:1280 resize:web strip:)
[[ $MOT == nativo ]] && ACTS+=(icompress:best icompress:200 icompress:50)
IDX="$ROOT/_log/$FASE.tsv"
mkdir -p "$ROOT/_log/$FASE"
print -r -- $'fase\tazione\tparametro\tfile\trc\tsecondi\tlog\tcartella' > "$IDX"
for ap in $ACTS; do
  act=${ap%%:*}; par=${ap#*:}
  [[ $ap == to:* ]] && { act="to:${${ap#to:}%%:*}"; par=${ap#to:*:}; }
  name=${act//:/-}${par:+-$par}
  D="$ROOT/$FASE/$name"; L="$ROOT/_log/$FASE/$name"
  rm -rf "$D"; mkdir -p "$D" "$L"
  cp -Rp "$FX/." "$D/"
  chmod 755 "$D/bloccata"; cp -p "$FX/bloccata/dentro.jpg" "$D/bloccata/" 2>/dev/null; chmod 555 "$D/bloccata"
  ( cd "$D" && find . -type f -print0 | xargs -0 shasum -a 256 ) > "$L/prima.sha"
  typeset -a files=("$D"/*(.N) "$D/bloccata/dentro.jpg")
  n=0
  for f in $files; do
    (( n += 1 ))
    e=${(L)f:e}; [[ $e == jpeg ]] && e=jpg; [[ $e == tif ]] && e=tiff
    # la stessa estensione: l'app non lo propone (il motore lo salterebbe)
    [[ $act == to:* && $e == ${act#to:} ]] && continue
    lg="$L/$n.out"
    s=$EPOCHREALTIME
    if [[ $MOT == engine ]]; then
      LR_LANG=it LR_SUBDIR=Convertiti t 240 zsh "$PROG" --run "$act" "$par" "$f" > "$lg" 2>"$L/$n.err" < /dev/null
    else
      t 240 "$PROG" "$act" "$par" "$f" "${f:h}" > "$lg" 2>"$L/$n.err" < /dev/null
    fi
    rc=$?
    secs=$(( EPOCHREALTIME - s ))
    printf '%s\t%s\t%s\t%s\t%d\t%.2f\t%s\t%s\n' "$FASE" "$act" "$par" "${f#$D/}" $rc $secs "${lg#$ROOT/}" "${D#$ROOT/}" >> "$IDX"
  done
  # Unisci in un PDF (solo motore classico): tutte le immagini buone insieme, poi anche con una rotta
  if [[ $MOT == engine && $act == to:pdf ]]; then
    typeset -a good=("$D"/{gps.jpg,alpha.png,orient6.jpg,photo.webp,anim.gif,cmyk.jpg,deep16.tiff,gps.heic}(N))
    for tag in buone conrotta; do
      g=("${(@)good}"); [[ $tag == conrotta ]] && g+=("$D/rotta.jpg")
      lg="$L/merge-$tag.out"; s=$EPOCHREALTIME
      LR_LANG=it t 300 zsh "$PROG" --run merge "" $g > "$lg" 2>"$L/merge-$tag.err" < /dev/null; rc=$?
      printf '%s\t%s\t%s\t%s\t%d\t%.2f\t%s\t%s\n' "$FASE" merge "$tag" "${#g} file" $rc $(( EPOCHREALTIME - s )) "${lg#$ROOT/}" "${D#$ROOT/}" >> "$IDX"
      # il PDF unito non resta tra le uscite delle altre prove
      for o in ${(f)"$(awk -F'\t' '$1=="OUT"{print $2}' "$lg")"}; do [[ -f $o ]] && mv -f "$o" "$L/merge-$tag.pdf"; done
    done
  fi
  # Tutti i file insieme (come selezionarli tutti nel Finder), solo per «in PNG» del motore classico
  if [[ $MOT == engine && $act == to:png ]]; then
    D2="$ROOT/$FASE/tutti-insieme-png"; rm -rf "$D2"; mkdir -p "$D2"; cp -Rp "$FX/." "$D2/"
    ( cd "$D2" && find . -type f -print0 | xargs -0 shasum -a 256 ) > "$L/tutti-prima.sha"
    lg="$L/tutti.out"; s=$EPOCHREALTIME
    LR_LANG=it t 600 zsh "$PROG" --run to:png "" "$D2"/*(.N) > "$lg" 2>"$L/tutti.err" < /dev/null; rc=$?
    printf '%s\t%s\t%s\t%s\t%d\t%.2f\t%s\t%s\n' "$FASE" "to:png" "tutti" "*" $rc $(( EPOCHREALTIME - s )) "${lg#$ROOT/}" "${D2#$ROOT/}" >> "$IDX"
  fi
  ( cd "$D" && find . -type f -print0 | xargs -0 shasum -a 256 ) > "$L/dopo.sha"
  print -r -- "$FASE $name: $n file"
done
# Avanzi: cartelle di lavoro non cancellate, file temporanei, «PWNED» creato da un nome di file
{
  print -r -- "lavori rimasti nella cache: $(ls -d "$HOME/Library/Caches/LRConverter"/job.* 2>/dev/null | wc -l | tr -d ' ')"
  print -r -- "png temporanei in TMPDIR: $(ls "${TMPDIR:-/tmp}"/orbitlr-*.png 2>/dev/null | wc -l | tr -d ' ')"
  print -r -- "PWNED trovati: $(find "$ROOT" "$HOME" -maxdepth 4 -name PWNED 2>/dev/null | wc -l | tr -d ' ')"
} | tee "$ROOT/_log/$FASE-avanzi.txt"
