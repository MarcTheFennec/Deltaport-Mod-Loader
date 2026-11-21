#!/usr/bin/env bash
# deltaport (mod loader edition) - unofficial DELTARUNE Linux port
#
# This version NEVER modifies your original game files:
#   - the game data is COPIED (and patched) into ~/.local/share/DELTARUNE/deltaport
#   - music/videos are LINKED, not moved or renamed
#   - Deltarune mods can be installed in the 'mods/' folder and are applied
#     automatically on game launch (see modloader.sh)
#
# Usage:
#   ./port.sh             # port the game (interactive)
#   ./port.sh nxrune      # add the console borders mod to an existing port
#   ./port.sh steamcloud  # add Steam Cloud saves support

# NOTE: 'set -e pipefail' would clobber the positional parameters, so use -o.
set -e -o pipefail
set -E

ARGS="${1:-}"

SCRIPTDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# shellcheck source=lib.sh
source "$SCRIPTDIR/lib.sh"

DELTARUNEDIR=""
VERSION=""
STEAMCLOUD=0
NXRUNE_MOD=0

trap 'warn "WARNING: Script cancelled by user, port may be incomplete." && exit 1' SIGINT
trap 'error "An error occurred while running this script :("' ERR

# Check for dependencies
if [ ! -d "$HOME/.local/share/Steam" ]; then
    error "ERROR: You need to have Steam installed in order to run this script."
fi
"$SCRIPTDIR/deps.sh"

function steam_cloud_support {
    if [ "$STEAMCLOUD" = "1" ]; then
        log "Adding Steam Cloud support..."
        # Needed for the symlink to work
        mkdir -p "$HOME/.config/DELTARUNE"
        # NOTE: From my observations, Steam Cloud seems to create this directory
        # automatically when syncing saves, but just to make sure:
        mkdir -p "$HOME/.local/share/Steam/steamapps/compatdata/1671210/pfx/drive_c/users/steamuser/Local Settings/Application Data"
        # NOTE 2: Other directory where saves are also stored
        mkdir -p "$HOME/.local/share/Steam/steamapps/compatdata/1671210/pfx/drive_c/users/steamuser/AppData/Local/"
        cd "$HOME/.local/share/Steam/steamapps/compatdata/1671210/pfx/drive_c/users/steamuser/Local Settings/Application Data"
        if [ -d "DELTARUNE" ]; then
            rm -r "DELTARUNE"
        fi
        ln -s "$HOME/.config/DELTARUNE" "DELTARUNE"
        cd "$HOME/.local/share/Steam/steamapps/compatdata/1671210/pfx/drive_c/users/steamuser/AppData/Local"
        if [ -d "DELTARUNE" ]; then
            rm -r "DELTARUNE"
        fi
        ln -s "$HOME/.config/DELTARUNE" "DELTARUNE"
        log "Steam Cloud support added! Please try not deleting the '.config/DELTARUNE' folder before running the game as it may break things."
    fi
    return 0
}

# Older deltaport versions ported the game in-place (files renamed/moved inside
# the game folder). This version needs the game in its original state.
function check_old_port {
    if [ -f "$DELTARUNEDIR/DELTARUNE.sh" ] && [ ! -f "$DELTARUNEDIR/data.win" ] && [ -f "$DELTARUNEDIR/assets/game.unx" ]; then
        error "This game folder was ported in-place by an older version of deltaport (its files were renamed/moved inside it).
This version keeps your original game files untouched, so it needs the game in its ORIGINAL state.
To migrate: restore the original game files (re-download the game files - see the 'Other versions' section of the README, or re-install the game) and run this script again."
    fi
    return 0
}

function check_version {
    VERSION="$(detect_version "$DELTARUNEDIR/data.win")"
    return 0
}

function confirm() {
    # confirm <prompt>  -> exits the script unless the user answers y
    local prompt="$1" yn
    while true; do
        read -r -p "$prompt" yn
        case "$yn" in
            [Yy]*) return 0 ;;
            [Nn]*) exit 1 ;;
            *) exit 1 ;;
        esac
    done
}

function install_scripts_in_place {
    # Make the deltaport directory self-contained so the port keeps working
    # even if the release folder you extracted gets deleted.
    # (Skip when already running from the deltaport directory itself.)
    mkdir -p "$DELTAPORTDIR"
    if [ "$SCRIPTDIR" != "$DELTAPORTDIR" ]; then
        cp "$SCRIPTDIR/port.sh" "$SCRIPTDIR/update.sh" "$SCRIPTDIR/deps.sh" \
            "$SCRIPTDIR/modloader.sh" "$SCRIPTDIR/DELTARUNE.sh" "$SCRIPTDIR/lib.sh" \
            "$SCRIPTDIR/launcher.sh" "$SCRIPTDIR/mod-index.json" \
            "$DELTAPORTDIR/"
        cp "$SCRIPTDIR/deltarune" "${DELTAPORTDIR:?}/"
        cp "$SCRIPTDIR/icon.png" "${DELTAPORTDIR:?}/"
        rm -rf "${DELTAPORTDIR:?}/files"
        cp -r "$SCRIPTDIR/files" "$DELTAPORTDIR/"
        # Ubuntu/Debian: carry over the static FFmpeg4 libraries (if deps.sh
        # downloaded them) so video playback works.
        if [ -f "$SCRIPTDIR/.ubuntu" ]; then
            cp "$SCRIPTDIR/.ubuntu" "$DELTAPORTDIR/"
            rm -rf "${DELTAPORTDIR:?}/lib"
            cp -r "$SCRIPTDIR/lib" "$DELTAPORTDIR/"
        fi
    fi
    chmod +x "$DELTAPORTDIR/"*.sh "$DELTAPORTDIR/deltarune"
    return 0
}

function port_game {
    check_old_port

    if [ -d "$BASEDIR" ]; then
        local old_gamedir
        old_gamedir="$(cat "$DELTAPORTDIR/.gamedir" 2> /dev/null || true)"
        if [ "$old_gamedir" = "$DELTARUNEDIR" ] && [ -f "$DELTARUNEDIR/data.win" ]; then
            log "Found an existing deltaport installation for this game, with updated game data (data.win present)."
            log "Updating keeps your installed mods."
            confirm "Update the port to the latest supported version? [y/n]: "
            "$DELTAPORTDIR/update.sh" "$DELTARUNEDIR"
            exit 0
        fi
        warn "A deltaport installation already exists at $DELTAPORTDIR."
        confirm "Rebuild the port from scratch? (Your installed mods in mods/ will be kept) [y/n]: "
    fi

    log "Detecting game version..."
    check_version

    if [ -z "$VERSION" ]; then
        warn "WARNING: data.win checksum does not match any supported version (0.0.247, 0.0.250, 0.0.253)."
        warn "You may have a corrupted or unsupported game."
        confirm "Continue anyway, using the latest available patches ($LATEST_VERSION)? [y/n]: "
        log "Using patches for version $LATEST_VERSION"
        VERSION="$LATEST_VERSION"
    else
        log "Detected version $VERSION"
    fi

    log "Using game directory: $DELTARUNEDIR (it will NOT be modified)"

    install_scripts_in_place
    build_base "$DELTARUNEDIR" "$VERSION"
    install_mods_readme

    if [ "$VERSION" = "$LATEST_VERSION" ]; then
        local yn
        while true; do
            read -r -p "$(log 'Optionally install the Console Borders mod (nxrune)? [y/n]: ')" yn
            case "$yn" in
                [Yy]*) NXRUNE_MOD=1; break ;;
                [Nn]*) log "If you change your mind, run './port.sh nxrune' to add it!!"; break ;;
                *) break ;;
            esac
        done
    fi

    if [ "$NXRUNE_MOD" = "1" ]; then
        install_nxrune_mod
    fi

    local yn
    while true; do
        read -r -p "$(log 'Optionally add Steam Cloud saves support? [y/n]: ')" yn
        case "$yn" in
            [Yy]*) STEAMCLOUD=1; break ;;
            [Nn]*) break ;;
            *) break ;;
        esac
    done

    steam_cloud_support

    log "Building the working tree (applying your mods)..."
    "$DELTAPORTDIR/modloader.sh" rebuild

    echo -e "\e[1;32m SUCCESS! The port is ready. Your original game files were left untouched. \e[0m"
    log "To play DELTARUNE through Steam, add this to the game's Launch Options (DELTARUNE -> Properties -> Launch Options):"
    log "  $DELTAPORTDIR/DELTARUNE.sh -- %command%"
    log "Or, you can run it directly in a terminal:"
    log "  $DELTAPORTDIR/DELTARUNE.sh"
    log "To manage mods, use: $DELTAPORTDIR/modloader.sh (mods live in $MODSDIR)"
    log "For updates on Steam, run this script again (or $DELTAPORTDIR/update.sh) to update the port."
    log "Thanks for using this project and have fun!"
    exit 0
}

function select_dir {
    echo ""
    log "Please type the path of DELTARUNE below (eg. /home/pug/.local/share/Steam/steamapps/common/DELTARUNE):"
    read -r path

    if [ -z "$path" ]; then
        select_dir
    fi

    if [ ! -d "$path" ]; then
        warn "Directory doesn't exist, please try again"
        select_dir
    fi

    if [ ! -f "$path/data.win" ] && [ ! -f "$path/assets/game.unx" ]; then
        warn "Unable to find game data (data.win/game.unx) at directory, please try again."
        select_dir
    fi

    DELTARUNEDIR="${path%/}"
    port_game
}

function find_deltarune_dir {
    if [ -d "$HOME/.local/share/Steam/steamapps/common/DELTARUNE" ]; then
        DELTARUNEDIR="$HOME/.local/share/Steam/steamapps/common/DELTARUNE"
        log "Detected deltarune directory at $DELTARUNEDIR."
        local yn
        while true; do
            read -r -p "Is this correct? [y/n]: " yn
            case "$yn" in
                [Yy]*) port_game; break ;;
                [Nn]*) select_dir; break ;;
                *) select_dir; break ;;
            esac
        done
    else
        select_dir
    fi
}

if [ "$ARGS" = "nxrune" ]; then
    if [ ! -d "$BASEDIR" ]; then
        warn "No deltaport installation found yet - run './port.sh' first, then run './port.sh nxrune'."
        exit 1
    fi
    if [ ! -d "$DELTAPORTDIR/files/patches/nxrune" ]; then
        error "The nxrune patches were not found next to this script - they ship with the release files/patches/nxrune/."
    fi
    log "Installing the Console Borders mod (nxrune)..."
    install_nxrune_mod
    log "Rebuilding the working tree..."
    "$DELTAPORTDIR/modloader.sh" rebuild
    echo -e "\e[1;32m SUCCESS! Borders mod applied. Launch the game with: $DELTAPORTDIR/DELTARUNE.sh \e[0m"
    exit 0
fi

if [ "$ARGS" = "steamcloud" ]; then
    STEAMCLOUD=1
    steam_cloud_support
    exit 0
fi

log "Welcome to the unofficial DELTARUNE Linux port (mod loader edition)."
log "This is the port for version(s): 0.0.247, 0.0.250, 0.0.253"
log "You will need to bring your own game files, as none of them are included here."
log "Your original game files are NEVER modified: the port is installed in $DELTAPORTDIR"
echo ""

find_deltarune_dir
