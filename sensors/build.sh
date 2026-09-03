#!/bin/bash
# Build the launcher, install the bundle to ~/Applications (apps can't launch
# from this SSD: it's mounted "ignore ownership"), ad-hoc sign it there.
set -eu; cd "$(dirname "$0")"
DEST="$HOME/Applications/SnakeSensors.app"; mkdir -p "$HOME/Applications"
cc -O2 -Wall -DREADER="\"$PWD/govee_reader.py\"" -o SnakeSensors.app/Contents/MacOS/SnakeSensors launcher.c
rm -rf "$DEST"; cp -R SnakeSensors.app "$DEST"
codesign --force --sign - "$DEST"
echo "installed + signed $DEST"
