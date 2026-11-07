#!/bin/zsh
# M01 · Compila il banco di prova con il codice VERO dell'app: NativeEngine.swift (pezzi) + SmartImage.swift
# Uso: prepara.sh CARTELLA-DEI-SORGENTI USCITA
set -e
S=$1; O=$2; H=${0:A:h}; T=$(mktemp -d)
awk '/^\/\/\/ Conversioni fatte direttamente/{exit} {print}' "$S/NativeEngine.swift" > "$T/parte1.swift"
{ echo "enum NativeEngine {"
  awk '/static func convertImage\(/{on=1} /\/\/ MARK: - Audio e video/{on=0} on{print}' "$S/NativeEngine.swift"
  echo "}"; } > "$T/parte2.swift"
cp "$S/SmartImage.swift" "$T/"
swiftc -O -o "$O" "$H/shim.swift" "$H/main.swift" "$T/parte1.swift" "$T/parte2.swift" "$T/SmartImage.swift"
