#!/bin/bash
# Build the launcher, install the bundle to ~/Applications (apps can't launch
# from an external SSD mounted "ignore ownership"), ad-hoc sign it there.
# The reader runs under /usr/bin/python3 and needs bleak:  /usr/bin/python3 -m pip install --user bleak
set -eu; cd "$(dirname "$0")"
DEST="$HOME/Applications/SnakeSensors.app"; mkdir -p "$HOME/Applications"
mkdir -p SnakeSensors.app/Contents/MacOS
cp Info.plist SnakeSensors.app/Contents/Info.plist          # bundle id + the Bluetooth usage description macOS insists on
cc -O2 -Wall -DREADER="\"$PWD/govee_reader.py\"" -o SnakeSensors.app/Contents/MacOS/SnakeSensors launcher.c
rm -rf "$DEST"; cp -R SnakeSensors.app "$DEST"
codesign --force --sign - "$DEST"
echo "installed + signed $DEST"
