#!/bin/sh
# Refresh the vendored macui kit (macui.lua, markdown.lua) from a kindle-ui checkout.
# usage: scripts/sync-kit.sh <kindle-ui checkout> [ref, default HEAD]
# The kit is linted and tested upstream, so make lint skips these two files.
set -eu
cd "$(dirname "$0")/.."
src=${1:?usage: scripts/sync-kit.sh <kindle-ui checkout> [ref]}
sha=$(git -C "$src" rev-parse "${2:-HEAD}")
for f in macui.lua markdown.lua; do
	{
		echo "-- Vendored from kindle-ui $sha:src/lib/$f by scripts/sync-kit.sh; edit it there, not here."
		git -C "$src" show "$sha:src/lib/$f"
	} >"plugin/kindlestories.koplugin/$f"
done
echo "kit at $sha"
