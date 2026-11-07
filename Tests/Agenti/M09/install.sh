#!/bin/zsh
# M09 · Installa la build da provare. Uso: install.sh 6.0.2|6.0.3  (6.0.3: pacchetto.tar già scaricato nella cartella corrente)
set -e
rm -rf x dist; pkill -x OrbitLR 2>/dev/null || true; sudo rm -rf /Applications/OrbitLR.app
if [ "$1" = 6.0.3 ]; then
  mkdir -p dist && tar -C dist -xf pacchetto.tar && ditto -x -k dist/OrbitLR/Firmato/app.zip x && cp -R x/OrbitLR.app /Applications/
else
  curl -fsSL -o o.orbitlr https://github.com/LR-apps609/OrbitLR/releases/download/v6.0.2/OrbitLR.6.0.2.orbitlr
  ditto -x -k o.orbitlr x && cp -R x/Prebuilt/OrbitLR.app /Applications/
fi
xattr -dr com.apple.quarantine /Applications/OrbitLR.app
/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" /Applications/OrbitLR.app/Contents/Info.plist
D=it.ledion.OrbitLR
defaults write $D welcomeDone -bool true; defaults write $D launchScreen -bool false; defaults write $D tips -bool false
defaults write $D lastLaunchVersion -string "$1"; defaults write $D AppleLanguages -array it
