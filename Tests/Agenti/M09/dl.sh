#!/bin/zsh
# M09 · Lancia yt-dlp con gli stessi argomenti di Sources/MusicLink.swift (download, righe 147-153).
# Uso: dl.sh <yt-dlp> <ffmpeg-dir|""> <audio|video|videoBest> <link> <cartella-lavoro>
YT=$1; MOT=$2; MODE=$3; LINK=$4; WORK=$5
mkdir -p "$WORK"
args=(--no-playlist --no-warnings --newline --progress --no-mtime --no-part)
case $MODE in
  audio) args+=(-f "bestaudio[ext=m4a]/bestaudio/best" -x --audio-format m4a --audio-quality 0) ;;
  video) args+=(-f "bv*[vcodec^=avc1][height<=1080]+ba[ext=m4a]/b[ext=mp4][height<=1080]/bv*[height<=1080]+ba/b[height<=1080]/b" --merge-output-format mp4) ;;
  videoBest) args+=(-f "bv*+ba/b" -S "res,vcodec:h264,acodec:m4a" --merge-output-format "mp4/mkv") ;;
esac
args+=(-o "$WORK/%(title).120B.%(ext)s" --print after_move:filepath)
[[ -n $MOT ]] && args+=(--ffmpeg-location "$MOT")
args+=(-- "$LINK")
"$YT" "${args[@]}" > "$WORK.out" 2> "$WORK.err"
echo $? > "$WORK.code"
