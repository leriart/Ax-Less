#!/usr/bin/env bash
# Build the axvideo binary shipped with the mod.
#
# The Go backend of Ambxst is compiled into the ambxst binary and the mods
# system does not rebuild it, so anything needing Go has to travel as its own
# executable that the shell spawns - the same trick mcp/nothingclaw uses with
# its Python server.
set -euo pipefail
cd "$(dirname "$0")"
mkdir -p bin
CGO_ENABLED=1 go build -trimpath -ldflags "-s -w" -o bin/axvideo ./cmd/axvideo
echo "built: $(pwd)/bin/axvideo"
