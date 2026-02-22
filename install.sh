#!/bin/sh
set -e

DEST="${HOME}/.local/bin"
mkdir -p "$DEST"
cp cloard-board "$DEST/cloard-board"
chmod +x "$DEST/cloard-board"
echo "Installed cloard-board to $DEST/cloard-board"
echo "Make sure $DEST is in your PATH."
