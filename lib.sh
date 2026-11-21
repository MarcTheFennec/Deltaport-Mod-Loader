#!/usr/bin/env bash
# deltaport - shared library used by port.sh, update.sh and modloader.sh.
#
# This file is meant to be SOURCED, not executed directly. It relies on the
# sourcing script using `set -e` (errexit) semantics.
#
# Architecture (this fork keeps the original game files untouched):
#   <your steam game folder>/            <- NEVER modified
#       data.win, mus/, chapter1_windows/ ...
#
#   ~/.local/share/DELTARUNE/deltaport/  <- everything deltaport owns
#       port.sh update.sh modloader.sh DELTARUNE.sh lib.sh  (self-contained scripts)
#       files/patches/...                  (base patches + nxrune mod patches)
#       deltarune, icon.png                (Linux runner + icon)
#       .gamedir                           (path of the untouched game folder)
#       base/                              <- ported tree (base patches applied,
#       |    assets/game.unx                   assets symlinked, data copied)
#       |    assets/mus/ -> game files
#       |    chapter1_linux/ ...
#       working/                           <- base + your mods (rebuilt on demand,
#       |    ...                              this is what the game actually runs)
#       mods/                              <- your mods (00-nxrune, 10-my-mod, ...)
#
# Saves and chapter-switch trigger files still live in ~/.config/DELTARUNE.

CHAPTERS=5
# Used by port.sh (which sources this file)
# shellcheck disable=SC2034
LATEST_VERSION="0.0.253"

VERSION_247_CHECKSUM="908643b7593b000f5b6c61bb484d086a"
VERSION_250_CHECKSUM="1f00145d681f830f1249d9493ba8f579"
VERSION_253_CHECKSUM="83a5a14f9b92a20f21fb9ec6c8528469"

DELTAPORTDIR="${DELTAPORTDIR:-$HOME/.local/share/DELTARUNE/deltaport}"
# Safety: every script removes directories below DELTAPORTDIR
[ -n "$DELTAPORTDIR" ] || { echo "deltaport: DELTAPORTDIR must not be empty" >&2; exit 1; }
BASEDIR="$DELTAPORTDIR/base"
WORKDIR="$DELTAPORTDIR/working"
MODSDIR="$DELTAPORTDIR/mods"

log() { echo -e "\e[1;34m::\e[0m \e[1m$1\e[0m"; }
warn() { echo -e "\n\e[38;5;172m::\e[0m \e[1m\e[38;5;208m$1\e[0m"; }
error() { echo -e "\n\e[38;5;203m::\e[0m \e[1m\e[38;5;196m$1\e[0m" && exit 1; }

require_cmd() {
    command -v "$1" > /dev/null 2>&1 || error "ERROR: '$1' is required but was not found. Install it (or run deps.sh) and try again."
}

game_is_running() {
    pidof deltarune > /dev/null 2>&1
}

# Detect the game version from a data.win file.
# Prints the version (0.0.247/0.0.250/0.0.253), or nothing when unknown.
detect_version() {
    local datafile="$1"
    local md5=""

    if [ -f "$datafile" ]; then
        md5="$(md5sum "$datafile" | cut -d ' ' -f 1)"
    fi
    if [ "$md5" = "$VERSION_247_CHECKSUM" ]; then
        printf '0.0.247'
    elif [ "$md5" = "$VERSION_250_CHECKSUM" ]; then
        printf '0.0.250'
    elif [ "$md5" = "$VERSION_253_CHECKSUM" ]; then
        printf '0.0.253'
    fi
    return 0
}

# Create a directory of symlinks mirroring every file in $1 inside $2.
# The GameMaker runner expects lowercase asset names on Linux, so every file
# gets a lowercase symlink; mixed-case files additionally keep an alias with
# their original name. The source directory is NEVER modified.
build_link_farm() {
    local srcdir="$1"
    local dstdir="$2"
    local f base lc

    [ -d "$srcdir" ] || return 0
    mkdir -p "$dstdir"
    for f in "$srcdir"/*; do
        [ -e "$f" ] || continue
        base="${f##*/}"
        lc="${base,,}"
        ln -sfn "$f" "$dstdir/$lc"
        if [ "$base" != "$lc" ]; then
            ln -sfn "$f" "$dstdir/$base"
        fi
    done
    return 0
}

# Link every non-data file of a chapter directory into the ported tree.
build_chapter_assets() {
    local gamedir="$1"
    local i="$2"
    local srcdir="$gamedir/chapter${i}_windows"
    local dstdir="$BASEDIR/chapter${i}_linux/assets"
    local f base lc

    for f in "$srcdir"/*; do
        [ -e "$f" ] || continue
        base="${f##*/}"
        case "$base" in
            data.win)
                # Handled separately (copied + patched into assets/game.unx)
                continue
                ;;
            vid)
                build_link_farm "$f" "$dstdir/vid"
                if [ "$i" = "3" ]; then
                    # The game references two Chapter 3 videos with mixed case
                    # while the files on disk are lowercase.
                    if [ -e "$dstdir/vid/tennaintrof1_compressed_28.mp4" ]; then
                        ln -sfn "tennaintrof1_compressed_28.mp4" "$dstdir/vid/tennaIntroF1_compressed_28.mp4"
                    fi
                    if [ -e "$dstdir/vid/tennaintrojpf1_compressed_28.mp4" ]; then
                        ln -sfn "tennaintrojpf1_compressed_28.mp4" "$dstdir/vid/tennaIntroJPf1_compressed_28.mp4"
                    fi
                fi
                ;;
            AUDIO_INTRONOISE.ogg)
                # The game expects this file lowercased on Linux.
                lc="${base,,}"
                ln -sfn "$f" "$dstdir/$lc"
                if [ "$base" != "$lc" ]; then
                    ln -sfn "$f" "$dstdir/$base"
                fi
                ;;
            *)
                # Anything else (lang/, snd_*.ogg, ...) is linked as-is.
                ln -sfn "$f" "$dstdir/$base"
                ;;
        esac
    done
    return 0
}

# Chapter 5 videos ship without an audio stream, which makes the Linux runner
# fail to open them. Re-encode (stream copy) a silent audio track into our OWN
# copy of the two intro videos. The original files are left untouched.
fix_chapter5_videos() {
    local gamedir="$1"
    local lang src dst
    local viddir="$BASEDIR/chapter5_linux/assets/vid"

    [ -d "$gamedir/chapter5_windows/vid" ] || return 0
    [ -d "$viddir" ] || return 0
    require_cmd ffmpeg

    for lang in en jp; do
        src="$gamedir/chapter5_windows/vid/ch5_intro_${lang}.mp4"
        dst="$viddir/ch5_intro_${lang}.mp4"
        if [ -f "$src" ]; then
            rm -f "$dst"
            ffmpeg -y -i "$src" -f lavfi -i anullsrc=channel_layout=stereo:sample_rate=44100 -c:v copy -shortest "$dst"
        fi
    done
    return 0
}

# Apply the base deltaport patches (game_change -> trigger file workaround)
# to the copied data files in the base tree.
apply_base_patches() {
    local version="$1"
    local i

    require_cmd hpatchz

    hpatchz -f "$BASEDIR/assets/game.unx" "$SCRIPTDIR/files/patches/v${version}/00-chapterselect.hpatch" "$BASEDIR/assets/game.unx"
    for ((i = 1; i <= CHAPTERS; i++)); do
        if [ -f "$BASEDIR/chapter${i}_linux/assets/game.unx" ]; then
            hpatchz -f "$BASEDIR/chapter${i}_linux/assets/game.unx" "$SCRIPTDIR/files/patches/v${version}/0${i}-chapter_0${i}.hpatch" "$BASEDIR/chapter${i}_linux/assets/game.unx"
        fi
    done
    return 0
}

write_base_stamp() {
    local version="$1"
    local gamedir="$2"
    {
        echo "version=$version"
        echo "gamedir=$gamedir"
        echo "built=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "$BASEDIR/.stamp"
}

# Build the whole base tree from a (pristine) game directory.
# $1 = game directory, $2 = game version. Never modifies the game directory.
build_base() {
    local gamedir="$1"
    local version="$2"
    local i

    [ -f "$gamedir/data.win" ] || error "data.win not found at '$gamedir' - this doesn't look like a DELTARUNE installation."
    if game_is_running; then
        error "DELTARUNE appears to be running - close the game before re-porting."
    fi

    log "Preparing the deltaport directory at $DELTAPORTDIR ..."
    log "(your original game files will NOT be modified)"
    rm -rf "$BASEDIR" "$WORKDIR"
    mkdir -p "$BASEDIR/assets"
    echo "$gamedir" > "$DELTAPORTDIR/.gamedir"

    log "Installing the Linux runner and options..."
    cp "$SCRIPTDIR/deltarune" "$BASEDIR/deltarune"
    chmod +x "$BASEDIR/deltarune"
    cp "$SCRIPTDIR/icon.png" "$BASEDIR/assets/icon.png"
    cp "$SCRIPTDIR/files/options.ini" "$BASEDIR/assets/options.ini"

    log "Copying game data into the deltaport directory..."
    cp "$gamedir/data.win" "$BASEDIR/assets/game.unx"

    for ((i = 1; i <= CHAPTERS; i++)); do
        if [ -d "$gamedir/chapter${i}_windows" ]; then
            mkdir -p "$BASEDIR/chapter${i}_linux/assets"
            cp "$SCRIPTDIR/deltarune" "$BASEDIR/chapter${i}_linux/deltarune"
            chmod +x "$BASEDIR/chapter${i}_linux/deltarune"
            cp "$SCRIPTDIR/files/options_${i}.ini" "$BASEDIR/chapter${i}_linux/assets/options.ini"
            cp "$SCRIPTDIR/icon.png" "$BASEDIR/chapter${i}_linux/assets/icon.png"
            cp "$gamedir/chapter${i}_windows/data.win" "$BASEDIR/chapter${i}_linux/assets/game.unx"
            ln -sfn "../../assets/mus" "$BASEDIR/chapter${i}_linux/assets/mus"
        fi
    done

    log "Linking music assets (music stays in your game folder)..."
    rm -rf "$BASEDIR/assets/mus"
    build_link_farm "$gamedir/mus" "$BASEDIR/assets/mus"

    for ((i = 1; i <= CHAPTERS; i++)); do
        [ -d "$gamedir/chapter${i}_windows" ] || continue
        rm -rf "$BASEDIR/chapter${i}_linux/assets/vid"
        build_chapter_assets "$gamedir" "$i"
    done

    if [ "$CHAPTERS" -ge 5 ]; then
        log "Fixing Chapter 5's videos (adding a silent audio stream)..."
        fix_chapter5_videos "$gamedir"
    fi

    log "Patching game data for Linux (chapter switching support)..."
    apply_base_patches "$version"

    write_base_stamp "$version" "$gamedir"
    log "Base tree built."
    return 0
}

# Re-link the asset farms (music/videos/other chapter assets) from the game
# directory. Used after a Steam update in case assets were added/renamed.
relink_assets() {
    local gamedir="$1"
    local i

    rm -rf "$BASEDIR/assets/mus"
    build_link_farm "$gamedir/mus" "$BASEDIR/assets/mus"

    for ((i = 1; i <= CHAPTERS; i++)); do
        [ -d "$gamedir/chapter${i}_windows" ] || continue
        [ -d "$BASEDIR/chapter${i}_linux" ] || continue
        rm -rf "$BASEDIR/chapter${i}_linux/assets/vid"
        build_chapter_assets "$gamedir" "$i"
    done

    if [ "$CHAPTERS" -ge 5 ]; then
        fix_chapter5_videos "$gamedir"
    fi
    return 0
}

# Install the nxrune console borders mod as a regular mod (applies first,
# thanks to its '00-' prefix).
install_nxrune_mod() {
    if [ -d "$MODSDIR/00-nxrune" ]; then
        log "The 'nxrune' console borders mod is already installed."
        return 0
    fi
    log "Installing the 'nxrune' console borders mod into $MODSDIR/00-nxrune ..."
    mkdir -p "$MODSDIR/00-nxrune/patches"
    cp "$SCRIPTDIR"/files/patches/nxrune/*.hpatch "$MODSDIR/00-nxrune/patches/"
    log "Installed. (Remove the '00-nxrune' folder - or rename it with a '.disabled' suffix - to disable it.)"
    return 0
}

# Write the mod format documentation into the mods folder.
install_mods_readme() {
    mkdir -p "$MODSDIR"
    cat > "$MODSDIR/README.md" <<'EOF'
# deltaport mods

This folder is where your Deltarune mods live. Every time you launch the game
the 'working' tree is (re)built from the patched base game + all *enabled*
mods, in folder-name order. The build is cached and only rebuilt when the
base or a mod changes, so launching is instant otherwise.

Your original game files (in your Steam folder) are never modified.

## Mod layout

    mods/
    └── 10-my-mod/
        ├── files/     (optional) full-file overrides, copied over the game tree
        └── patches/   (optional) hdiffpatch (.hpatch) deltas, applied in filename order

### files/
Everything under `files/` is copied (overwriting, keeping relative paths)
into the game tree. To replace a game data file with a fully modded version
(e.g. made with UndertaleModTool) drop it at the exact path:

    files/assets/game.unx                    (chapter select)
    files/chapter1_linux/assets/game.unx     (chapter 1)
    files/chapter2_linux/assets/game.unx     (chapter 2)
    ...

> [!IMPORTANT]
> A full `game.unx` replacement MUST be made from a **deltaport-patched**
> data file (the ones in `base/` or `working/`), NOT from the original
> `data.win` - otherwise the Linux chapter-switching support is lost and the
> game will not be able to switch chapters.

### patches/
Each `.hpatch` file is applied with `hpatchz` to the matching data file, in
filename order. Name the file after the chapter it patches:

    patches/00-chapterselect.hpatch
    patches/01-chapter_01.hpatch
    patches/02-chapter_02.hpatch
    patches/03-chapter_03.hpatch
    patches/04-chapter_04.hpatch
    patches/05-chapter_05.hpatch

Only include the chapters your mod touches.

## Order and enabling
- Mods are applied in lexicographic folder-name order (prefix with numbers: `00-`, `10-`, `20-`, ...).
- The console borders mod lives in `00-nxrune` (installed via `./port.sh nxrune`) and applies before your mods.
- To disable a mod without deleting it, rename the folder with a `.disabled` suffix (e.g. `10-my-mod.disabled`).

## Making a patch mod
Create the patch between the base file of the chapter you mod and your modded file:

    hdiffz base/assets/game.unx my-modded-game.unx 10-my-mod/patches/00-chapterselect.hpatch

## Managing mods
    ../modloader.sh list       # show installed mods
    ../modloader.sh check      # validate your mods' layout
    ../modloader.sh rebuild    # force a rebuild of the working tree
    ../modloader.sh status     # is the working tree up to date?
EOF
    return 0
}
