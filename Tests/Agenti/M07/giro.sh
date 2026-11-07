#!/bin/zsh
# M07 · «Installazione pulita per chi non sa niente» sul macOS più vecchio supportato.
# Uso: giro.sh CARTELLA_USCITA CARTELLA_STRUMENTI
# Non si ferma mai al primo errore: ogni passo scrive una riga in esiti.tsv (passo, esito, dettaglio).
emulate zsh
setopt NO_NOMATCH
OUT=$1; BIN=$2
mkdir -p "$OUT/foto" "$OUT/ax" "$OUT/motore"
ESITI="$OUT/esiti.tsv"; : > "$ESITI"
APPDIR=/Applications/OrbitLR.app
D=it.ledion.OrbitLR
zmodload zsh/datetime
T0=$EPOCHREALTIME
ts() { printf "%6.1f" $(( EPOCHREALTIME - T0 )) }
esito() { print -r -- "$1"$'\t'"$2"$'\t'"$3" >> "$ESITI"; print -r -- "[$(ts)s] $1: $2 — $3"; }
finestre() { "$BIN/finestre" "$@" 2>/dev/null; }
vivo() { pgrep -x OrbitLR >/dev/null; }
crash_count() { ls ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -ci orbitlr; }

# Foto: schermo intero + finestra principale (livello 0, la più grande) + pannelli sopra (livello > 0)
foto() {
  local n=$1
  screencapture -x "$OUT/foto/$n-schermo.png" 2>/dev/null
  local l; l=$(finestre)
  print -r -- "== $n ($(ts)s)"$'\n'"$l" >> "$OUT/finestre.txt"
  local main=$(print -r -- "$l" | awk '$2==0 {print $5*$6, $1}' | sort -n | tail -n 1 | cut -d' ' -f2)
  [[ -n $main ]] && screencapture -x -o -l"$main" "$OUT/foto/$n.png" 2>/dev/null
  local pan=$(print -r -- "$l" | awk '$2>0 && $2<25 && $5>200 {print $5*$6, $1}' | sort -n | tail -n 1 | cut -d' ' -f2)
  [[ -n $pan ]] && screencapture -x -o -l"$pan" "$OUT/foto/$n-pannello.png" 2>/dev/null
  return 0
}

# Accessibilità (System Events): testi e pulsanti visibili, per controllare cosa c'è scritto
ax_ok=0
ax() { perl -e 'alarm shift; exec @ARGV' 25 osascript "$@" 2>&1; }
ax_dump() {  # nome
  (( ax_ok )) || return 0
  ax -e 'tell application "System Events" to tell process "OrbitLR"
    set out to ""
    repeat with w in windows
      set out to out & "### finestra: " & (name of w as text) & " " & ((size of w) as text) & linefeed
      try
        repeat with e in (entire contents of w)
          try
            set r to role of e
            if r is in {"AXStaticText", "AXButton", "AXCheckBox", "AXRadioButton", "AXRow", "AXTextField", "AXPopUpButton"} then
              set nm to ""
              try
                set nm to (name of e as text)
              end try
              if nm is "" or nm is "missing value" then
                try
                  set nm to (value of e as text)
                end try
              end if
              set out to out & r & " | " & nm & linefeed
            end if
          end try
        end repeat
      end try
    end repeat
    return out
  end tell' > "$OUT/ax/$1.txt"
}
tasto() {  # tasto [modificatori AppleScript] — sempre verso OrbitLR
  (( ax_ok )) || return 1
  ax -e 'tell application "System Events" to tell process "OrbitLR" to set frontmost to true' >/dev/null
  sleep 0.4
  if [[ $1 == <-> ]]; then
    ax -e "tell application \"System Events\" to key code $1${2:+ using {$2}}"
  else
    ax -e "tell application \"System Events\" to keystroke \"$1\"${2:+ using {$2}}"
  fi
}
clic() {  # nome del pulsante (in qualsiasi finestra di OrbitLR)
  (( ax_ok )) || return 1
  ax -e "tell application \"System Events\" to tell process \"OrbitLR\"
    repeat with w in windows
      try
        repeat with e in (entire contents of w)
          try
            if role of e is \"AXButton\" and ((name of e as text) is \"$1\" or (description of e as text) is \"$1\") then
              click e
              return \"cliccato\"
            end if
          end try
        end repeat
      end try
    end repeat
    return \"non trovato\"
  end tell"
}
esci() {
  osascript -e 'tell application "OrbitLR" to quit' >/dev/null 2>&1
  for i in {1..20}; do vivo || break; sleep 0.5; done
  if vivo; then pkill -x OrbitLR; sleep 1; esito "$1-uscita" FALLITO "⌘Q/quit non ha chiuso l'app in 10 s (chiusa a forza)"; fi
}
attendi_principale() {  # secondi massimi → stampa i secondi o «mai»
  local s=$EPOCHREALTIME
  for i in {1..$(( $1 * 2 ))}; do
    if finestre | awk '$2==0 && $5>=600 {f=1} END {exit !f}'; then printf "%.1f" $(( EPOCHREALTIME - s )); return 0; fi
    sleep 0.5
  done
  print mai; return 1
}

# ─── 0. Il Mac ────────────────────────────────────────────────────────
{ sw_vers; uname -m; print "schermo: $(finestre schermo)"; system_profiler SPDisplaysDataType 2>/dev/null | grep -E "Resolution|Retina|Chipset|Metal"; } > "$OUT/mac.txt"
cat "$OUT/mac.txt"
print "== Programmi trovati (dopo aver nascosto Homebrew)" >> "$OUT/mac.txt"
for x in ffmpeg ffprobe magick convert gs pandoc soffice exiftool whisper-cli rsvg-convert swiftc brew; do
  print "$x: $(command -v $x || print -- '-')" >> "$OUT/mac.txt"
done
plutil -p "$APPDIR/Contents/Info.plist" | grep -E "LSMinimumSystemVersion|CFBundleShortVersionString|CFBundleVersion|DTSDKName|DTXcode" >> "$OUT/mac.txt"
# Versione minima scritta dentro ogni programma dell'app (LC_BUILD_VERSION)
print "== minos dei programmi dentro l'app" >> "$OUT/mac.txt"
find "$APPDIR" -type f -perm -u+x | while read -r f; do
  file "$f" | grep -q Mach-O || continue
  for a in $(lipo -archs "$f" 2>/dev/null); do
    m=$(vtool -arch $a -show-build "$f" 2>/dev/null | awk '/minos/ {print $2}' | head -n 1)
    print "$m $a ${f#$APPDIR/}" >> "$OUT/mac.txt"
  done
done
OSV=$(sw_vers -productVersion)
bad=$(awk -v os="$OSV" 'NF==3 && $1 ~ /^[0-9]/ { split($1,a,"."); split(os,b,"."); if (a[1]+0 > b[1]+0 || (a[1]+0 == b[1]+0 && a[2]+0 > b[2]+0)) print }' "$OUT/mac.txt")
if [[ -n $bad ]]; then esito minos FALLITO "programmi che chiedono un macOS più nuovo di $OSV: $bad"; else esito minos OK "tutti i programmi dell'app partono da macOS ≤ $OSV"; fi

# ─── 1. Utente nuovo: niente preferenze, niente cartelle dell'app ───────────
pkill -x OrbitLR 2>/dev/null
defaults delete $D >/dev/null 2>&1
rm -rf ~/Library/Preferences/$D.plist ~/Library/Application\ Support/LRConverter ~/Library/Application\ Support/OrbitLR \
       ~/Library/Caches/LRConverter ~/Library/Caches/$D ~/Library/Logs/LRConverter.log ~/Library/Saved\ Application\ State/$D.savedState
killall cfprefsd 2>/dev/null
C0=$(crash_count)

# Il permesso di Accessibilità serve solo per premere i tasti come un utente: si controlla
open -a Finder; sleep 1

# ─── 2. Primo avvio ──────────────────────────────────────────────────────
TL=$EPOCHREALTIME
open "$APPDIR"
sleep 2; foto 01-avvio-2s
if ax -e 'tell application "System Events" to tell process "OrbitLR" to get name of windows' | grep -qiE "not allowed|non è consentito|assistive|-1719|-25211|-1743"; then
  ax_ok=0; esito accessibilita AVVISO "System Events non può comandare OrbitLR: niente tasti né clic (solo foto)"
else
  ax_ok=1; esito accessibilita OK "System Events può premere tasti e leggere i testi"
fi
sleep 3; foto 02-avvio-5s
sleep 4; foto 03-avvio-9s; ax_dump 03-benvenuto
if vivo; then esito primo-avvio OK "l'app è aperta dopo 9 s"; else esito primo-avvio FALLITO "l'app non è aperta dopo 9 s (si è chiusa?)"; fi
pan=$(finestre | awk '$2>0 && $2<25 && $5>=400 {print $5"x"$6}' | head -n 1)
if [[ -n $pan ]]; then esito benvenuto OK "pannello di benvenuto visibile ($pan)"; else esito benvenuto FALLITO "nessun pannello di benvenuto dopo 9 s; finestre: $(finestre | tr '\n' ';')"; fi
grep -q "Prima di iniziare" "$OUT/ax/03-benvenuto.txt" 2>/dev/null && esito benvenuto-testo OK "«Prima di iniziare» letto dall'accessibilità"

# Permessi: «Concedi i permessi» (Invio, come farebbe chiunque)
tasto 36
for s in 3 8 15 25; do sleep $(( s - ${prev:-0} )); prev=$s; foto 04-permessi-${s}s; done
unset prev
finestre tutte | grep -viE "Dock|Window Server|Menubar|Control Cent|SystemUIServer|Spotlight|TextInput|Notification Center" > "$OUT/finestre-sistema-permessi.txt"
ax_dump 04-permessi
# Se macOS sta ancora chiedendo qualcosa (finestra di sistema non vista), «Più tardi» non deve lasciare bloccati
if grep -q "Concedi i permessi" "$OUT/ax/04-permessi.txt" 2>/dev/null; then
  r=$(clic "Più tardi"); esito permessi AVVISO "dopo 25 s ancora in attesa di macOS; «Più tardi»: $r"
  sleep 2; foto 05-dopo-piu-tardi
else
  esito permessi OK "richieste finite in ≤ 25 s"
  tasto 36; sleep 2; foto 05-dopo-continua    # «Continua»
fi
ax_dump 05-pagina
# Le tre pagine della guida: Avanti, Avanti, Inizia (Invio)
for p in 1 2 3; do
  tasto 36; sleep 2; foto 06-guida-$p; ax_dump 06-guida-$p
done
sec=$(attendi_principale 15)
if [[ $sec == mai ]]; then
  esito finestra-principale FALLITO "dopo il benvenuto la finestra principale non compare entro 15 s"
  # La rete di sicurezza dell'app (20 s) dovrebbe mostrarla comunque
  sleep 8; foto 07-dopo-rete
  sec=$(attendi_principale 5)
  [[ $sec != mai ]] && esito finestra-principale-rete OK "comparsa solo con la rete di sicurezza"
else
  esito finestra-principale OK "visibile ${sec}s dopo l'ultimo Invio (avvio totale $(printf %.0f $(( EPOCHREALTIME - TL )))s)"
fi
sleep 2; foto 07-principale; ax_dump 07-principale
[[ $(defaults read $D welcomeDone 2>/dev/null) == 1 ]] && esito welcomeDone OK "il benvenuto risulta finito" || esito welcomeDone FALLITO "welcomeDone non salvato"

# ─── 3. Ogni sezione della barra laterale, con i tasti dell'app (⌘1…⌘5, ⌘0, ⌘?) ───
typeset -a SEZ=("1:converti" "2:pdf" "3:immagini" "4:video" "5:audio" "0:attivita")
for x in $SEZ; do
  k=${x%%:*}; n=${x#*:}
  if tasto "$k" "command down" >/dev/null; then
    sleep 2.5; foto 10-sez-$n; ax_dump 10-sez-$n
    vivo || { esito sezione-$n FALLITO "l'app si è chiusa aprendo $n"; break; }
    esito sezione-$n OK "aperta con ⌘$k"
  fi
done
if vivo && tasto "/" "command down, shift down" >/dev/null; then sleep 2.5; foto 10-sez-aiuto; ax_dump 10-sez-aiuto; esito sezione-aiuto OK "⌘? inviato"; fi
# Le sezioni «avanzate» (chiuse di base): si apre il gruppo e si sceglie la voce, come con il mouse
for n in "Cartelle automatiche" "Le mie azioni" "Componenti"; do
  vivo || break
  r=$(ax -e "tell application \"System Events\" to tell process \"OrbitLR\"
    set frontmost to true
    repeat with e in (entire contents of window 1)
      try
        if (role of e is \"AXStaticText\") and ((value of e as text) is \"$n\" or (name of e as text) is \"$n\") then
          set p to position of e
          set s to size of e
          click at {(item 1 of p) + 5, (item 2 of p) + (item 2 of s) / 2}
          return \"cliccato\"
        end if
      end try
    end repeat
    return \"non visibile\"
  end tell")
  if [[ $r == *non\ visibile* ]]; then
    # Il gruppo «Altro» è chiuso: lo si apre con un clic sul suo pulsante
    r0=$(clic "Avanzate"); print "Avanzate: $r0" >> "$OUT/mac.txt"; sleep 1.5
    r=$(ax -e "tell application \"System Events\" to tell process \"OrbitLR\"
      repeat with e in (entire contents of window 1)
        try
          if (role of e is \"AXStaticText\") and ((value of e as text) is \"$n\") then
            set p to position of e
            click at {(item 1 of p) + 5, (item 2 of p) + 6}
            return \"cliccato\"
          end if
        end try
      end repeat
      return \"non visibile\"
    end tell")
  fi
  sleep 2.5; tag=${n// /-}; foto "11-sez-$tag"; ax_dump "11-sez-$tag"
  esito "sezione-$tag" $([[ $r == *cliccato* ]] && print OK || print AVVISO) "$r"
done
vivo || esito sezioni FALLITO "l'app si è chiusa durante il giro delle sezioni"

# Chiudere la finestra (⌘W): la prima volta avvisa «OrbitLR resta pronta»
tasto w "command down" >/dev/null; sleep 2; foto 12-chiusa; ax_dump 12-chiusa
grep -q "resta pronta" "$OUT/ax/12-chiusa.txt" 2>/dev/null && esito chiudi-finestra OK "avviso «OrbitLR resta pronta» mostrato"
clic "Va bene" >/dev/null; sleep 1
esci primo
C1=$(crash_count)
(( C1 > C0 )) && esito arresti FALLITO "nuovi rapporti di arresto dopo il primo avvio: $(ls ~/Library/Logs/DiagnosticReports | grep -i orbitlr | tr '\n' ' ')"
defaults read $D > "$OUT/preferenze-dopo-primo-avvio.txt" 2>&1
# Il nome vero della misura salvata della finestra
FK=$(defaults read $D 2>/dev/null | grep -oE '"NSWindow Frame [^"]+"' | head -n 1 | tr -d '"')
print "chiave misura finestra: ${FK:-nessuna}" >> "$OUT/mac.txt"

# ─── 4. Misure della finestra (come build.yml «dispositivi»: misura salvata, poi si riapre) ───
SCR=($(finestre schermo)); SW=${SCR[1]:-1440}; SH=${SCR[2]:-900}
for m in "1120x760" "880x620" "1100x600" "1280x800" "1440x900" "700x480" "${SW}x${SH}"; do
  w=${m%x*}; h=${m#*x}
  for k in "NSWindow Frame main" "NSWindow Frame SwiftUI.main" "NSWindow Frame OrbitLR" ${FK:+"$FK"}; do
    defaults write $D "$k" "40 40 $w $h 0 0 $SW $SH"
  done
  open "$APPDIR"
  sec=$(attendi_principale 25)
  sleep 3
  got=$(finestre | awk '$2==0 {print $5"x"$6}' | sort -t x -k1,1n | tail -n 1)
  foto "20-misura-$m"; ax_dump "20-misura-$m"
  if [[ $sec == mai ]]; then esito "misura-$m" FALLITO "finestra principale mai comparsa in 25 s"
  else esito "misura-$m" OK "chiesta $m, avuta ${got:-?} (comparsa in ${sec}s)"; fi
  # Barra laterale su Sonoma: le voci devono avere il nome intero
  if [[ -s "$OUT/ax/20-misura-$m.txt" ]]; then
    trunc=$(grep -E '^AXStaticText \| .{1,2}…$' "$OUT/ax/20-misura-$m.txt" | head -n 3 | tr '\n' ' ')
    [[ -n $trunc ]] && esito "barra-laterale-$m" FALLITO "voci troncate: $trunc"
  fi
  esci "misura-$m"
done

# ─── 5. Link orbitlr:// e «Apri con» (gli ingressi dell'app) ─────────────
mkdir -p ~/Desktop/M07
cp "$OUT/../fixture/foto.png" ~/Desktop/M07/foto.png 2>/dev/null
open "orbitlr://open?f=$HOME/Desktop/M07/foto.png"
sec=$(attendi_principale 25); sleep 3; foto 30-link; ax_dump 30-link
if vivo; then esito link-orbitlr OK "orbitlr://open avviata ($sec s)"; else esito link-orbitlr FALLITO "l'app non è aperta dopo orbitlr://open"; fi
grep -q "foto" "$OUT/ax/30-link.txt" 2>/dev/null && esito link-orbitlr-file OK "il file compare nella finestra"
open "orbitlr://qualcosa-di-sbagliato"; sleep 3; vivo && esito link-sbagliato OK "un link sconosciuto non chiude l'app" || esito link-sbagliato FALLITO "l'app si è chiusa con un link sconosciuto"
open "orbitlr://open?f=/percorso/che/non/esiste.png"; sleep 3; vivo && esito link-file-mancante OK "un file che non c'è non chiude l'app" || esito link-file-mancante FALLITO "chiusa"
foto 31-link-sbagliati
esci link
open -a "$APPDIR" ~/Desktop/M07/foto.png; sec=$(attendi_principale 25); sleep 3; foto 32-apri-con; ax_dump 32-apri-con
vivo && esito apri-con OK "«Apri con» avviata ($sec s)" || esito apri-con FALLITO "non aperta"
esci apri-con

# ─── 6. In inglese (argomento di avvio standard di macOS) ────────────────
open -a "$APPDIR" --args -AppleLanguages "(en)"; sec=$(attendi_principale 25); sleep 3; foto 40-inglese; ax_dump 40-inglese
if grep -qE "Convert|Activity|Help" "$OUT/ax/40-inglese.txt" 2>/dev/null; then esito inglese OK "testi in inglese"
elif (( ax_ok )); then esito inglese AVVISO "nessun testo inglese letto (vedi ax/40-inglese.txt)"; fi
esci inglese

C2=$(crash_count)
(( C2 > C0 )) && esito arresti-totali FALLITO "rapporti di arresto: $(ls ~/Library/Logs/DiagnosticReports | grep -i orbitlr | tr '\n' ' ')"
cp ~/Library/Logs/DiagnosticReports/*OrbitLR* "$OUT/" 2>/dev/null
cp ~/Library/Logs/LRConverter.log "$OUT/LRConverter-app.log" 2>/dev/null
ls ~/Desktop > "$OUT/scrivania.txt" 2>&1
cp ~/Desktop/*OrbitLR*.txt "$OUT/" 2>/dev/null     # 6.0.3: rapporto del rilevatore di blocchi
print "fine interfaccia: $(ts)s"
exit 0
