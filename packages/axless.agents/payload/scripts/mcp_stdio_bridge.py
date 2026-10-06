#!/usr/bin/env python3
"""
MCP stdio bridge for Ambxst.

Usage:
    python3 mcp_stdio_bridge.py -- <command> [args...]

Spawns a Model Context Protocol server over stdio, exposes its
stdin as a per-instance FIFO so the QML client (which has no
direct stdin access) can feed it JSON-RPC messages.

Protocol with the QML side
==========================
On startup the bridge writes a single line to its stdout:

    __FIFO__:/tmp/ambxst-mcp-<pid>-<rand>.in

Then every line the MCP server prints to its stdout is forwarded
verbatim to the bridge's stdout. Stderr lines are wrapped into
`notifications/message` JSON-RPC objects so the QML side can
display them as agent diagnostics.

The QML side writes JSON-RPC messages (one per line) to the FIFO
path; the bridge forwards them directly to the MCP server's stdin.

Lifecycle
=========
* The bridge exits when the MCP server exits, when stdin closes,
  or on SIGTERM/SIGINT.
* The FIFO is unlinked on shutdown.
"""

import json
import os
import signal
import subprocess
import sys
import tempfile
import threading
import time


def _eprint(msg):
    sys.stderr.write(f"[mcp_stdio_bridge] {msg}\n")
    sys.stderr.flush()


def _emit_meta(payload):
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def main():
    if "--" not in sys.argv:
        _emit_meta({
            "jsonrpc": "2.0",
            "method": "notifications/message",
            "params": {"level": "error", "data": "Usage: mcp_stdio_bridge.py -- <command> [args...]"},
        })
        sys.exit(2)

    split = sys.argv.index("--")
    cmd = sys.argv[split + 1]
    args = sys.argv[split + 2:]

    # Per-instance FIFO. QML writes to this; we forward to the MCP
    # server's stdin. We create it in /tmp because /run/user is not
    # always writable from the Quickshell sandbox.
    fifo_dir = tempfile.mkdtemp(prefix="ambxst-mcp-", dir="/tmp")
    fifo_path = os.path.join(fifo_dir, "in.fifo")
    try:
        os.mkfifo(fifo_path, 0o600)
    except FileExistsError:
        pass
    except OSError as e:
        _emit_meta({
            "jsonrpc": "2.0",
            "method": "notifications/message",
            "params": {"level": "error",
                       "data": f"Failed to create FIFO: {e}"},
        })
        sys.exit(1)

    # Announce the FIFO path before we spawn the server, so the
    # QML side can start queuing writes immediately. We use a
    # well-known prefix so the QML parser can distinguish it from
    # genuine MCP traffic.
    sys.stdout.write(f"__FIFO__:{fifo_path}\n")
    sys.stdout.flush()

    env = os.environ.copy()

    try:
        proc = subprocess.Popen(
            [cmd] + args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            env=env,
            bufsize=1,
        )
    except FileNotFoundError as e:
        _emit_meta({
            "jsonrpc": "2.0",
            "method": "notifications/message",
            "params": {"level": "error",
                       "data": f"Could not spawn MCP server: {e}"},
        })
        _cleanup(fifo_path, fifo_dir, None)
        sys.exit(1)

    shutdown_requested = threading.Event()

    def _on_signal(*_):
        shutdown_requested.set()
        try:
            proc.terminate()
        except Exception:
            pass

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    def forward_stdout():
        try:
            assert proc.stdout is not None
            for line in proc.stdout:
                sys.stdout.write(line)
                sys.stdout.flush()
        except Exception as e:
            _eprint(f"stdout forwarder error: {e}")

    def forward_stderr():
        try:
            assert proc.stderr is not None
            for line in proc.stderr:
                text = line.rstrip("\n")
                if not text:
                    continue
                # Wrap stderr lines as JSON-RPC notifications so the
                # QML client can render them as agent diagnostics
                # without losing track of message boundaries.
                payload = {
                    "jsonrpc": "2.0",
                    "method": "notifications/message",
                    "params": {"level": "info", "data": text},
                }
                sys.stdout.write(json.dumps(payload) + "\n")
                sys.stdout.flush()
        except Exception as e:
            _eprint(f"stderr forwarder error: {e}")

    def forward_fifo():
        # Open the FIFO in read mode; this blocks until the QML
        # writer opens it. We use a small read loop so we can shut
        # down promptly when the server exits.
        while not shutdown_requested.is_set():
            try:
                with open(fifo_path, "r") as fifo:
                    for line in fifo:
                        if shutdown_requested.is_set():
                            return
                        if not proc.stdin or proc.poll() is not None:
                            return
                        try:
                            proc.stdin.write(line if line.endswith("\n") else line + "\n")
                            proc.stdin.flush()
                        except (BrokenPipeError, ValueError):
                            return
            except FileNotFoundError:
                # FIFO removed; nothing more to do.
                return
            except Exception as e:
                _eprint(f"fifo forwarder error: {e}")
                time.sleep(0.05)

    t_out = threading.Thread(target=forward_stdout, daemon=True)
    t_err = threading.Thread(target=forward_stderr, daemon=True)
    t_fifo = threading.Thread(target=forward_fifo, daemon=True)
    t_out.start()
    t_err.start()
    t_fifo.start()

    try:
        rc = proc.wait()
    except KeyboardInterrupt:
        rc = 130
    finally:
        shutdown_requested.set()
        _cleanup(fifo_path, fifo_dir, proc)

    sys.exit(rc if rc is not None else 0)


def _cleanup(fifo_path, fifo_dir, proc):
    try:
        if proc is not None:
            if proc.stdin:
                try:
                    proc.stdin.close()
                except Exception:
                    pass
            if proc.poll() is None:
                try:
                    proc.terminate()
                    proc.wait(timeout=1.5)
                except Exception:
                    try:
                        proc.kill()
                    except Exception:
                        pass
    except Exception:
        pass
    try:
        if fifo_path and os.path.exists(fifo_path):
            os.unlink(fifo_path)
    except Exception:
        pass
    try:
        if fifo_dir and os.path.isdir(fifo_dir):
            os.rmdir(fifo_dir)
    except Exception:
        pass


if __name__ == "__main__":
    main()
