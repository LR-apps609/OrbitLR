#!/bin/zsh
# M09 · Installa la build da provare. Uso: install.sh 6.0.2|6.0.3  (6.0.3: pacchetto.tar già scaricato nella cartella corrente)
set -e
rm -rf x y dist; pkill -x OrbitLR 2>/dev/null || true; sudo rm -rf /Applications/OrbitLR.app
if [ "$1" = 6.0.3 ]; then
  mkdir -p dist && tar -C dist -xf pacchetto.tar && Z=$(find dist -name "app.zip" | head -n 1); ditto -x -k "$Z" x && cp -R "$(find x -maxdepth 3 -type d -name OrbitLR.app | head -n 1)" /Applications/
else
  curl -fsSL -o o.orbitlr https://github.com/LR-apps609/OrbitLR/releases/download/v6.0.2/OrbitLR.6.0.2.orbitlr
  ditto -x -k o.orbitlr x
  find x -maxdepth 4 -name "*.app" -o -maxdepth 4 -name "*.zip" | head -n 20
  APPDIR=$(find x -maxdepth 4 -type d -name "OrbitLR.app" | head -n 1)
  if [ -z "$APPDIR" ]; then Z=$(find x -maxdepth 4 -name "*.zip" | head -n 1); ditto -x -k "$Z" y; APPDIR=$(find y -maxdepth 4 -type d -name "OrbitLR.app" | head -n 1); fi
  cp -R "$APPDIR" /Applications/
fi
xattr -dr com.apple.quarantine /Applications/OrbitLR.app
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" /Applications/OrbitLR.app/Contents/Info.plist
D=it.ledion.OrbitLR
defaults write $D welcomeDone -bool true; defaults write $D launchScreen -bool false; defaults write $D tips -bool false
defaults write $D lastLaunchVersion -string "$1"; defaults write $D AppleLanguages -array it
