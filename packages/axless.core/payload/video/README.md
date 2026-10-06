# axvideo — frame interpolation for video wallpapers

Turns a 30 fps wallpaper into a 60 fps stream by synthesising the frames the
source never had, guided by **the motion vectors the decoder itself produces**.

## Why this exists

Ambxst renders video wallpapers with `MediaPlayer` + `VideoOutput`. That
`VideoOutput` is a straight path to the screen: no frame handles, no
timestamps, no motion vectors. There is nothing to interpolate *through*, so
any real interpolation needs its own decode path. That is what this is.

A mod also cannot add Go to the Ambxst backend — the Go is compiled into the
`ambxst` binary and the mods system never rebuilds it. So this ships as its
own executable that the shell spawns, exactly like `mcp/nothingclaw` ships a
Python server.

## How it works

`decode.go` opens the file with libavcodec and, crucially, sets
`AV_CODEC_FLAG2_EXPORT_MVS`. Without that flag the decoder attaches **no**
motion vector side data at all and every frame silently degrades to a plain
cross-fade — the single easiest thing to get wrong here.

Vectors come in the decoder's own block layout (8x8, 8x16, 16x8, 16x16) and
are scattered onto a uniform 16 px grid. Gaps stay invalid rather than being
filled with zeros-with-confidence, so those cells fall back to a fade.

`synth.go` then builds each in-between frame the way FSR does: for every cell,
walk backwards along the motion vector into frame A and forwards into frame B,
then blend. Motion is clamped (a bad vector would otherwise smear a cell across
the screen) and any sample landing outside a frame degrades to a cross-fade.

## Measured result

20 source frames of a 30 fps clip, doubling to 40 output frames, compared
frame-to-frame the way a 60 Hz display would see them:

| | consecutive deltas | repeated frames | CV |
|---|---|---|---|
| duplicated (no interpolation) | `0.0, 3.41, 0.0, 4.30, 0.0…` | **20 / 39** | 1.04 |
| interpolated | `2.57, 2.52, 3.62, 3.67, 3.49…` | **0 / 39** | 0.34 |

Judder *is* that `0/d, 0/d` alternation — the frame holds, then jumps. With
interpolation it disappears and the variance drops threefold.

Throughput on this machine: ~126 output fps at 640x360, single-threaded.

## axprobe — the real frame rate

```bash
bin/axprobe video.mp4          # human readable
bin/axprobe --json video.mp4  # {"fps":30,"width":640,...}
```

`InterpolatedVideo` spawns this and feeds the result into `originalFps`, so the
capture cadence matches the actual clip instead of an assumed 30. Guessing is
not harmless here: if the capture rate disagrees with the decoder, the blend
drifts against the frames being produced, which is precisely the artefact
interpolation exists to remove.

Verified with two clips: a 30 fps file gives `originalFps=30` and a 33.33 ms
capture interval, a 60 fps file gives `originalFps=60` and 16.67 ms - read from
the container's `avg_frame_rate`, not the default.

Rate sanity is enforced on the shell side (accepted only between 1 and 480), so
a container that claims 0 or 2000 fps cannot poison the cadence.

## Building

```bash
./build.sh          # -> bin/axvideo
```

Needs `libavcodec`, `libavformat`, `libavutil`, `libswscale` development
headers and `pkg-config`. The binary links against the system libav rather
than bundling it.

## Usage

```bash
# verify motion vectors are being decoded
go run ./cmd/probe-mv video.mp4

# 30 -> 60 fps, raw RGB24 out
bin/axvideo -in video.mp4 -out frames.rgb -ratio 2
```

`-ratio 4` quadruples the frame rate, `-frames N` stops early, `-grid N` sets
the motion cell size.

## Still to do

The engine produces frames; nothing consumes them yet. The remaining piece is
the live path: a socket service that streams synthesised frames to the shell
at display refresh, plus the QML side to upload each frame as a texture and
sample it in sync with vsync. See ToDo.md → F4.
