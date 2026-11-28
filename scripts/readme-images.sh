#!/bin/sh
# Frames the demo-data renders from `make screenshots` and copies them to the README image folder.
# Usage: scripts/readme-images.sh <render dir> <image dir>
set -eu

src=$1
dst=$2
names=""
for screen in overview popover keepawake weekly-report cleanup space-lens activity system; do
    names="$names $screen-dark $screen-light"
done

# shellcheck disable=SC2086 # word splitting is intended
swift "$(dirname "$0")/frame-screenshot.swift" "$src" "$dst" $names
cp Osin/Resources/Assets.xcassets/AppIcon.appiconset/icon_128x128@2x.png "$dst/icon.png"
du -sh "$dst"
