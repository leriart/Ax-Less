// Command mcp_stdio_bridge is the Go port of the mod's Python stdio bridge.
//
// It runs a Model Context Protocol server over stdio and exposes the server's
// stdin as a per-instance FIFO, because the QML client cannot write to a child
// process's stdin directly.
//
// Protocol with the QML side
//
//	On startup one line is written to stdout:
//	    __FIFO__:/tmp/ambxst-mcp-<rand>/in.fifo
//	Every line the server prints to stdout is forwarded verbatim to stdout.
//	Stderr lines are wrapped into notifications/message JSON-RPC objects so the
//	shell can show them as agent diagnostics.
//	The QML side writes one JSON-RPC message per line to the FIFO; the bridge
//	forwards them to the server's stdin.
//
// It exits when the server exits, when stdin closes or on SIGTERM/SIGINT, and
// removes the FIFO on the way out.
//
// Standard library only.
package main

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"sync"
	"syscall"
	"time"
)

func eprint(msg string) {
	fmt.Fprintf(os.Stderr, "[mcp_stdio_bridge] %s\n", msg)
}

func emitMeta(level, data string) {
	payload := map[string]any{
		"jsonrpc": "2.0",
		"method":  "notifications/message",
		"params":  map[string]any{"level": level, "data": data},
	}
	enc, err := json.Marshal(payload)
	if err != nil {
		return
	}
	fmt.Fprintf(os.Stdout, "%s\n", enc)
	_ = os.Stdout.Sync()
}

func main() {
	os.Exit(run())
}

func run() int {
	// Split on "--" so the bridge's own flags never collide with the server's.
	sep := -1
	for i, a := range os.Args[1:] {
		if a == "--" {
			sep = i + 1
			break
		}
	}
	if sep == -1 || sep+1 >= len(os.Args) {
		emitMeta("error", "Usage: mcp_stdio_bridge -- <command> [args...]")
		return 2
	}
	name := os.Args[sep+1]
	args := os.Args[sep+2:]

	// Per-instance FIFO. /tmp rather than /run/user because that is not always
	// writable from the shell's sandbox.
	dir, err := os.MkdirTemp("/tmp", "ambxst-mcp-")
	if err != nil {
		emitMeta("error", fmt.Sprintf("Failed to create temp dir: %v", err))
		return 1
	}
	fifoPath := filepath.Join(dir, "in.fifo")
	if err := syscall.Mkfifo(fifoPath, 0o600); err != nil && !os.IsExist(err) {
		emitMeta("error", fmt.Sprintf("Failed to create FIFO: %v", err))
		return 1
	}

	// Announce the FIFO before spawning, so the client can start queuing.
	fmt.Fprintf(os.Stdout, "__FIFO__:%s\n", fifoPath)
	_ = os.Stdout.Sync()

	cmd := exec.Command(name, args...)
	stdin, err := cmd.StdinPipe()
	if err != nil {
		emitMeta("error", fmt.Sprintf("Could not open server stdin: %v", err))
		cleanup(fifoPath, dir, nil)
		return 1
	}
	stdout, err := cmd.StdoutPipe()
	if err != nil {
		emitMeta("error", fmt.Sprintf("Could not open server stdout: %v", err))
		cleanup(fifoPath, dir, nil)
		return 1
	}
	stderr, err := cmd.StderrPipe()
	if err != nil {
		emitMeta("error", fmt.Sprintf("Could not open server stderr: %v", err))
		cleanup(fifoPath, dir, nil)
		return 1
	}
	if err := cmd.Start(); err != nil {
		emitMeta("error", fmt.Sprintf("Could not spawn MCP server: %v", err))
		cleanup(fifoPath, dir, nil)
		return 1
	}

	var stopOnce sync.Once
	stop := func() { stopOnce.Do(func() { _ = cmd.Process.Kill() }) }

	sigs := make(chan os.Signal, 1)
	signal.Notify(sigs, syscall.SIGTERM, syscall.SIGINT)
	go func() {
		<-sigs
		_ = cmd.Process.Signal(syscall.SIGTERM)
	}()

	var outWG sync.WaitGroup
	outWG.Add(2)

	// Server stdout -> our stdout, verbatim.
	go func() {
		defer outWG.Done()
		sc := bufio.NewScanner(stdout)
		sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
		for sc.Scan() {
			fmt.Fprintf(os.Stdout, "%s\n", sc.Bytes())
		}
		_ = os.Stdout.Sync()
	}()

	// Server stderr -> notifications/message, so the shell can show it.
	go func() {
		defer outWG.Done()
		sc := bufio.NewScanner(stderr)
		sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
		for sc.Scan() {
			line := sc.Text()
			if line == "" {
				continue
			}
			emitMeta("info", line)
		}
	}()

	// FIFO -> server stdin.
	go func() {
		for {
			// Blocks until a writer opens the FIFO.
			f, err := os.OpenFile(fifoPath, os.O_RDONLY, 0)
			if err != nil {
				if os.IsNotExist(err) {
					return
				}
				eprint(fmt.Sprintf("fifo forwarder error: %v", err))
				time.Sleep(50 * time.Millisecond)
				continue
			}
			sc := bufio.NewScanner(f)
			sc.Buffer(make([]byte, 0, 64*1024), 8*1024*1024)
			for sc.Scan() {
				if _, err := io.WriteString(stdin, sc.Text()+"\n"); err != nil {
					_ = f.Close()
					return
				}
			}
			_ = f.Close()
			// If the server is gone, stop looping.
			if cmd.ProcessState != nil {
				return
			}
		}
	}()

	rc := 0
	if err := cmd.Wait(); err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			rc = ee.ExitCode()
		} else {
			rc = 1
		}
	}

	stop()
	cleanup(fifoPath, dir, cmd)
	outWG.Wait()
	return rc
}

func cleanup(fifoPath, dir string, cmd *exec.Cmd) {
	if cmd != nil && cmd.Process != nil {
		_ = cmd.Process.Signal(syscall.SIGTERM)
	}
	_ = os.Remove(fifoPath)
	_ = os.Remove(dir)
}
