#!/usr/bin/env bash
# Render an interpolated copy of a video wallpaper, with axvideo.
#
# Why pre-render instead of streaming live: QML has no way to push raw frames
# into a texture. ShaderEffectSource.textureSize is not even readable here, and
# there is no ImageProvider in Quickshell, so a live socket feed of frames has
# nowhere to land. A wallpaper loops, so a rendered copy plays perfectly well.
#
# Usage: interpolate.sh <input> <output> [multiplier]
#
# Caches by output path: re-running with an existing file is a no-op unless
# FORCE=1. The caller picks the cache path, so a changed wallpaper naturally
# gets a different name.
set -euo pipefail

in="${1:?falta el vídeo de entrada}"
out="${2:?falta la salida}"
mult="${3:-2}"
# Cap on the render resolution. The wallpaper is displayed scaled to the
# screen either way, so rendering 4K and letting the compositor downscale
# wastes several times the work for no visible gain: measured, 720p runs at
# 30 output fps, 1080p at 14, and 4K would be ~3.5 - a three minute wait for a
# clip that is going to be shown at 1536 px anyway. Override with MAXW=0.
maxw="${MAXW:-1920}"

if [ "${FORCE:-0}" != "1" ] && [ -s "$out" ]; then
    echo "$out"
    exit 0
fi

here="$(cd "$(dirname "$0")" && pwd)"
axvideo="$here/axvideo"
axprobe="$here/axprobe"
[ -x "$axvideo" ] || { echo "axvideo no encontrado en $here" >&2; exit 1; }

# The real frame rate and geometry come from the file, not from a guess: the
# rawvideo pipe has to be told both or every frame lands at the wrong stride.
info="$("$axprobe" --json "$in")"
read -r w h fps <<EOF
$(python3 -c "
import json,sys
i=json.loads(sys.argv[1])
print(i['width'], i['height'], i['fps'] or 30)
" "$info")
EOF
outfps="$(python3 -c "print($fps * $mult)")"

# Pre-scale if the source is wider than the cap. Done to a temp file so
# axvideo still reads from a real path.
src="$in"
rmaxh=""
if [ "$maxw" -gt 0 ] && [ "$w" -gt "$maxw" ]; then
    rmaxh=$(python3 -c "print(round($h * $maxw / $w))")
    scaled="${out%.*}.scaled.$$.${out##*.}"
    ffmpeg -y -hide_banner -loglevel error -i "$in" \
        -vf "scale=${maxw}:${rmaxh}" -c:v libx264 -preset veryfast -crf 18 \
        -pix_fmt yuv420p "$scaled"
    src="$scaled"
fi

# Geometry of what axvideo will actually decode.
outw="$w"; outh="$h"
if [ "$src" != "$in" ]; then
    outw="$maxw"; outh="$rmaxh"
fi

mkdir -p "$(dirname "$out")"
# The temp file must keep the output extension: ffmpeg picks its muxer
# from it and refuses ".partial.<pid>" outright.
tmp="${out%.*}.partial.$$.${out##*.}"

# A 4K clip takes minutes; if the shell is killed mid-render the temp file
# would otherwise be left behind forever. Clean it up on any exit that is not
# the successful rename.
cleanup_partial() {
    [ -n "${tmp:-}" ] && [ -f "$tmp" ] && rm -f "$tmp"
    [ -n "${scaled:-}" ] && [ -f "$scaled" ] && rm -f "$scaled"
}
trap cleanup_partial EXIT INT TERM

# axvideo emits `mult` frames per source frame as raw RGB24 on stdout; ffmpeg
# re-encodes at the multiplied rate. Encode to a temp file and rename, so a
# crash never leaves a half-written wallpaper for the shell to play.
set -o pipefail
"$axvideo" -in "$src" -out - -ratio "$mult" -quiet 2>/dev/null \
  | ffmpeg -y -hide_banner -loglevel error \
      -f rawvideo -pix_fmt rgb24 -s "${outw}x${outh}" -framerate "$outfps" -i - \
      -c:v libx264 -preset veryfast -crf 18 -pix_fmt yuv420p \
      -r "$outfps" -f mp4 "$tmp"
mv -f "$tmp" "$out"
echo "$out"
