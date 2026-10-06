#!/usr/bin/env bash
# Compile the wallpapers shaders.
#
# --glsl 440 is mandatory. A bare `qsb` bakes no GLSL at all - it only emits
# the uniform-block description - and Qt then logs
#   "No GLSL shader code found (versions tried: ... 440 ...)"
# and the ShaderEffect renders nothing, which shows up as a black wallpaper.
#
# --qt6 is NOT usable here: it implies the legacy ES versions and interpol.frag
# uses texelFetch, which ES 100/120 do not support ("texelFetch not supported
# in legacy ES"). The shaders declare #version 440, so bake exactly that.
set -euo pipefail
cd "$(dirname "$0")"
export PATH=/usr/lib/qt6/bin:$PATH
for s in interpol.vert interpol.frag; do
    qsb --glsl 440 "$s" -o "$s.qsb"
    echo "compiled $s.qsb"
done
