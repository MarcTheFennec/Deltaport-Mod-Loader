#!/usr/bin/env bash
# deltaport - update the ported game data to a new version.
#
# Your ORIGINAL game files are never modified: the new data.win files are
# COPIED into the deltaport directory, re-patched, and the working tree is
# rebuilt. Installed mods are kept as-is (they may need author updates for
# the new game version).
#
# Usage:
#   ./update.sh                # uses the game folder stored at port time
#   ./update.sh <game dir>     # or specify the DELTARUNE directory explicitly

# NOTE: 'set -e pipefail' would clobber the positional parameters, so use -o.
set -e -o pipefail
set -E

DELTARUNEDIR="${1:-}"

SCRIPTDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# shellcheck source=lib.sh
source "$SCRIPTDIR/lib.sh"

trap 'warn "WARNING: Script cancelled by user, update may be incomplete." && exit 1' SIGINT
trap 'error "An error occurred while running this script :("' ERR

if [ ! -d "$BASEDIR" ]; then
    error "No deltaport installation found at $DELTAPORTDIR - run port.sh first."
fi

if [ -z "$DELTARUNEDIR" ] || [ ! -d "$DELTARUNEDIR" ]; then
    DELTARUNEDIR="$(cat "$DELTAPORTDIR/.gamedir" 2> /dev/null || true)"
fi

if [ -z "$DELTARUNEDIR" ] || [ ! -d "$DELTARUNEDIR" ]; then
    error "ERROR: DELTARUNE directory not found. Usage: ./update.sh <deltarune directory>"
fi

if [ ! -f "$DELTARUNEDIR/data.win" ]; then
    error "ERROR: data.win not found at $DELTARUNEDIR - is the game updated and in its original state?"
fi

if game_is_running; then
    error "DELTARUNE appears to be running - close the game before updating."
fi

log "Updating your deltaport installation (your original game files are never touched)"
log "This only updates the game data, not external files (unlikely for those to change anyway)"

log "Detecting updated game version..."
NEW_VERSION="$(detect_version "$DELTARUNEDIR/data.win")"

if [ -z "$NEW_VERSION" ]; then
    error "ERROR: Unsupported game version or unable to detect it (supported: 0.0.247, 0.0.250, 0.0.253). Check the supported versions list, or you may have corrupted game files."
fi

CURRENT_VERSION="$(grep '^version=' "$BASEDIR/.stamp" 2> /dev/null | cut -d '=' -f 2 || true)"

if [ "$NEW_VERSION" = "$CURRENT_VERSION" ]; then
    log "Your port is already on version $NEW_VERSION - nothing to do."
    exit 0
fi

log "Detected updated version: $NEW_VERSION (currently ported: ${CURRENT_VERSION:-unknown})"

if [ ! -d "$DELTARUNEDIR/chapter5_windows" ]; then
    warn "WARNING: Chapter 5 not found. You cannot update from a version below v0.0.240 (Chapter 5 release version)! (Versions with new chapters require a reinstall) You will most likely encounter issues."
    while true; do
        read -r -p "Continue anyway? [y/n]: " yn
        case "$yn" in
            [Yy]*) break ;;
            [Nn]*) exit 1 ;;
            *) exit 1 ;;
        esac
    done
fi

log "Using directory: $DELTARUNEDIR"

echo "$DELTARUNEDIR" > "$DELTAPORTDIR/.gamedir"

log "Copying updated game data into the deltaport directory..."
cp "$DELTARUNEDIR/data.win" "$BASEDIR/assets/game.unx"
for ((i = 1; i <= CHAPTERS; i++)); do
    if [ -f "$DELTARUNEDIR/chapter${i}_windows/data.win" ]; then
        if [ -d "$BASEDIR/chapter${i}_linux" ]; then
            cp "$DELTARUNEDIR/chapter${i}_windows/data.win" "$BASEDIR/chapter${i}_linux/assets/game.unx"
        else
            warn "WARNING: Chapter $i data found in the game but not in the port. A new chapter likely appeared - a full re-port (./port.sh) is recommended."
        fi
    fi
done

log "Re-linking game assets (in case the update added or renamed files)..."
relink_assets "$DELTARUNEDIR"

log "Patching game files for version $NEW_VERSION..."
apply_base_patches "$NEW_VERSION"

write_base_stamp "$NEW_VERSION" "$DELTARUNEDIR"

warn "NOTE: your installed mods ($MODSDIR) were kept. If a mod misbehaves after a game update, its author needs to publish an update for version $NEW_VERSION."

log "Rebuilding the working tree..."
"$DELTAPORTDIR/modloader.sh" rebuild

echo -e "\e[1;32m SUCCESS! Game data successfully updated. \e[0m"
log "Updated to version $NEW_VERSION"
log "Thanks for using deltaport, have fun!"
exit 0
