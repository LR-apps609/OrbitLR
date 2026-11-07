#!/bin/zsh
# M04 · File audio di prova (generati, niente binari nel repo)
# uso: fixtures.zsh <ffmpeg> <cartella>
emulate zsh; setopt NO_NOMATCH
FF=$1; D=$2; mkdir -p "$D"; cd "$D" || exit 1
ff() { "$FF" -nostdin -hide_banner -loglevel error -y "$@" || print -r -- "FIXTURE-FAIL: $*" }

IT="Buongiorno a tutti. Oggi parliamo di caffè, di città italiane e di musica. Grazie e arrivederci."
EN="Good morning everyone. Today we talk about coffee, Italian cities and music. Thank you and goodbye."
print -r -- "$IT" > testo_it.txt; print -r -- "$EN" > testo_en.txt
vit=$(say -v '?' | awk '/it_IT/ {print $1; exit}'); ven=$(say -v '?' | awk '/en_US/ {print $1; exit}')
print -r -- "voci: it=$vit en=$ven"
say ${vit:+-v $vit} -o voce_it.aiff -- "$IT" || say -o voce_it.aiff -- "$IT"
say ${ven:+-v $ven} -o voce_en.aiff -- "$EN" || say -o voce_en.aiff -- "$EN"

ff -i voce_it.aiff -ar 44100 -ac 1 -c:a pcm_s16le voce_it.wav
ff -i voce_en.aiff -ar 44100 -ac 1 -c:a pcm_s16le voce_en.wav
# Voce con pause lunghe: it · 3 s · en · 4 s · it
ff -f lavfi -i anullsrc=r=44100:cl=mono -t 3 sil3.wav
ff -f lavfi -i anullsrc=r=44100:cl=mono -t 4 sil4.wav
ff -i voce_it.wav -i sil3.wav -i voce_en.wav -i sil4.wav -i voce_it.wav \
   -filter_complex "[0:a][1:a][2:a][3:a][4:a]concat=n=5:v=0:a=1[a]" -map "[a]" -c:a pcm_s16le pause.wav

# MP3 VBR (se l'ffmpeg ha libmp3lame), altrimenti segnalato
if "$FF" -hide_banner -encoders 2>/dev/null | grep -q libmp3lame; then
  ff -i pause.wav -c:a libmp3lame -q:a 4 voce_vbr.mp3
  ff -f lavfi -i "sine=f=440:d=3" -c:a libmp3lame -q:a 2 corto3s.mp3
else print -r -- "FIXTURE-NOTE: niente libmp3lame: mp3 da afconvert non possibile"; fi
# WAV 24 bit 96 kHz stereo (10 s, tono)
ff -f lavfi -i "sine=f=1000:d=10:sample_rate=96000" -af "pan=stereo|c0=c0|c1=0.5*c0" -c:a pcm_s24le -ar 96000 hd_24_96.wav
ff -i hd_24_96.wav -c:a flac hd_24_96.flac
ff -i pause.wav -c:a flac voce.flac
ff -i pause.wav -c:a aac -b:a 128k voce.m4a
if "$FF" -hide_banner -encoders 2>/dev/null | grep -q libvorbis; then ff -i pause.wav -c:a libvorbis -q:a 4 voce.ogg
else ff -i pause.wav -c:a vorbis -strict -2 -ac 2 voce.ogg; fi
ff -i voce_it.aiff -c:a pcm_s24be -ar 48000 voce_24.aiff
ff -f lavfi -i "sine=f=330:d=5" -ac 1 -c:a pcm_s16le mono.wav
# 5.1: sei toni diversi
ff -f lavfi -i "sine=f=200:d=6" -f lavfi -i "sine=f=300:d=6" -f lavfi -i "sine=f=400:d=6" -f lavfi -i "sine=f=60:d=6" \
   -f lavfi -i "sine=f=500:d=6" -f lavfi -i "sine=f=600:d=6" \
   -filter_complex "[0:a][1:a][2:a][3:a][4:a][5:a]join=inputs=6:channel_layout=5.1[a]" -map "[a]" -c:a pcm_s16le surround51.wav
ff -i surround51.wav -c:a flac surround51.flac
ff -i surround51.wav -c:a aac -b:a 384k surround51.m4a
ff -f lavfi -i "sine=f=440:d=3" -c:a pcm_s16le corto3s.wav
# 2 ore quasi muto: un bip ogni 10 minuti, mono 16 kHz AAC basso
ff -f lavfi -i "aevalsrc='if(lt(mod(t,600),0.5),0.3*sin(2*PI*880*t),0)':s=16000:d=7200" -ac 1 -c:a aac -b:a 16k lungo2h.m4a
ff -f lavfi -i anullsrc=r=44100:cl=mono -t 20 tutto_muto.wav
# Nomi con accenti e simboli
cp voce_it.wav "Caffè città — è già.wav"
cp voce.m4a "L'ultima nota (versione 2).m4a"
[[ -f voce_vbr.mp3 ]] && cp voce_vbr.mp3 "-trattino iniziale.mp3"
cp voce.flac "Ciao 🎵 musica.flac"
python3 -c "import unicodedata,shutil; shutil.copy('voce_it.wav', unicodedata.normalize('NFD','Perché così.wav'))"
# File rotti
head -c 50000 /dev/urandom > rotto.mp3
: > vuoto.wav
rm -f sil3.wav sil4.wav
ls -la "$D"
