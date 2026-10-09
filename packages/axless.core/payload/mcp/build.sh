#!/usr/bin/env bash
# Build the Go binaries shipped with the mod.
#
# Ambxst's mods system does not rebuild anything a package ships, so every Go
# component has to travel as its own executable that the shell spawns.
#
# The flags matter for shipped size. These were previously built with a bare
# `go build`, which left debug info in (12.1 MB for nothingclaw) and linked
# them dynamically against the host loader, so they would not run on a machine
# without a matching glibc. CGO_ENABLED=0 plus -trimpath -s -w makes each one
# static and stripped.
#
# Run this after changing anything under mcp/, and commit the result: the
# binaries are what actually ships.
set -euo pipefail
cd "$(dirname "$0")"

GOFLAGS_BUILD=(-trimpath -ldflags "-s -w")

echo "==> nothingclaw"
(cd nothingclaw-go && CGO_ENABLED=0 go build "${GOFLAGS_BUILD[@]}" -o ../nothingclaw/server .)

echo "==> openclaw bridge"
(cd openclaw && CGO_ENABLED=0 go build "${GOFLAGS_BUILD[@]}" -o ../openclaw/server .)

echo "==> opencode bridge"
(cd opencode-bridge && CGO_ENABLED=0 go build "${GOFLAGS_BUILD[@]}" -o ../opencode/server .)

echo "==> mcp stdio bridge"
(cd bridge && CGO_ENABLED=0 go build "${GOFLAGS_BUILD[@]}" -o ../scripts/mcp_stdio_bridge .)

echo "==> vetting"
(cd nothingclaw-go && go vet ./... && go test ./...)

echo
echo "built:"
for b in nothingclaw/server openclaw/server opencode/server ../scripts/mcp_stdio_bridge; do
    printf '  %10s  %s\n' "$(stat -c %s "$b" | numfmt --to=iec)" "$b"
done