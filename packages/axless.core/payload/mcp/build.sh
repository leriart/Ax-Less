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
# NOTE the path: from bridge/, ../scripts is mcp/scripts, but the manifest ships
# payload/scripts/mcp_stdio_bridge. Writing to the wrong directory meant this
# binary was never actually rebuilt - it stayed the old hand-built 4.4 MB
# artifact with the build machine's source path embedded, while the three
# servers were correctly trimmed and stripped.
(cd bridge && CGO_ENABLED=0 go build "${GOFLAGS_BUILD[@]}" -o ../../scripts/mcp_stdio_bridge .)

echo "==> vetting"
(cd nothingclaw-go && go vet ./... && go test ./...)

echo
echo "built:"
for b in nothingclaw/server openclaw/server opencode/server ../../scripts/mcp_stdio_bridge; do
    printf '  %10s  %s\n' "$(stat -c %s "$b" | numfmt --to=iec)" "$b"
done