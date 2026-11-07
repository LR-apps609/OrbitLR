#!/bin/zsh
# M07 · I nomi dei simboli SF scritti nei sorgenti
cd "${1:-.}"
{
  grep -hoE '(systemName|systemImage|systemSymbolName|symbol|icon|sfSymbol): *"[a-z0-9]+(\.[a-z0-9]+)*"' Sources/*.swift ShareExtension/*.swift 2>/dev/null | sed -E 's/.*"([^"]+)"/\1/'
  grep -hE 'systemName|systemImage|systemSymbolName|symbol|icon' Sources/*.swift ShareExtension/*.swift 2>/dev/null | grep -oE '"[a-z0-9]+(\.[a-z0-9]+)+"' | tr -d '"'
  grep -hoE 'case [^:]+: *return *"[a-z0-9]+(\.[a-z0-9]+)*"' Sources/*.swift | sed -E 's/.*"([^"]+)"/\1/'
} | grep -vE '^(it|com|public|org|net|io|www)\.|\.(png|jpg|mp4|mov|txt|zsh|wav|json|orbitlr|pdf|svg|m4a|mp3|plist)$|^[0-9.]+$' | sort -u
