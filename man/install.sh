#!/bin/bash
# Install roar's man page so `man roar` works.
#
# Default install is per-user (~/.local/share/man). Run with --system
# (sudo) to install to /usr/local/share/man instead.
#
# After install:
#     man roar           # opens the page
#     man -w roar        # prints the resolved path
#     export MANPATH     # users may need to add ~/.local/share/man if
#                          /etc/man.conf doesn't already pick it up.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_PAGE="$SCRIPT_DIR/roar.1"

if [[ ! -f "$SOURCE_PAGE" ]]; then
    echo "error: $SOURCE_PAGE not found." >&2
    exit 1
fi

case "${1:-}" in
    --system)
        DEST_DIR=/usr/local/share/man/man1
        ;;
    "")
        DEST_DIR="$HOME/.local/share/man/man1"
        ;;
    *)
        echo "usage: $0 [--system]" >&2
        exit 64
        ;;
esac

mkdir -p "$DEST_DIR"
cp "$SOURCE_PAGE" "$DEST_DIR/roar.1"
echo "installed $DEST_DIR/roar.1"

# Hint about MANPATH only for the per-user case — /usr/local/share/man
# is in the default man path on macOS and Linux.
if [[ "$DEST_DIR" == "$HOME"/* ]]; then
    if ! man -w roar >/dev/null 2>&1; then
        cat <<EOF

Note: \`man roar\` does not resolve yet. Add this to your shell rc:

    export MANPATH="\$HOME/.local/share/man:\${MANPATH:-}"

Then re-source the rc and try \`man roar\` again.
EOF
    fi
fi
