import QtQuick
import QtQuick.Controls
import QtMultimedia
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
    property alias tintSource: paletteSourceItem

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

    function restart() {
        if (!sourceFile)
            return;
        player.stop();
        player.source = "file://" + sourceFile;
        playIfNeeded();
    }

    function playIfNeeded() {
        if (!sourceFile)
            return;
        if (player.playbackState !== MediaPlayer.PlayingState)
            player.play();
    }

    onSourceFileChanged: restart()

    onInterpolateChanged: {
        if (interpolate && multiplier > 1) {
            previousFrame.scheduleUpdate();
            lastCaptureTime = Date.now();
            captureTimer.restart();
            blendAnimation.running = true;
        } else {
            captureTimer.stop();
            blendAnimation.running = false;
            // Reset so switching interpolation back on does not start from a
            // stale blendFactor and show a single garbage frame.
            blendFactor = 0;
            isOriginalFrame = true;
        }
    }

    onMultiplierChanged: {
        if (!interpolate || multiplier <= 1) {
            captureTimer.stop();
            blendAnimation.running = false;
        } else {
            captureTimer.restart();
            blendAnimation.running = true;
        }
    }

    Component.onCompleted: restart()

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
        sourceItem: root.interpolate && root.multiplier > 1 ? videoNode : null
        live: root.interpolate && root.multiplier > 1
        hideSource: true
        smooth: true
        visible: false
    }

    // ── The previous source frame, frozen ─────────────────────────
    ShaderEffectSource {
        id: previousFrame
        sourceItem: root.interpolate && root.multiplier > 1 ? videoNode : null
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
        visible: root.interpolate && root.multiplier > 1

        property var currentFrame: liveSource
        property var previousFrame: previousFrame

        property real blendFactor: root.blendFactor
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

    // Plain output when interpolation is off, so there is no capture cost.
    VideoOutput {
        id: videoNode
        anchors.fill: parent
        fillMode: VideoOutput.PreserveAspectCrop
        visible: !effect.visible
    }

    // ── Palette (tint) ────────────────────────────────────────────
    Item {
        id: paletteSourceItem
        visible: false
    }
}