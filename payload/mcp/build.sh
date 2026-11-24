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

# Paths are given relative to this directory (payload/mcp). The manifest ships
# the stdio bridge as payload/scripts/mcp_stdio_bridge, which from here is
# ../scripts - NOT mcp/scripts. Getting that wrong silently left the shipped
# binary untouched, so it is spelled out once, here.
BRIDGE_OUT="../scripts/mcp_stdio_bridge"

GOFLAGS_BUILD=(-buildvcs=false -trimpath -ldflags "-s -w")
# -buildvcs=false matters here. These binaries are committed, and Go otherwise
# stamps each one with the git revision and a vcs.modified flag. Committing a
# binary dirties the tree, so the next build stamps vcs.modified=true, which
# changes the binary, which dirties the tree again: every rebuild produced a
# diff against an identical source tree. Turning VCS stamping off makes a
# rebuild of unchanged source byte-identical, and keeps the repository revision
# out of a shipped artifact.

echo "==> nothingclaw"
(cd nothingclaw-go && CGO_ENABLED=0 go build "${GOFLAGS_BUILD[@]}" -o ../nothingclaw/server .)

echo "==> openclaw bridge"
(cd openclaw && CGO_ENABLED=0 go build "${GOFLAGS_BUILD[@]}" -o ../openclaw/server .)

echo "==> opencode bridge"
(cd opencode-bridge && CGO_ENABLED=0 go build "${GOFLAGS_BUILD[@]}" -o ../opencode/server .)

echo "==> mcp stdio bridge"
# BRIDGE_OUT is relative to payload/mcp; the subshell is in payload/mcp/bridge,
# so one more .. is needed.
(cd bridge && CGO_ENABLED=0 go build "${GOFLAGS_BUILD[@]}" -o "../$BRIDGE_OUT" .)

echo "==> vetting"
(cd nothingclaw-go && go vet ./... && go test ./...)

echo
echo "built:"
for b in nothingclaw/server openclaw/server opencode/server "$BRIDGE_OUT"; do
    printf '  %10s  %s\n' "$(stat -c %s "$b" | numfmt --to=iec)" "$b"
done