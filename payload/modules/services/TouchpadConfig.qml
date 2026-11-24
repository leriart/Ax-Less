pragma Singleton

import QtQuick
import Quickshell
import qs.modules.services

/*
    TouchpadConfig.qml

    Touchpad settings for niri.

    Why this touches a file
    -----------------------
    niri has no runtime interface for the touchpad: no `niri msg` verb, no
    keyword, and axctl does not expose it either (its vocabulary is gaps,
    border, opacity, blur). The settings live in the static KDL at
    ~/.config/niri/config.kdl and the only way to apply a change is to edit it
    and run `niri msg action load-config-file`.

    Editing a user's compositor config from a settings panel is invasive, so
    every write goes through a candidate first:

        build the new text -> write .ambxst-candidate.kdl -> niri validate it
        -> only if valid, write the real file and reload

    A malformed edit never reaches niri. The candidate lives in the same
    directory on purpose: niri resolves `include` paths relative to the config
    file, so validating anywhere else would fail on configs that use includes.

    Files are read and written through Process rather than FileView. A FileView
    assigned as a child of a singleton simply never loaded here, while Process
    created this way is the pattern the rest of the mod already relies on. The
    writer passes the whole document as a positional argument, never
    interpolated into the shell string, so its contents cannot escape.
*/
QtObject {
    id: root

    readonly property string dir: (Quickshell.env("XDG_CONFIG_HOME")
        || (Quickshell.env("HOME") + "/.config")) + "/niri"
    readonly property string mainPath: dir + "/config.kdl"
    readonly property string candidatePath: dir + "/.ambxst-candidate.kdl"

    // Only niri takes this path; Hyprland drives touchpad and gestures through
    // hyprctl keywords (see CompositorKeywords).
    readonly property bool supported: CompositorKeywords.compositor === "niri"

    property bool ready: false
    property string lastError: ""

    // Seeded from the existing block, then maintained here. niri cannot report
    // device state, so a change made outside this panel is not noticed.
    property bool tap: false
    property bool naturalScroll: false
    property bool middleEmulation: false
    property string clickMethod: "clickfinger"
    property string accelProfile: "adaptive"
    property real accelSpeed: 0.0

    property string _mainText: ""

    // ── Process plumbing (same shape as CompositorKeywords._run) ────────

    function _run(argv, onDone) {
        const args = argv.map(a => JSON.stringify(String(a))).join(", ");
        let proc;
        try {
            proc = Qt.createQmlObject(
                "import Quickshell\n"
                + "import Quickshell.Io\n"
                + "Process {\n"
                + "    command: [" + args + "]\n"
                + "    stdout: StdioCollector {}\n"
                + "    stderr: StdioCollector {}\n"
                + "}",
                root, "tpProc");
        } catch (e) {
            root.lastError = qsTr("Could not run a command");
            if (onDone)
                onDone(false, "", "");
            return;
        }
        proc.exited.connect(function (code) {
            let out = "", err = "";
            try {
                out = proc.stdout ? proc.stdout.text : "";
                err = proc.stderr ? proc.stderr.text : "";
            } catch (e) {}
            proc.destroy();
            if (onDone)
                onDone(code === 0, out, err);
        });
        proc.running = true;
    }

    // ── read ────────────────────────────────────────────────────────────

    function refresh() {
        // Deliberately not gated on `supported`: at Component.onCompleted the
        // compositor has not been detected yet, so a gate here meant the very
        // first read was skipped and `ready` never became true. If this is not
        // niri the cat simply fails and lastError is set; the UI hides anyway.
        _run(["cat", mainPath], function (ok, out, err) {
            root.ready = true;
            if (!ok) {
                root.lastError = (err || "").trim() || qsTr("Could not read the niri config");
                return;
            }
            root._mainText = out;
            root._seedFrom(out);
        });
    }

    function _seedFrom(text) {
        const block = _touchpadBlock(text);
        if (block === "")
            return;
        // Parse the primitives rather than trusting the defaults, so the panel
        // opens on the user's real settings.
        root.tap = /(^|\s)tap(\s|$)/.test(block);
        root.naturalScroll = /(^|\s)natural-scroll(\s|$)/.test(block);
        root.middleEmulation = /(^|\s)middle-emulation(\s|$)/.test(block);
        let m = block.match(/click-method\s+"?([a-z-]+)"?/);
        if (m)
            root.clickMethod = m[1];
        m = block.match(/accel-profile\s+"?([a-z-]+)"?/);
        if (m)
            root.accelProfile = m[1];
        m = block.match(/accel-speed\s+(-?[0-9.]+)/);
        if (m)
            root.accelSpeed = parseFloat(m[1]);
    }

    function _touchpadBlock(text) {
        const at = text.indexOf("touchpad {");
        if (at < 0)
            return "";
        const open = text.indexOf("{", at);
        let depth = 0;
        for (let i = open; i < text.length; i++) {
            if (text[i] === "{")
                depth++;
            else if (text[i] === "}") {
                depth--;
                if (depth === 0)
                    return text.slice(open + 1, i);
            }
        }
        return "";
    }

    function _render() {
        // niri's touchpad booleans are bare flags: `tap` is on, its absence
        // is off. `tap false` is a parse error, so a disabled flag is simply
        // not written. (dwt is deliberately absent: niri defaults it on and
        // has no `dwt false`, so it cannot be turned off from here.)
        let b = "touchpad {\n";
        if (tap)
            b += "        tap\n";
        if (naturalScroll)
            b += "        natural-scroll\n";
        if (middleEmulation)
            b += "        middle-emulation\n";
        b += "        click-method \"" + clickMethod + "\"\n";
        b += "        accel-profile \"" + accelProfile + "\"\n";
        b += "        accel-speed " + accelSpeed.toFixed(2) + "\n";
        b += "    }";
        return b;
    }

    // Find the `{ ... }` that closes the block whose opening brace is at `open`.
    function _closeOf(text, open) {
        let depth = 0;
        for (let i = open; i < text.length; i++) {
            if (text[i] === "{")
                depth++;
            else if (text[i] === "}") {
                depth--;
                if (depth === 0)
                    return i;
            }
        }
        return -1;
    }

    // ── write ───────────────────────────────────────────────────────────

    function set(key, value) {
        root[key] = value;
        _apply();
    }

    function _apply() {
        if (!supported || !root.ready || root._mainText === "")
            return;

        const at = root._mainText.indexOf("touchpad {");
        let next;
        if (at < 0) {
            const inputAt = root._mainText.indexOf("input {");
            if (inputAt < 0) {
                next = _render().replace(/^/gm, "    ").replace(/^/, "input {\n") + "\n}\n"
                    + root._mainText;
            } else {
                const close = _closeOf(root._mainText, root._mainText.indexOf("{", inputAt));
                if (close < 0) {
                    root.lastError = qsTr("Could not find the end of the input block");
                    return;
                }
                next = root._mainText.slice(0, close)
                    + "    " + _render().replace(/\n/g, "\n    ") + "\n"
                    + root._mainText.slice(close);
            }
        } else {
            const close = _closeOf(root._mainText, root._mainText.indexOf("{", at));
            if (close < 0) {
                root.lastError = qsTr("Could not find the end of the touchpad block");
                return;
            }
            next = root._mainText.slice(0, at) + _render() + root._mainText.slice(close + 1);
        }

        root.lastError = "";
        _write(candidatePath, next, function (ok) {
            if (!ok)
                return;
            _run(["niri", "validate", "-c", candidatePath], function (vok, vout, verr) {
                if (!vok) {
                    root.lastError = (verr || vout || "").trim() || qsTr("niri rejected the change");
                    return;
                }
                root._mainText = next;
                _write(mainPath, next, function (wok) {
                    if (!wok) {
                        root.lastError = qsTr("Could not write the niri config");
                        return;
                    }
                    _run(["niri", "msg", "action", "load-config-file"], function () {});
                });
            });
        });
    }

    // Write `text` to `path`. The document travels as a positional argument,
    // never interpolated into the shell string.
    function _write(path, text, onDone) {
        _run(["bash", "-c", "printf '%s' \"$1\" > \"$2\"", "axless", text, path], function (ok, out, err) {
            if (!ok)
                root.lastError = (err || "").trim();
            if (onDone)
                onDone(ok);
        });
    }

    Component.onCompleted: root.refresh()
}
