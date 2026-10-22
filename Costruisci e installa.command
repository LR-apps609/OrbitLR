#!/bin/zsh
# ════════════════════════════════════════════════════════════════════
#  Costruisce OrbitLR.app e la installa in Applicazioni.
#  Fai doppio clic su questo file. Per aggiornare l'app, rifallo.
# ════════════════════════════════════════════════════════════════════
cd "${0:A:h}" || exit 1
clear
print ""
print "  OrbitLR — costruisco l'app"
print "  ══════════════════════════"
print ""

fail() { print ""; print "  ❌ $1"; print ""; print "  Mandami uno screenshot di questa finestra."; exit 1 }

# 1. Xcode
print "  1/5  Controllo Xcode…"
[[ -d /Applications/Xcode.app ]] || fail "Non trovo Xcode in Applicazioni. Installalo dal Mac App Store e aprilo una volta."
if [[ $(xcode-select -p 2>/dev/null) != /Applications/Xcode.app/* ]]; then
  print "       Imposto Xcode come strumento predefinito (ti chiede la password del Mac)…"
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer || fail "Non riesco a impostare Xcode."
fi
if ! xcodebuild -checkFirstLaunchStatus >/dev/null 2>&1; then
  print "       Completo la prima configurazione di Xcode (ti chiede la password del Mac)…"
  sudo xcodebuild -license accept >/dev/null 2>&1
  sudo xcodebuild -runFirstLaunch >/dev/null 2>&1
fi
print "       ✅"

# 2. XcodeGen (crea il progetto Xcode dai file di testo)
print "  2/5  Preparo il progetto…"
[[ -x /opt/homebrew/bin/brew ]] && eval "$(/opt/homebrew/bin/brew shellenv)"
if ! command -v xcodegen >/dev/null 2>&1; then
  command -v brew >/dev/null 2>&1 || fail "Non trovo Homebrew."
  brew install --quiet xcodegen >/dev/null 2>&1 || fail "Non riesco a installare XcodeGen."
fi
xcodegen generate --quiet >/dev/null 2>&1 || xcodegen generate || fail "Non riesco a creare il progetto Xcode."
print "       ✅"

# 3. Compilazione
#    Si compila fuori da Documenti/Scrivania: se sono sincronizzate con iCloud, aggiungono ai file
#    delle informazioni nascoste che fanno fallire la firma dell'app.
print "  3/5  Compilo l'app (la prima volta 1–3 minuti)…"
BUILD_DIR="$HOME/Library/Caches/OrbitLR-build"
rm -rf build "$BUILD_DIR" "$HOME/Library/Caches/LRConverter-build" LRConverter.xcodeproj
xattr -cr . 2>/dev/null
if ! xcodebuild -project OrbitLR.xcodeproj -scheme OrbitLR -configuration Release \
     -destination 'generic/platform=macOS' -derivedDataPath "$BUILD_DIR" \
     CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= \
     -quiet build > build.log 2>&1; then
  print ""
  if grep -qE "error:" build.log; then
    grep -E "error:" build.log | sed 's/^/     /' | head -n 25
  else
    tail -n 15 build.log | sed 's/^/     /'
  fi
  fail "La compilazione non è riuscita (dettagli completi in build.log)."
fi
APP_BUILT="$BUILD_DIR/Build/Products/Release/OrbitLR.app"
[[ -d $APP_BUILT ]] || fail "Non trovo l'app compilata."
print "       ✅"

# 4. Installazione
print "  4/5  Installo in Applicazioni…"
LSREG=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
osascript -e 'tell application "OrbitLR" to quit' >/dev/null 2>&1
osascript -e 'tell application "LRConverter" to quit' >/dev/null 2>&1
sleep 1
# La versione precedente si chiamava LRConverter: la tolgo per non avere due app uguali
if [[ -d /Applications/LRConverter.app ]]; then
  $LSREG -u /Applications/LRConverter.app >/dev/null 2>&1
  rm -rf /Applications/LRConverter.app
fi
rm -rf /Applications/OrbitLR.app
cp -R "$APP_BUILT" /Applications/ || fail "Non riesco a copiare l'app in Applicazioni."
xattr -dr com.apple.quarantine /Applications/OrbitLR.app 2>/dev/null
# La copia compilata nella cache non deve risultare come una seconda OrbitLR
$LSREG -u "$APP_BUILT" >/dev/null 2>&1
rm -rf "$BUILD_DIR"
$LSREG -f /Applications/OrbitLR.app >/dev/null 2>&1
/System/Library/CoreServices/pbs -update >/dev/null 2>&1
print "       ✅"

# 5. Avvio
print "  5/5  Apro OrbitLR…"
open /Applications/OrbitLR.app
print ""
print "  Fatto! 🎉"
print ""
print "  • Tasto destro su un file nel Finder → OrbitLR (in fondo al menu, o in «Servizi»)"
print "  • Oppure seleziona un file e premi ⌥⌘C"
print "  • L’icona di OrbitLR è anche nella barra dei menu, in alto a destra"
print ""
