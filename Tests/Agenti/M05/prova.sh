#!/bin/zsh
# M05 · Primo avvio e AGGIORNAMENTI di OrbitLR (5.x -> 6.0.2 / 6.0.3).
# Uso: prova.sh <cartella-release> <cartella-uscita> <sequenze...>
# Nella cartella-release: OrbitLR.<V>.orbitlr (pacchetti pubblicati) ed eventualmente 603/ (pacchetto 6.0.3).
set -u
REL=$1; OUT=$2; shift 2
mkdir -p "$OUT"
HERE=${0:A:h}
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
D=it.ledion.OrbitLR
APP=/Applications/OrbitLR.app
RES="$OUT/risultati.txt"
FIN="$OUT/finestre-bin"
[ -x "$FIN" ] || swiftc -O -o "$FIN" "$HERE/finestre.swift" 2>/dev/null || FIN=""
T0=$(date +%s)
tmo() { perl -e 'alarm shift; exec @ARGV' "$@"; }   # tempo massimo per un comando

say() { print -r -- "[$(( $(date +%s) - T0 ))s] $*" | tee -a "$OUT/diario.txt"; }
esito() { print -r -- "$*" | tee -a "$RES"; }

mini() { # mini <nome>: una foto piccola dentro il registro del lavoro (base64), per vederla senza scaricare
  [ -s "$OUT/$1.png" ] || return 0
  sips -s format jpeg -s formatOptions 35 -Z 720 "$OUT/$1.png" --out "$OUT/../mini.jpg" >/dev/null 2>&1 || return 0
  print -r -- "@@FOTO $1 $(base64 -i "$OUT/../mini.jpg" | tr -d '\n') @@"
}
diag() { # diag <nome>: lo stato dell'aggiornamento, scritto nel registro del lavoro
  print -r -- "---- DIAG $1"
  [ -n "$FIN" ] && "$FIN" | sed 's/^/  win: /'
  ps -axo pid=,ppid=,etime=,command= | grep -E 'OrbitLR|ditto|codesign|lipo|xcrun|zsh -c' | grep -vE 'grep|prova.sh' | cut -c1-220 | sed 's/^/  ps: /'
  ls -d $(getconf DARWIN_USER_TEMP_DIR)OrbitLR-aggiornamento-*(N) 2>/dev/null | while read d; do print -r -- "  lavoro: $d $(du -sh "$d" 2>/dev/null | cut -f1) $(ls "$d" | tr '\n' ' ')"; done
  tail -n 15 ~/Library/Logs/LRConverter.log 2>/dev/null | cut -c1-250 | sed 's/^/  app.log: /'
  tail -n 10 ~/Library/Logs/OrbitLR-aggiornamento.log 2>/dev/null | cut -c1-250 | sed 's/^/  agg.log: /'
  log show --last 3m --style compact --predicate 'process == "OrbitLR" OR process == "syspolicyd" OR process == "tccd" OR process == "lipo" OR process == "xcrun"' 2>/dev/null \
    | grep -iE 'error|fail|denied|deny|not allowed|quarantin|gatekeeper|codesign|lipo|xcrun|developer|license|update|aggiorn|orbitlr\.|AppBundles|crash|exception' | grep -viE 'CFPasteboard|HIServices' | tail -n 25 | cut -c1-300 | sed 's/^/  sys: /'
  print -r -- "---- fine DIAG"
}
shot() { # shot <nome>
  screencapture -x "$OUT/$1.png" 2>/dev/null || true
  { echo "== $1"; [ -n "$FIN" ] && "$FIN"; } >> "$OUT/finestre.txt" 2>&1
  testi "$1"
}
testi() { # i testi visibili nelle finestre di OrbitLR (alert compresi), via Accessibilità
  local t
  t=$(osascript -e 'tell application "System Events"
    if not (exists process "OrbitLR") then return "(OrbitLR non è aperta)"
    set r to ""
    tell process "OrbitLR"
      repeat with w in windows
        set r to r & "[finestra " & (name of w as text) & "] "
        try
          repeat with s in (static texts of w)
            set r to r & (value of s as text) & " | "
          end repeat
        end try
        try
          repeat with b in (buttons of w)
            set r to r & "<" & (name of b as text) & "> "
          end repeat
        end try
        set r to r & linefeed
      end repeat
    end tell
    return r
  end tell' 2>&1)
  print -r -- "== $1: $t" >> "$OUT/testi.txt"
  print -r -- "$t"
}
clicca() { # clicca <pulsante> [<altro nome>...]: prima con Accessibilità, poi con Invio
  local r b
  for b in "$@"; do
  r=$(osascript -e "tell application \"System Events\" to tell process \"OrbitLR\"
    set frontmost to true
    repeat with w in windows
      try
        if exists button \"$b\" of w then
          click button \"$b\" of w
          return \"cliccato\"
        end if
      end try
    end repeat
    return \"non trovato\"
  end tell" 2>&1)
  say "clic su «$b»: $r"
  [[ $r == cliccato ]] && break
  done
  if [[ $r != cliccato ]]; then
    osascript -e 'tell application "System Events" to key code 36' 2>&1 | tee -a "$OUT/diario.txt"
    say "premuto Invio (exit $?)"
  fi
}
versione() { /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist" 2>/dev/null || echo nessuna; }
quale_gira() { ps -axo pid=,command= | grep -E '/OrbitLR.app/Contents/MacOS/OrbitLR' | grep -v grep | head -3; }

chiudi() {
  osascript -e 'quit app "OrbitLR"' >/dev/null 2>&1; sleep 2
  pkill -x OrbitLR 2>/dev/null; sleep 1; pkill -9 -x OrbitLR 2>/dev/null; true
}

estrai() { # estrai <file.orbitlr> <cartella>  -> app in <cartella>/.../Prebuilt/OrbitLR.app
  rm -rf "$2"; mkdir -p "$2"; ditto -x -k "$1" "$2"
  find "$2" -maxdepth 4 -type d -name OrbitLR.app -path '*Prebuilt*' | head -1
}

installa() { # installa <versione>: come un utente che ha già usato l'app (niente benvenuto)
  local v=$1 a
  chiudi
  rm -rf "$APP" ~/Library/Caches/OrbitLR-precedente.app ~/Library/Caches/OrbitLR-download
  a=$(estrai "$REL/OrbitLR.$v.orbitlr" "$OUT/../x-$v")
  ditto "$a" "$APP"
  xattr -dr com.apple.quarantine "$APP" 2>/dev/null
  "$LSREG" -f "$APP" >/dev/null 2>&1
  defaults delete $D >/dev/null 2>&1
  defaults write $D welcomeDone -bool true
  defaults write $D launchScreen -bool false
  defaults write $D tips -bool false
  defaults write $D lastLaunchVersion -string "$v"
  defaults write $D updateAutoCheck -bool false
  defaults write $D AppleLanguages -array it-IT it
  defaults write $D closeNoticeShown -bool true   # l'avviso «OrbitLR resta pronta» già visto (come un utente vero)
  : > ~/Library/Logs/LRConverter.log 2>/dev/null
  rm -f ~/Library/Logs/OrbitLR-aggiornamento.log
  say "installata $(versione) in $APP"
}

registri() { # registri <nome>: tutti i log utili di questo passo
  local n=$1
  cp ~/Library/Logs/LRConverter.log "$OUT/$n-LRConverter.log" 2>/dev/null
  cp ~/Library/Logs/OrbitLR-aggiornamento.log "$OUT/$n-aggiornamento.log" 2>/dev/null
  log show --last 4m --style compact --predicate 'process == "OrbitLR" OR process == "zsh" OR process == "mv" OR process == "tccd" OR process == "syspolicyd" OR process == "ditto" OR process == "codesign" OR process == "lipo" OR process == "xcrun" OR process == "xcode-select" OR eventMessage CONTAINS[c] "OrbitLR"' 2>/dev/null \
    | grep -viE 'CFPasteboard|HIServices|AppKit:Window' | tail -n 400 > "$OUT/$n-sistema.log"
  log show --last 4m --style compact --predicate 'subsystem == "com.apple.TCC" AND (eventMessage CONTAINS[c] "AppBundles" OR eventMessage CONTAINS[c] "OrbitLR")' 2>/dev/null | tail -n 80 > "$OUT/$n-tcc.log"
  ls -la ~/Library/Logs/DiagnosticReports/ 2>/dev/null | grep -i orbit > "$OUT/$n-crash.txt"
  for f in ~/Library/Logs/DiagnosticReports/OrbitLR*(N); do cp "$f" "$OUT/"; done
  { echo "--- precedente:"; ls -d ~/Library/Caches/OrbitLR-precedente.app 2>&1
    echo "--- cartelle di lavoro:"; ls -d ${TMPDIR:-/tmp}/OrbitLR-aggiornamento-* $(getconf DARWIN_USER_TEMP_DIR)OrbitLR-aggiornamento-*(N) 2>&1 | sort -u
    echo "--- download:"; ls -la ~/Library/Caches/OrbitLR-download 2>&1
    echo "--- app:"; ls -la /Applications | grep -i orbit
    echo "--- xattr app:"; xattr "$APP" 2>&1
    echo "--- gira:"; quale_gira; } > "$OUT/$n-stato.txt" 2>&1
}

aspetta_testo() { # aspetta_testo <regex> <secondi>  -> 0 se compare
  local i=0 t
  while (( i < $2 )); do
    t=$(testi "attesa-$i" 2>/dev/null)
    if print -r -- "$t" | grep -qE "$1"; then return 0; fi
    sleep 3; i=$((i+3))
  done
  return 1
}

aspetta_versione() { # aspetta_versione <v> <secondi>: finita quando l'app installata è <v> e gira
  local i=0
  while (( i < $2 )); do
    [[ "$(versione)" == "$1" ]] && pgrep -x OrbitLR >/dev/null && return 0
    sleep 3; i=$((i+3))
  done
  return 1
}

copia_scaricato() { # come un download dal browser: in Download, con la quarantena
  local v=$1 f=~/Downloads/OrbitLR.$1.orbitlr
  mkdir -p ~/Downloads; rm -f "$f"; cp "$REL/OrbitLR.$v.orbitlr" "$f"
  xattr -w com.apple.quarantine "0083;$(printf %x $(date +%s));Safari;$(uuidgen)" "$f"
  print -r -- "$f"
}

# ---------- Sequenze ----------

seq_info() {
  { sw_vers; uname -m; echo "spctl: $(tmo 20 spctl --status 2>&1)"; csrutil status 2>&1
    echo "xcode-select -p: $(xcode-select -p 2>&1)"
    echo "xcrun --find lipo: $(xcrun --find lipo 2>&1)"
    ls -la /usr/bin/lipo /usr/bin/codesign /usr/bin/ditto 2>&1
    echo "--- /usr/bin/lipo con DEVELOPER_DIR inesistente (come un Mac senza strumenti per sviluppatori validi):"
    DEVELOPER_DIR=/nonexistent/Dev /usr/bin/lipo -archs /bin/ls 2>&1; echo "exit=$?"
    echo "--- /usr/bin/lipo normale:"; /usr/bin/lipo -archs /bin/ls 2>&1; echo "exit=$?"
    echo "--- TCC utente:"; sqlite3 ~/Library/Application\ Support/com.apple.TCC/TCC.db "select service,client,auth_value from access" 2>&1 | head -60
    echo "--- TCC sistema:"; sudo sqlite3 /Library/Application\ Support/com.apple.TCC/TCC.db "select service,client,auth_value from access" 2>&1 | grep -iE "Accessibility|AppBundles|ScreenCapture|AppleEvents|FullDisk" | head -60
  } > "$OUT/info.txt" 2>&1
  cat "$OUT/info.txt" | cut -c1-200
  esito "info | ok | $(sw_vers -productVersion) $(uname -m) spctl=$(tmo 20 spctl --status 2>&1)"
}

seq_statico() { # firma e Gatekeeper di ogni pacchetto, senza aprire l'app
  local v a z m f
  for f in "$REL"/OrbitLR.*.orbitlr; do
    v=${${f:t}#OrbitLR.}; v=${v%.orbitlr}
    a=$(estrai "$f" "$OUT/../s-$v")
    z=$(dirname "$(dirname "$a")")/Firmato
    {
      echo "===== $v"
      echo "--- codesign -dvvv (Prebuilt):"; codesign -dvvv "$a" 2>&1 | grep -E "Identifier|Format|CodeDirectory|Signature|Authority|TeamIdentifier|Runtime|flags|Notarization|Timestamp"
      echo "--- codesign --verify --deep --strict (Prebuilt): "; codesign --verify --deep --strict --verbose=2 "$a" 2>&1 | tail -3; echo "exit=$?"
      echo "--- spctl exec:"; tmo 60 spctl -a -vv -t exec "$a" 2>&1; echo "--- spctl open:"; tmo 60 spctl -a -vv -t open --context context:primary-signature "$f" 2>&1
      command -v syspolicy_check >/dev/null && { echo "--- tmo 60 syspolicy_check distribution:"; tmo 60 syspolicy_check distribution "$a" 2>&1 | head -20; }
      echo "--- lipo: $(lipo -archs "$a/Contents/MacOS/OrbitLR" 2>&1)"
      echo "--- min macOS: $(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$a/Contents/Info.plist" 2>&1)  build: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$a/Contents/Info.plist" 2>&1)"
      if [ -f "$z/manifest.json" ]; then
        m=$(python3 -I -c 'import json,sys;d=json.load(open(sys.argv[1]));print(d["version"],d["build"],d["sha256"])' "$z/manifest.json")
        echo "--- manifesto: $m ; sha app.zip: $(shasum -a 256 "$z/app.zip" | cut -c1-64) ; firma: $(stat -f %z "$z/manifest.sig" 2>/dev/null || echo NO) byte"
        rm -rf "$OUT/../z-$v"; mkdir -p "$OUT/../z-$v"; ditto -x -k "$z/app.zip" "$OUT/../z-$v"
        echo "--- codesign --verify --deep --strict (app.zip firmato):"; codesign --verify --deep --strict --verbose=2 "$OUT/../z-$v/OrbitLR.app" 2>&1 | tail -3; echo "exit=$?"
      else echo "--- nessuna cartella Firmato"; fi
    } >> "$OUT/statico.txt" 2>&1
    esito "statico $v | $(codesign --verify --deep --strict "$a" >/dev/null 2>&1 && echo firma-ok || echo FIRMA-KO) | spctl: $(tmo 60 spctl -a -t exec "$a" 2>&1 | tr '\n' ' ')"
  done
}

seq_primo_avvio() { # primo_avvio <v>: app appena scaricata, con la quarantena, mai aperta prima
  local v=$1 a n=primo-$1
  chiudi; rm -rf "$APP"; defaults delete $D >/dev/null 2>&1
  a=$(estrai "$REL/OrbitLR.$v.orbitlr" "$OUT/../p-$v")
  ditto "$a" "$APP"
  local q="0083;$(printf %x $(date +%s));Safari;$(uuidgen)"
  find "$APP" -print0 | xargs -0 xattr -w com.apple.quarantine "$q" 2>/dev/null
  { echo "xattr: $(xattr -p com.apple.quarantine "$APP")"; tmo 60 spctl -a -vv -t exec "$APP" 2>&1; echo "exit=$?"
    command -v syspolicy_check >/dev/null && tmo 60 syspolicy_check distribution "$APP" 2>&1 | head -20; } > "$OUT/$n-spctl.txt"
  say "primo avvio $v con quarantena"
  ( open "$APP" > "$OUT/$n-open.txt" 2>&1; echo "open exit=$?" >> "$OUT/$n-open.txt" ) &
  local oe="(in sottofondo)"
  sleep 15; shot "$n-15s"; mini "$n-15s"; diag "$n-15s"
  local giro=$(pgrep -x OrbitLR >/dev/null && echo aperta || echo NON-aperta)
  sleep 10; shot "$n-25s"
  registri "$n"
  log show --last 2m --style compact --predicate 'process == "syspolicyd" OR process == "CoreServicesUIAgent" OR process == "XprotectService" OR subsystem == "com.apple.syspolicy"' 2>/dev/null | tail -n 150 > "$OUT/$n-gatekeeper.log"
  pkill -x open 2>/dev/null; cat "$OUT/$n-open.txt" 2>/dev/null; cat "$OUT/$n-spctl.txt"; tail -n 30 "$OUT/$n-gatekeeper.log" | cut -c1-250
  esito "primo_avvio $v | open: $(tr '\n' ' ' < "$OUT/$n-open.txt" 2>/dev/null), $giro dopo 15s | spctl: $(tmo 60 spctl -a -t exec "$APP" 2>&1 | tr '\n' ' ') | quarantena dopo: $(xattr -p com.apple.quarantine "$APP" 2>&1)"
  chiudi; xattr -dr com.apple.quarantine "$APP" 2>/dev/null
}

seq_file() { # file <da> <a> <aperta|chiusa>: doppio clic sul file .orbitlr scaricato
  local da=$1 a=$2 modo=$3 n="file-$1-$2-$3" f
  installa "$da"
  if [[ $modo == aperta* ]]; then open "$APP"; sleep 15; shot "$n-0-aperta"; fi
  f=$(copia_scaricato "$a")
  say "$n: apro $f"
  open "$f" 2>&1 | tee -a "$OUT/diario.txt"
  if aspetta_testo "Installare OrbitLR|Install OrbitLR|<Installa>|<Install>" 60; then
    shot "$n-1-domanda"; mini "$n-1-domanda"; clicca "Installa" "Install"
  else
    shot "$n-1-nessuna-domanda"; mini "$n-1-nessuna-domanda"; diag "$n-1-nessuna-domanda"
    clicca "Va bene" "OK"
    if aspetta_testo "Installare OrbitLR|Install OrbitLR|<Installa>|<Install>" 40; then shot "$n-1b-domanda"; mini "$n-1b-domanda"; clicca "Installa" "Install"; fi
    sample OrbitLR 2 -file "$OUT/$n-sample.txt" >/dev/null 2>&1; grep -A25 -m1 "Thread_.*DispatchQueue_1\|com.apple.main-thread" "$OUT/$n-sample.txt" | cut -c1-200 | sed 's/^/  main: /'
  fi
  sleep 4; shot "$n-2-schedina"; mini "$n-2-schedina"; diag "$n-2-schedina"
  local ok=no
  aspetta_versione "$a" 90 && ok=si
  sleep 8; shot "$n-3-fine"; mini "$n-3-fine"; diag "$n-3-fine"
  registri "$n"
  esito "$n | aggiornata=$ok | installata ora: $(versione) | gira: $(quale_gira | awk '{print $1}' | tr '\n' ' ') | testi: $(tail -n 1 "$OUT/testi.txt" | cut -c1-300)"
}

seq_menu() { # menu <da> <a>: OrbitLR -> «Controlla aggiornamenti…» -> «Scarica e installa» (scarica da GitHub)
  local da=$1 a=$2 n="menu-$1-$2"
  installa "$da"
  open "$APP"; sleep 15; shot "$n-0-aperta"
  local r
  r=$(osascript -e 'tell application "System Events" to tell process "OrbitLR"
    set frontmost to true
    set m to menu 1 of menu bar item 2 of menu bar 1
    set its_items to (name of every menu item of m)
    repeat with i in (menu items of m)
      try
        set nm to name of i as text
        if nm starts with "Controlla aggiornamenti" or nm starts with "Check for Updates" then
          click i
          return "ok: " & nm
        end if
      end try
    end repeat
    return "non trovato tra: " & (its_items as text)
  end tell' 2>&1); say "$n: menu -> $r"
  if aspetta_testo "disponibile|available|Scarica e installa|Download and Install" 40; then shot "$n-1-domanda"; mini "$n-1-domanda"; clicca "Scarica e installa" "Download and Install"; else shot "$n-1-nessuna-domanda"; mini "$n-1-nessuna-domanda"; diag "$n-1"; fi
  sleep 6; shot "$n-2-download"; diag "$n-2-download"
  local ok=no
  aspetta_versione "$a" 150 && ok=si
  sleep 8; shot "$n-3-fine"; mini "$n-3-fine"; diag "$n-3-fine"
  registri "$n"
  esito "$n | aggiornata=$ok | installata ora: $(versione) | gira: $(quale_gira | awk '{print $1}' | tr '\n' ' ') | testi: $(tail -n 1 "$OUT/testi.txt" | cut -c1-300)"
}

seq_senza_strumenti() { # come seq_file, ma /usr/bin/lipo non funziona (strumenti per sviluppatori assenti/rotti)
  launchctl setenv DEVELOPER_DIR /nonexistent/Developer
  { echo "--- DEVELOPER_DIR rotto: lipo:"; DEVELOPER_DIR=/nonexistent/Developer /usr/bin/lipo -archs /bin/ls 2>&1; echo "exit=$?"; echo "launchctl getenv: $(launchctl getenv DEVELOPER_DIR)"; } >> "$OUT/strumenti.txt"
  seq_file "$1" "$2" aperta-senza-strumenti
  launchctl unsetenv DEVELOPER_DIR
}

seq_licenza() { # come seq_file, ma con la licenza di Xcode non accettata (succede dopo un aggiornamento di macOS/Xcode)
  local P=/Library/Preferences/com.apple.dt.Xcode.plist
  sudo cp "$P" "$OUT/../xcode-licenza.bak" 2>/dev/null
  for k in IDEXcodeVersionForAgreedToGMLicense IDEXcodeVersionForAgreedToBetaLicense IDELastGMLicenseAgreedTo IDELastBetaLicenseAgreedTo; do
    sudo defaults delete /Library/Preferences/com.apple.dt.Xcode $k 2>/dev/null
  done
  { echo "--- licenza tolta: lipo da utente:"; /usr/bin/lipo -archs /bin/ls 2>&1; echo "exit=$?"; } >> "$OUT/strumenti.txt"
  seq_file "$1" "$2" aperta-licenza
  sudo cp "$OUT/../xcode-licenza.bak" "$P" 2>/dev/null
  { echo "--- licenza rimessa: lipo:"; /usr/bin/lipo -archs /bin/ls 2>&1; echo "exit=$?"; } >> "$OUT/strumenti.txt"
}

seq_arch() { # arch <v>: il controllo dell'architettura vecchio (lipo) e quello nuovo di 6.0.3 (Bundle), con e senza strumenti
  local v=$1 a probe="$OUT/../probe-arch"
  if [[ $v == 6.0.3 ]]; then a=$(find "$REL/603" -maxdepth 6 -type d -name OrbitLR.app -path '*Prebuilt*' | head -1)
  else a=$(estrai "$REL/OrbitLR.$v.orbitlr" "$OUT/../a-$v"); fi
  [[ -z $a ]] && { esito "arch $v | pacchetto non disponibile"; return; }
  cat > "$OUT/../probe.swift" <<'SW'
import Foundation
let app = URL(fileURLWithPath: CommandLine.arguments[1])
#if arch(arm64)
let need = NSBundleExecutableArchitectureARM64
#else
let need = NSBundleExecutableArchitectureX86_64
#endif
let archs = (Bundle(url: app)?.executableArchitectures ?? []).map { $0.intValue }
print("Bundle.executableArchitectures=\(archs) need=\(need) archOK(6.0.3)=\(archs.isEmpty || archs.contains(need))")
SW
  [ -x "$probe" ] || swiftc -o "$probe" "$OUT/../probe.swift" 2>>"$OUT/strumenti.txt"
  local exe="$a/Contents/MacOS/OrbitLR" m=$(uname -m) mode lo le old nw
  for mode in normale senza-strumenti; do
    if [[ $mode == normale ]]; then lo=$(/usr/bin/lipo -archs "$exe" 2>&1); le=$?; nw=$("$probe" "$a" 2>&1)
    else lo=$(DEVELOPER_DIR=/nonexistent/Developer /usr/bin/lipo -archs "$exe" 2>&1); le=$?; nw=$(DEVELOPER_DIR=/nonexistent/Developer "$probe" "$a" 2>&1); fi
    old=no; [[ "$lo" == *"$m"* ]] && old=si
    print -r -- "--- $v $mode: lipo exit=$le out=«$lo» -> archOK(lipo)=$old ; $nw" >> "$OUT/strumenti.txt"
    esito "arch $v $mode | archOK con lipo=$old (exit $le: $(print -r -- $lo | head -c 120 | tr '\n' ' ')) | nuovo: $nw"
  done
}

seq_doppio() { # doppio <da> <a>: due doppi clic di fila sul file (il secondo mentre il primo è in corso)
  local da=$1 a=$2 n="doppio-$1-$2" f
  installa "$da"; open "$APP"; sleep 15
  f=$(copia_scaricato "$a")
  open "$f"; sleep 1; open "$f"
  if aspetta_testo "Installare OrbitLR|Installa" 45; then shot "$n-1-domanda"; clicca "Annulla"; fi
  sleep 3; shot "$n-2-dopo-annulla"
  say "$n: riapro il file dopo Annulla"
  open "$f"
  if aspetta_testo "Installare OrbitLR|Installa" 30; then shot "$n-3-domanda"; clicca "Installa"; else shot "$n-3-nessuna-domanda"; fi
  local ok=no; aspetta_versione "$a" 90 && ok=si
  sleep 6; shot "$n-4-fine"; registri "$n"
  esito "$n | aggiornata=$ok | installata ora: $(versione) | testi: $(tail -n 1 "$OUT/testi.txt" | cut -c1-300)"
}

for s in "$@"; do
  say "=== $s"
  case $s in
    info) seq_info ;;
    statico) seq_statico ;;
    primo:*) seq_primo_avvio ${s#primo:} ;;
    file:*) p=(${(s.:.)s}); seq_file $p[2] $p[3] $p[4] ;;
    menu:*) p=(${(s.:.)s}); seq_menu $p[2] $p[3] ;;
    nostrumenti:*) p=(${(s.:.)s}); seq_senza_strumenti $p[2] $p[3] ;;
    doppio:*) p=(${(s.:.)s}); seq_doppio $p[2] $p[3] ;;
    licenza:*) p=(${(s.:.)s}); seq_licenza $p[2] $p[3] ;;
    arch:*) seq_arch ${s#arch:} ;;
  esac
done
chiudi
say "fine"
