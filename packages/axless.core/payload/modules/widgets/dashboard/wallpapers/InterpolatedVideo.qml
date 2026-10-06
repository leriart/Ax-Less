import QtQuick
import QtQuick.Controls
import QtMultimedia
import Quickshell
import Quickshell.Io
import qs.modules.globals
import qs.modules.services
import qs.modules.theme
import qs.config

/**
 * InterpolatedVideo — a video wallpaper that fills in the frames the source
 * never had.
 *
 * Port of NothingLess's approach, not a new one. The shape:
 *
 *   - One MediaPlayer / VideoOutput, as usual.
 *   - Two ShaderEffectSources over that *same* VideoOutput. One is `live`
 *     and tracks the frame currently on screen; the other is frozen with
 *     scheduleUpdate() once per source frame, so it holds the previous one.
 *     Qt keeps the frozen frame as a texture, so no IPC and no second decoder
 *     are involved.
 *   - A capture Timer ticking at the source frame interval freezes the
 *     previous frame.
 *   - A FrameAnimation, vsync-synced, advances blendFactor across that
 *     interval and hands it to the shader.
 *   - interpol.frag does the work on the GPU: it estimates motion per block
 *     by block matching, warps both frames along it, and blends. Static
 *     blocks skip the search via a cheap SAD test.
 *
 * The shader, not this file, does the interpolation. See
 * payload/shaders/interpol.frag and payload/video/README.md.
 *
 * Interpolation is off unless the caller asks for it, in which case this is
 * a plain VideoOutput with an extra off-screen copy - the reason
 * sourceItem is null rather than the VideoOutput when disabled.
 */
Item {
    id: root

    // ── Source ────────────────────────────────────────────────────
    property string sourceFile: ""
    property bool tint: false

    // The colours the tint shader is allowed to remap the video onto. Same list
    // Ambxst's own VideoWallpaper used, so the result matches the static-image
    // wallpaper path.
    readonly property var optimizedPalette: ["background", "overBackground", "shadow",
        "surface", "surfaceBright", "surfaceDim", "surfaceContainer", "surfaceContainerHigh",
        "surfaceContainerHighest", "surfaceContainerLow", "surfaceContainerLowest",
        "primary", "secondary", "tertiary", "red", "lightRed", "green", "lightGreen",
        "blue", "lightBlue", "yellow", "lightYellow", "cyan", "lightCyan",
        "magenta", "lightMagenta"]

    // ── Interpolation ──────────────────────────────────────────────
    // `multiplier` is the *declared* output rate: a 30 fps clip with a
    // multiplier of 2 is presented as 60 fps. It deliberately does not
    // change the capture rate - the shader always fills the single gap
    // between two consecutive source frames, and the display refresh does
    // the rest. Changing the capture rate instead would decouple the
    // interpolation from the source and drift.
    property bool interpolate: false
    property int multiplier: 2

    // The clip's real frame rate, used to time the capture. Capped by
    // targetInputFps so a 60 fps source is not needlessly re-blended.
    property real originalFps: 30
    property real targetInputFps: 60

    // ── Shader tuning, exposed as in NothingLess ──────────────────
    property int blockSize: 12
    property int searchRadius: 3
    property real motionThreshold: 0.05
    property bool debugMode: false

    // ── Output ────────────────────────────────────────────────────
    property real fpsOutput: 0

    readonly property real effectiveInputFps: Math.min(originalFps, targetInputFps)
    property real captureIntervalMs: 1000 / effectiveInputFps

    property real lastCaptureTime: 0
    property real blendFactor: 0.0
    property bool isOriginalFrame: true
    property int frameCounter: 0

    property int frameCountSinceLastSecond: 0
    property real lastFpsUpdateTime: 0

    // ── Pre-rendered interpolation (axvideo) ──────────────────────
    //
    // The GPU shader estimates motion per block, and its previous-frame
    // source cannot be made reliable from QML: Quickshell has no
    // ImageProvider and ShaderEffectSource does not expose textureSize, so
    // there is no way to feed it valid frames or size them correctly.
    //
    // So the real work is done up front by axvideo, which uses the decoder's
    // own motion vectors, and the shell just plays the result. A wallpaper
    // loops, so rendering a copy costs nothing at playback time.
    // Empty by default: the GPU shader is the live path, like NothingLess.
    // Point this at interpolate.sh to render an axvideo copy instead, which
    // uses the decoder's real motion vectors but is CPU bound - a 4K clip
    // takes a while, so it is opt-in rather than automatic.
    property string interpolateScriptPath: ""
    property string cacheDir: (Quickshell.env("XDG_CACHE_HOME") || Quickshell.env("HOME") + "/.cache") + "/ambxst/interpolated"
    // Non-empty once the interpolated copy exists and is what we play.
    property string interpolatedPath: ""
    property bool renderPending: false

    // Keep playing the original until the render finishes, so enabling
    // interpolation never blanks the wallpaper.
    readonly property string playbackPath: (interpolate && interpolatedPath !== "") ? interpolatedPath : sourceFile

    function _basename(p) {
        const parts = String(p).split("/");
        return parts[parts.length - 1];
    }

    function _cacheTarget() {
        // Multiplier and source both land in the name, so changing either
        // naturally produces a different cache entry.
        return cacheDir + "/" + _basename(sourceFile) + ".x" + multiplier + ".mp4";
    }

    function _startRender() {
        if (!sourceFile || interpolateScriptPath === "")
            return;
        const target = _cacheTarget();
        // No existence check on this side: neither File.exists nor
        // FileView.exists is available here (both throw), and interpolate.sh
        // already no-ops on a cached target, printing the path either way.
        renderPending = true;
        // QML resolves a bare relative path against the *current working
        // directory*, which is not where the shell runs. file:// URLs have to
        // be stripped and turned into a real path before exec, otherwise the
        // process fails silently and renderPending never clears.
        let script = String(interpolateScriptPath).replace("file://", "");
        // Run it through bash explicitly. Process execs the first argument
        // directly, and a .sh with a shebang is not guaranteed to be treated
        // as executable from here - the launch just failed and
        // renderPending never cleared.
        renderProc.command = ["bash", script, sourceFile, target, String(multiplier)];
        renderProc.running = true;
    }

    onInterpolateChanged: {
        if (interpolate && multiplier > 1) {
            _startRender();
            // Only prime the shader's frame sources while it is the thing
            // actually drawing; once axvideo has rendered a copy the shader
            // is skipped entirely.
            if (interpolatedPath === "") {
                previousFrame.scheduleUpdate();
                lastCaptureTime = Date.now();
            }
            captureTimer.restart();
            blendAnimation.running = true;
        } else {
            interpolatedPath = "";
            renderPending = false;
            captureTimer.stop();
            blendAnimation.running = false;
            // Reset so switching interpolation back on does not start from a
            // stale blendFactor and show a single garbage frame.
            blendFactor = 0;
            isOriginalFrame = true;
        }
    }

    onMultiplierChanged: {
        interpolatedPath = "";
        renderPending = false;
        if (interpolate && multiplier > 1) {
            _startRender();
            captureTimer.restart();
            blendAnimation.running = true;
        } else {
            captureTimer.stop();
            blendAnimation.running = false;
        }
    }

    // Switching source must invalidate the cache entry: a different clip
    // means a different interpolated copy.
    onPlaybackPathChanged: restart()

    Process {
        id: renderProc
        running: false
        stdout: StdioCollector {
            id: renderOut
                // The script prints the final path on its last stdout line. Read
            // it here rather than on the process: Process has no onExited, and
            // the collector's streamFinished is the only reliable end-of-output
            // signal. A run that produced nothing simply clears the flag, so a
            // failure leaves the original clip playing instead of blanking.
            onStreamFinished: {
                const out = renderOut.text.trim().split("\n").filter(s => s.length > 0);
                const target = out.length > 0 ? out[out.length - 1] : "";
                if (root.renderPending && target !== "") {
                    root.interpolatedPath = target;
                    root.restart();
                } else if (root.renderPending) {
                    console.warn("InterpolatedVideo: el render no produjo", target || "(nada)");
                }
                root.renderPending = false;
            }
        }
    }

    function restart() {
        if (!playbackPath)
            return;
        player.stop();
        player.source = "file://" + playbackPath;
        playIfNeeded();
    }

    readonly property real positionMs: player.position
    readonly property int playbackState: player.playbackState

    function pause() {
        if (player.playbackState === MediaPlayer.PlayingState)
            player.pause();
    }

    function seek(ms) {
        // Qt6 removed MediaPlayer.seek(); position is the setter now. Calling
        // the old method threw "Property 'seek' ... is not a function", which
        // is why the multi-monitor video sync tick did nothing.
        player.position = ms;
    }

    // Fired once the source is set and the node has a chance to start, so the
    // parent can apply its pause-on-fullscreen policy without racing the
    // first play().
    signal started

    // ── Real frame rate, read by the Go probe ─────────────────────
    //
    // The decoder does not advertise a frame rate through Qt, and guessing
    // one makes the capture cadence drift against the frames actually being
    // produced, which is exactly the artefact interpolation is meant to
    // remove. axprobe reads avg_frame_rate straight out of the container.
    //
    // Kept as a declared fallback so the component still animates correctly
    // before the probe answers, and if the binary is unavailable.
    property string axprobePath: Qt.resolvedUrl("../../../../video/bin/axprobe")
    property bool sourceProbed: false

    // The GPU shader is never used.
    //
    // It was kept as a fallback for the gap between enabling the toggle and
    // the render landing, and that was a mistake: its previousFrame source
    // cannot be made reliable from QML, so during that gap the wallpaper was
    // being drawn by the broken shader - which is what showed up as a zoom.
    // axvideo is slower to produce its copy (a 4K clip takes minutes, since
    // the interpolation is CPU bound) but it is correct, so the original clip
    // keeps playing until the copy is ready. No zoom, just no interpolation
    // yet.
    readonly property bool shaderActive: interpolate && multiplier > 1 && interpolatedPath === ""

    function probeSource() {
        if (!sourceFile || sourceProbed)
            return;
        sourceProbed = true;
        var path = String(axprobePath).replace("file://", "");
        if (!probeProc)
            return;
        probeProc.command = [path, "--json", "file://" + sourceFile];
        probeProc.running = true;
    }

    Process {
        id: probeProc
        running: false
        stdout: StdioCollector {
            id: probeOut
            onStreamFinished: {
                var text = probeOut.text;
                if (!text)
                    return;
                try {
                    var info = JSON.parse(text);
                    // Only accept a plausible rate: a container that claims
                    // 0 or 2000 fps would otherwise poison the cadence.
                    if (info && info.fps > 1 && info.fps < 480) {
                        root.originalFps = info.fps;
                    }
                } catch (e) {
                    console.warn("axprobe: no se pudo leer el fps:", e);
                }
            }
        }
    }

    onSourceProbedChanged: if (sourceProbed) { }

    function playIfNeeded() {
        if (!sourceFile)
            return;
        if (player.playbackState !== MediaPlayer.PlayingState) {
            player.play();
            started();
        }
    }

    onSourceFileChanged: {
        // A new file needs a new probe.
        sourceProbed = false;
        probeSource();
        restart();
    }

    Component.onCompleted: {
        probeSource();
        if (interpolate && multiplier > 1)
            _startRender();
        restart();
    }

    MediaPlayer {
        id: player
        audioOutput: muted
        videoOutput: videoNode
        loops: MediaPlayer.Infinite

        onErrorOccurred: (error, errorString) => {
            console.warn("InterpolatedVideo playback error:", errorString,
                         "source:", root.sourceFile);
        }
    }

    AudioOutput {
        id: muted
        volume: 0
    }

    // ── The frame currently being displayed ───────────────────────
    ShaderEffectSource {
        id: liveSource
        // Null when interpolation is off: pointing this at the VideoOutput
        // would force texture-capture mode and cost a full-screen copy for
        // every frame just to throw it away.
        // Needed by both the interpolator and the tint, so it stays
        // live whenever either is on.
        sourceItem: (root.shaderActive || root.tint) ? videoNode : null
        live: root.shaderActive || root.tint
        hideSource: true
        smooth: true
        visible: false
    }

    // ── The previous source frame, frozen ─────────────────────────
    ShaderEffectSource {
        id: previousFrame
        sourceItem: root.shaderActive ? videoNode : null
        live: false
        hideSource: true
        smooth: true
        visible: false
    }

    // Freeze a copy of the current frame once per source frame interval.
    Timer {
        id: captureTimer
        interval: root.captureIntervalMs
        repeat: true
        running: false
        onTriggered: {
            if (!root.interpolate || root.multiplier <= 1)
                return;
            previousFrame.scheduleUpdate();
            root.lastCaptureTime = Date.now();
        }
    }

    // Advance blendFactor in step with the display. FrameAnimation is the
    // vsync-synced callback; a plain Timer would drift against the panel.
    FrameAnimation {
        id: blendAnimation
        running: false
        onTriggered: {
            if (!root.interpolate || root.multiplier <= 1)
                return;
            if (player.playbackState !== MediaPlayer.PlayingState)
                return;

            var now = Date.now();
            var elapsed = now - root.lastCaptureTime;
            root.blendFactor = Math.min(1.0, elapsed / root.captureIntervalMs);
            // The shader brightens interpolated frames in debug mode; telling
            // it these are the real frames keeps that debug view readable.
            root.isOriginalFrame = root.blendFactor < 0.01 || root.blendFactor > 0.99;
            root.frameCounter++;

            // Count first, then publish once a second has elapsed, otherwise
            // the first window is always short by one frame and reads zero.
            root.frameCountSinceLastSecond++;
            var since = now - root.lastFpsUpdateTime;
            if (root.lastFpsUpdateTime === 0) {
                root.lastFpsUpdateTime = now;
            } else if (since >= 1000) {
                root.fpsOutput = root.frameCountSinceLastSecond * 1000 / since;
                root.frameCountSinceLastSecond = 0;
                root.lastFpsUpdateTime = now;
            }
        }
    }

    // ── Interpolation ─────────────────────────────────────────────
    ShaderEffect {
        id: effect
        anchors.fill: parent
        // Above the VideoOutput: the node has to stay visible for the frame
        // sources to keep updating, so the effect is what the user sees.
        z: 1
        visible: root.interpolate && root.multiplier > 1

        property var currentFrame: liveSource
        property var previousFrame: previousFrame

        property real blendFactor: root.blendFactor
        // The effect's own size. An attempt to feed the captured texture's
        // size instead regressed this to undefined (ShaderEffectSource does
        // not expose textureSize as a readable property here), which is worse
        // than the effect size, so it was reverted.
        property vector2d iResolution: Qt.vector2d(width, height)
        property int blockSize: root.blockSize
        property int searchRadius: root.searchRadius
        property real motionThreshold: root.motionThreshold
        property bool debugMode: root.debugMode
        property bool isOriginalFrame: root.isOriginalFrame
        property int frameCounter: root.frameCounter

        vertexShader: "../../../../shaders/interpol.vert.qsb"
        fragmentShader: "../../../../shaders/interpol.frag.qsb"
    }

    // ── Tint ──────────────────────────────────────────────────────
    //
    // Applied to a texture, not as an item layer. An item layer renders the
    // item into an FBO through the normal path and that does NOT capture
    // custom scene-graph nodes: putting palette.frag in a layer over the
    // VideoOutput produced literally nothing (proved with a solid-red
    // stand-in, which came back empty). This is why the tint never applied
    // to video wallpapers while static images were fine - an Image renders
    // normally, QSGVideoNode does not.
    //
    // liveSource is the same ShaderEffectSource the interpolator samples, and
    // that path is proven to carry video. So the tint is just palette.frag
    // fed with it. When interpolation is running the interpolator already
    // covers the screen, so the tint sits underneath and the interpolator
    // output is what shows - see ShaderEffect's own layering below.
    ShaderEffect {
        id: tintEffect
        anchors.fill: parent
        visible: root.tint && !root.shaderActive

        // palette.frag samples the frame through `source`. ShaderEffect has a
        // built-in `source` of type QUrl meant for image files, so it is
        // shadowed here with the captured texture - the same thing
        // UnifiedPanelEffect.qml does for its blur passes. Assigning to the
        // built-in one is a type error ("Cannot assign to non-existent
        // property source"), which is why this shadows rather than assigns.
        property var source: liveSource
        property var paletteTexture: paletteTextureSource
        property real paletteSize: root.optimizedPalette.length
        property real texWidth: width
        property real texHeight: height

        vertexShader: "../../../../shaders/palette.vert.qsb"
        fragmentShader: "../../../../shaders/palette.frag.qsb"
    }

    // Plain output when interpolation is off, so there is no capture cost.
    VideoOutput {
        id: videoNode
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        // Hidden while the effect is up, as NothingLess does, so the video is
        // not composited twice. The earlier black screen was the .qsb carrying
        // no GLSL, not this - hiding the node is fine now that the shader
        // actually compiles.
        //
        // NOTE: a reported zoom when interpolation is on is still open. A
        // side-by-side render of one instance with interpolation off and one
        // with it on cannot settle it - they are independent MediaPlayers at
        // different timestamps, so the two captures show different frames. The
        // next check has to compare the *same* frame with and without the
        // effect (seek both to one timestamp, or capture one instance twice).
        z: 0
        visible: !effect.visible
    }

    // ── Palette (tint) ────────────────────────────────────────────
    //
    // A 1-pixel-tall strip of the shell palette, uploaded once and read by
    // palette.frag as paletteTexture. Built as a Row of 1x1 rectangles rather
    // than drawn into a Canvas: it is static, so there is nothing to repaint
    // when the theme changes and the Row re-evaluates on its own.
    Item {
        id: paletteSourceItem
        // Must be visible: ShaderEffectSource captures the item's rendering,
        // and an item with opacity 0 renders nothing, so the palette texture
        // would come out empty and palette.frag would paint the wallpaper
        // black. Ambxst's static-image path spells this out too. It stays
        // invisible because ShaderEffectSource uses hideSource, not opacity.
        visible: true
        width: InterpolatedVideo.optimizedPalette.length
        height: 1
        // Parked far off-screen so it is never actually visible on the
        // desktop while still being rendered into the texture.
        x: -width - 10
        y: -height - 10

        Row {
            anchors.fill: parent
            Repeater {
                model: InterpolatedVideo.optimizedPalette
                Rectangle {
                    width: 1
                    height: 1
                    color: Colors[modelData]
                }
            }
        }
    }

    ShaderEffectSource {
        id: paletteTextureSource
        sourceItem: paletteSourceItem
        hideSource: true
        visible: false
        smooth: false
        recursive: false
    }

    // The tint is a layer effect on the VideoOutput, which is where Ambxst
    // put it. It cannot ride on the interpolation ShaderEffect instead: that
    // one already consumes two sampler bindings for the frame sources, and
    // palette.frag needs its own.
}