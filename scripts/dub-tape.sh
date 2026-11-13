#!/bin/zsh
# Makes a cassette out of audio files and puts it on the desk.
#
#   ./scripts/dub-tape.sh <folder> [<folder to keep the proof in>]
#
# <folder> holds the audio (48 kHz, anything macOS can read) and an
# order.json saying what goes on which track. See "Dubbing a cassette from
# stems" in docs/x26-reference.md.
#
# The X-2026 in /Applications does the recording, with no window, in a work
# folder of its own. Only the finished cassette is then moved onto the desk:
# no other cassette and no setting is touched. It is there the next time the
# app starts.

set -euo pipefail

APP="/Applications/X2026.app/Contents/MacOS/X2026"
CONTAINER="$HOME/Library/Containers/se.mickekring.X2026/Data"
TAPES="$CONTAINER/Library/Application Support/Tapes"

ORDER="${1:?usage: dub-tape.sh <folder with the audio and order.json> [<folder for the proof>]}"
PROOF="${2:-}"

if [[ ! -f "$ORDER/order.json" ]]; then
    echo "There is no order.json in $ORDER" >&2
    exit 1
fi
if [[ ! -x "$APP" ]]; then
    echo "The X-2026 is not in /Applications. Run scripts/install.sh first." >&2
    exit 1
fi
if [[ ! -d "$TAPES" ]]; then
    echo "The X-2026 has never been started here, so it has no desk yet. Start it once." >&2
    exit 1
fi

# The app is sandboxed: it can only read what lies inside its own container.
WORK="$CONTAINER/tmp/dub-$$"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT
cp "$ORDER"/*(.) "$WORK/"

echo "Recording…"
"$APP" --dub-tape "$WORK" 2>/dev/null | sed -n 's/^\[dub\] /  /p'

packages=( "$WORK"/cassette/*.x2026tape(N/) )
if (( ${#packages} != 1 )); then
    echo "No cassette came out of it." >&2
    exit 1
fi
package="${packages[1]}"
if [[ ! -f "$package/label.json" || ! -f "$package/oxide.pcm" ]]; then
    echo "The cassette is incomplete; leaving the desk alone." >&2
    exit 1
fi
if [[ -e "$TAPES/${package:t}" ]]; then
    echo "A cassette with that serial is already on the desk; leaving it alone." >&2
    exit 1
fi

if [[ -n "$PROOF" ]]; then
    mkdir -p "$PROOF"
    mv "$WORK"/proof/* "$PROOF/"
    echo "What went in and what the machine plays back: $PROOF"
fi

mv -n "$package" "$TAPES/"
echo "The cassette is on the desk. It is there the next time the X-2026 starts."
