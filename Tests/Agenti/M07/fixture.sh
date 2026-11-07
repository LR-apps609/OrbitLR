#!/bin/zsh
# M07 · File di prova creati sul Mac (niente file grandi nel repository). Uso: fixture.sh CARTELLA FFMPEG
FX=$1; FF=$2; mkdir -p "$FX"; cd "$FX"
"$FF" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=640x400:rate=1" -frames:v 1 foto.png
"$FF" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=3000x2000:rate=1" -frames:v 1 -q:v 2 grande.jpg
"$FF" -hide_banner -loglevel error -y -f lavfi -i "testsrc2=size=1280x720:rate=30" -f lavfi -i "sine=f=440:sample_rate=48000" -t 5 -c:v mpeg4 -b:v 6M -c:a aac -shortest clip.mp4
"$FF" -hide_banner -loglevel error -y -i clip.mp4 -c copy clip.mkv
"$FF" -hide_banner -loglevel error -y -f lavfi -i "sine=f=330:duration=3:sample_rate=44100" -af "volume=0.2" suono.wav
printf 'Prova OrbitLR M07\nSeconda riga con accenti: perché città\n' > testo.txt
textutil -convert rtf -output testo.rtf testo.txt
cupsfilter testo.txt > doc.pdf 2>/dev/null || true
printf '# Titolo\n\nUn paragrafo con **grassetto**.\n' > note.md
printf 'a,b\n1,2\n' > tabella.csv
ls -la "$FX"
