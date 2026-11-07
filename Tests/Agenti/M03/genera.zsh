#!/bin/zsh
# M03 · File di prova video, creati con un ffmpeg completo (Homebrew). Uso: genera.zsh FFMPEG CARTELLA GRUPPO
FF=$1; D=$2; G=$3
mkdir -p "$D"; cd "$D" || exit 1
q=(-nostdin -hide_banner -loglevel error -y)
t() { local s=$EPOCHREALTIME; "$@"; local rc=$?; printf 'fixture %-40s rc=%d %.1fs\n' "${@[-1]:t}" $rc $(( EPOCHREALTIME - s )); }
zmodload zsh/datetime
srt() { printf '1\n00:00:00,500 --> 00:00:02,500\nCiao, è una prova\n\n2\n00:00:03,000 --> 00:00:05,000\nSeconda riga 🎬\n' > "$1"; }
base720() {  # durata uscita
  t $FF $q -f lavfi -i "testsrc2=s=1280x720:r=30:d=$1" -f lavfi -i "sine=f=440:d=$1:sample_rate=48000" \
    -c:v libx264 -preset veryfast -crf 23 -g 60 -pix_fmt yuv420p -c:a aac -b:a 128k -shortest "$2"
}
case $G in
  formati)
    base720 6 clip.mov
    srt clip.srt
    t $FF $q -f lavfi -i "testsrc2=s=1280x720:r=30:d=6" -f lavfi -i "sine=f=440:d=6" -c:v libx264 -preset veryfast -crf 23 -g 60 -pix_fmt yuv420p -c:a libopus -b:a 96k -shortest clip.mkv
    t $FF $q -f lavfi -i "testsrc2=s=1280x720:r=25:d=6" -f lavfi -i "sine=f=440:d=6" -c:v mpeg4 -q:v 5 -c:a libmp3lame -q:a 4 -shortest clip.avi
    t $FF $q -f lavfi -i "testsrc2=s=1280x720:r=30:d=6" -f lavfi -i "sine=f=440:d=6" -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 1M -c:a libopus -b:a 96k -shortest clip.webm
    # Telefono in verticale: girato 1920x1080 con la rotazione nei metadati (come l'iPhone): si vede 1080x1920
    t $FF $q -f lavfi -i "testsrc2=s=1920x1080:r=30:d=8" -f lavfi -i "sine=f=330:d=8" -c:v libx264 -preset veryfast -crf 26 -g 60 -pix_fmt yuv420p -c:a aac -shortest _v.mov
    t $FF $q -display_rotation:v:0 -90 -i _v.mov -c copy -metadata:s:v:0 handler_name=Core\ Media\ Video verticale.mov
    rm -f _v.mov
    # HDR come l'iPhone: HEVC 10 bit, BT.2020 + HLG
    t $FF $q -f lavfi -i "testsrc2=s=1920x1080:r=30:d=6" -f lavfi -i "sine=f=550:d=6" -vf format=yuv420p10le \
      -c:v libx265 -preset ultrafast -x265-params "log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" \
      -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -tag:v hvc1 -c:a aac -shortest hdr10bit.mov
    # Frequenza dei fotogrammi variabile: 30 fps per 4 s, poi 10 fps
    t $FF $q -f lavfi -i "testsrc2=s=1280x720:r=30:d=10" -f lavfi -i "sine=f=440:d=10" -vf "select='if(lt(t,4),1,not(mod(n,3)))'" -fps_mode vfr \
      -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -c:a aac -shortest vfr.mp4
    t $FF $q -f lavfi -i "testsrc2=s=1280x720:r=30:d=6" -c:v libx264 -preset veryfast -crf 23 -pix_fmt yuv420p -an senza-audio.mp4
    t $FF $q -f lavfi -i "sine=f=440:d=6" -c:a aac -b:a 128k solo-audio.mp4
    base720 2 breve-2s.mp4
    cp clip.mov "Città già perché — vídeo 🎬.mov"
    cp clip.mov "emoji 😀🇮🇹 #1 & 'apice'.mp4"
    python3 -c "import shutil,unicodedata; shutil.copy('clip.mov', unicodedata.normalize('NFD','Caffè NFD é.mov'))"
    ;;
  pesanti)
    t $FF $q -f lavfi -i "testsrc2=s=3840x2160:r=60:d=5" -f lavfi -i "sine=f=440:d=5" -c:v libx264 -preset ultrafast -b:v 40M -pix_fmt yuv420p \
      -c:a aac -b:a 128k -shortest 4k60.mp4
    t $FF $q -f lavfi -i "testsrc2=s=640x360:r=25:d=1200" -f lavfi -i "sine=f=440:d=1200" -c:v libx264 -preset ultrafast -b:v 400k -g 250 -pix_fmt yuv420p \
      -c:a aac -b:a 64k -shortest lungo-20min.mp4
    ;;
  rotti)
    base720 6 _sano.mp4                                 # moov in fondo (niente faststart)
    head -c $(( $(stat -f %z _sano.mp4) * 6 / 10 )) _sano.mp4 > rotto.mp4
    head -c 300000 /dev/urandom > rotto-casuale.mkv
    t $FF $q -f lavfi -i "testsrc2=s=1280x720:r=30:d=6" -f lavfi -i "sine=d=6" -c:v libx264 -preset veryfast -g 30 -c:a aac -shortest _sano.mkv
    head -c $(( $(stat -f %z _sano.mkv) / 2 )) _sano.mkv > troncato.mkv
    : > vuoto.mp4
    rm -f _sano.mp4 _sano.mkv
    # Per il giro con l'ffmpeg di Homebrew (libx264)
    t $FF $q -f lavfi -i "testsrc2=s=1280x720:r=30:d=6" -f lavfi -i "sine=f=440:d=6" -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 1M -c:a libopus -shortest clip.webm
    t $FF $q -f lavfi -i "testsrc2=s=1920x1080:r=30:d=8" -f lavfi -i "sine=f=330:d=8" -c:v libx264 -preset veryfast -crf 26 -g 60 -pix_fmt yuv420p -c:a aac -shortest _v.mov
    t $FF $q -display_rotation:v:0 -90 -i _v.mov -c copy verticale.mov; rm -f _v.mov
    t $FF $q -f lavfi -i "testsrc2=s=1920x1080:r=30:d=6" -f lavfi -i "sine=f=550:d=6" -vf format=yuv420p10le \
      -c:v libx265 -preset ultrafast -x265-params "log-level=error:colorprim=bt2020:transfer=arib-std-b67:colormatrix=bt2020nc" \
      -color_primaries bt2020 -color_trc arib-std-b67 -colorspace bt2020nc -tag:v hvc1 -c:a aac -shortest hdr10bit.mov
    ;;
esac
ls -la "$D"
