#!/usr/bin/env bash
# deltaport launcher - the friendly front-end for your port and your mods.
#
# What it does:
#   * play the game (with a starting-chapter choice)
#   * enable / disable / remove / inspect mods
#   * install mods from a URL or from a local archive file
#   * browse the known-mods index (mod-index.json next to this script)
#   * install / update the port, manage dependencies, show port status
#
# Your original Steam game files are never modified.
#
# This is a plain terminal UI: it needs no extra packages. Arrow keys
# (or j/k) navigate, Enter selects, q goes back, Esc quits the menu.
#
# NOTE: 'set -e pipefail' would clobber the positional parameters, so use -o.
set -e -o pipefail
set -E
shopt -s nullglob

SCRIPTDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# shellcheck source=lib.sh
source "$SCRIPTDIR/lib.sh"

# ---------------------------------------------------------------------------
# TTY detection + colors
# ---------------------------------------------------------------------------
if [ -t 0 ] && [ -t 1 ]; then TTY=1; else TTY=0; fi

if [ "$TTY" = "1" ]; then
    C_TITLE=$'\e[1;36m'
    C_GREEN=$'\e[1;32m'; C_YELLOW=$'\e[1;33m'; C_RED=$'\e[1;31m'
    C_CYAN=$'\e[1;36m'
    C_RESET=$'\e[0m'
else
    C_TITLE=""; C_GREEN=""; C_YELLOW=""
    C_RED=""; C_CYAN=""; C_RESET=""
fi

# ---------------------------------------------------------------------------
# State helpers
# ---------------------------------------------------------------------------
has_port() { [ -d "$BASEDIR" ] && [ -f "$BASEDIR/.stamp" ]; }

current_version() {
    grep '^version=' "$BASEDIR/.stamp" 2> /dev/null | cut -d '=' -f 2 || true
}

game_dir() {
    cat "$DELTAPORTDIR/.gamedir" 2> /dev/null || true
}

enabled_mod_names() {
    [ -d "$MODSDIR" ] || return 0
    find "$MODSDIR" -mindepth 1 -maxdepth 1 -type d ! -name '*.disabled' -printf '%f\n' | sort
}

working_is_current() {
    [ -f "$WORKDIR/.modstamp" ] || return 1
    [ "$(cat "$WORKDIR/.modstamp" 2> /dev/null)" = "$("$SCRIPTDIR/modloader.sh" fingerprint 2> /dev/null)" ]
}

# Starting chapter for the next launch (0 = chapter select screen).
LAUNCH_CHAPTER=0
if [ -f "$DELTAPORTDIR/.launchopts" ]; then
    LAUNCH_CHAPTER="$(grep '^chapter=' "$DELTAPORTDIR/.launchopts" 2> /dev/null | cut -d '=' -f 2 || true)"
fi
case "$LAUNCH_CHAPTER" in
    0 | 1 | 2 | 3 | 4 | 5) : ;;
    *) LAUNCH_CHAPTER=0 ;;
esac

chapter_label() {
    case "$1" in
        0) echo "chapter select" ;;
        *) echo "chapter $1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------
# Read one key. Sets REPLY_KEY to: up / down / left / right / esc / enter,
# or the literal character that was pressed. Returns 1 on EOF.
read_key() {
    local key seq
    REPLY_KEY=""
    IFS= read -rsn1 key || return 1
    if [ "$key" = $'\e' ]; then
        IFS= read -rsn2 -t 0.15 seq || seq=""
        case "$seq" in
            '[A') REPLY_KEY="up" ;;
            '[B') REPLY_KEY="down" ;;
            '[C') REPLY_KEY="right" ;;
            '[D') REPLY_KEY="left" ;;
            *)    REPLY_KEY="esc" ;;
        esac
    else
        REPLY_KEY="$key"
    fi
    return 0
}

# Wait for any key (only when there is a real terminal).
pause() {
    if [ "$TTY" = "1" ]; then
        echo
       echo ${C_YELLOW}" [press any key to continue]..."$C_RESET
        read_key || true
    fi
    return 0
}

# Prompt for a whole line (URLs, file paths, confirmations).
# $1 = prompt, $2 = optional default value. Sets REPLY_LINE.
read_line() {
    local prompt="$1" def="${2:-}"
    REPLY_LINE=""
    if [ -n "$def" ]; then
        printf '%s %s' "$C_YELLOW$prompt"$C_RESET "($def) "
    else
        printf '%s' "$C_YELLOW$prompt"$C_RESET
    fi
    IFS= read -r REPLY_LINE || return 1
    if [ -n "$def" ] && [ -z "$REPLY_LINE" ]; then
        REPLY_LINE="$def"
    fi
    return 0
}

confirm() {
    local prompt="$1"
    if ! read_line "$prompt [y/n]: "; then
        return 1
    fi
    case "$REPLY_LINE" in
        [Yy]*) return 0 ;;
        *) return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# Screens
# ---------------------------------------------------------------------------
clear_screen() {
    [ "$TTY" = "1" ] && clear || true
    return 0
}

screen_title() {
    if [ "$TTY" = "1" ]; then
        echo "$C_TITLE$1$C_RESET"
    else
        echo "# $1"
    fi
}

# ---------------------------------------------------------------------------
# Handlers
# ---------------------------------------------------------------------------
help_screen() {
    clear_screen
    screen_title "deltaport launcher - help"
    cat <<EOF
 Navigation:  arrow keys or j/k move, Enter selects, q/Esc goes back.

 Mods (main menu -> "Manage mods"):
   t or Enter  enable/disable a mod (the working tree is rebuilt right away)
   i           inspect a mod (contents, source, what it replaces)
   d           delete a mod (with confirmation)

 Installing mods (main menu):
   "Install mod from URL"   any .zip / .tar.gz / .tar.xz that contains
                            a deltaport mod folder (files/ and/or patches/),
                            or a modded data.win / game.unx file (it is
                            converted into a files/ override for you).
   "Install mod from file"  same, from an archive you already downloaded.
   "Browse known mods"      the bundled mod-index.json (extend it with your
                            own entries - see the README, "Known mods index").

 Your original Steam game files are never modified. The game always runs
 from the deltaport working tree (base + enabled mods).
EOF
    pause
    return 0
}

port_status_screen() {
    clear_screen
    screen_title "port status"
    if ! has_port; then
        echo " Not ported yet - use the main menu to install the port."
        pause
        return 0
    fi
    local ver gdir gver hpatchz_path
    ver="$(current_version)"
    gdir="$(game_dir)"
    gver="$( [ -n "$gdir" ] && [ -f "$gdir/data.win" ] && detect_version "$gdir/data.win" || true )"
    if command -v hpatchz > /dev/null 2>&1; then
        hpatchz_path="$(command -v hpatchz)"
    else
        hpatchz_path="MISSING (run deps.sh)"
    fi
    echo " INSTALL DIR:   $DELTAPORTDIR"
    echo " PORT VERSION:  ${ver:-unknown}"
    echo " GAME DIR:      ${gdir:-unknown}"
    echo " GAME VERSION:  ${gver:-unknown (not in the supported list - the port still works)}"
    if working_is_current; then
        echo " WORKING TREE:  up to date"
    else
        echo " WORKING TREE:  stale (it will be rebuilt automatically on the next launch)"
    fi
    echo " HPATCHZ:       $hpatchz_path"
    if game_is_running; then
        echo " GAME RUNNING:  yes"
    else
        echo " GAME RUNNING:  no"
    fi
    local mods
    mods="$(enabled_mod_names)"
    if [ -n "$mods" ]; then
        echo " ENABLED MODS:  $(echo "$mods" | wc -l) ($(echo "$mods" | tr '\n' ' '))"
    else
        echo " ENABLED MODS:  none"
    fi
    if [ -d "$BASEDIR" ] || [ -d "$WORKDIR" ]; then
        echo " DISK USAGE:"
        du -sh "$BASEDIR" "$WORKDIR" 2> /dev/null | sed 's/^/   /' || true
    fi
    pause
    return 0
}

run_port_sh() {
    clear_screen
    screen_title "installing the port"
    echo " Running port.sh - answer its questions, then come back here."
    echo
    ( "$SCRIPTDIR/port.sh" )
    local rc=$?
    if [ "$rc" -ne 0 ]; then
       echo ${C_RED}" port.sh exited with code $rc"$C_RESET
    fi
    pause
    return 0
}

run_update_sh() {
    clear_screen
    screen_title "updating the port"
    echo " Running update.sh (your original game files are never touched)."
    echo
    ( "$SCRIPTDIR/update.sh" )
    local rc=$?
    if [ "$rc" -ne 0 ]; then
       echo ${C_RED}" update.sh exited with code $rc"$C_RESET
    fi
    pause
    return 0
}

run_deps_sh() {
    clear_screen
    screen_title "dependencies"
    echo " Running deps.sh (installs hpatchz, jq, unzip, ... if missing)."
    echo
    ( "$SCRIPTDIR/deps.sh" )
    local rc=$?
    if [ "$rc" -ne 0 ]; then
       echo ${C_RED}" deps.sh exited with code $rc"$C_RESET
    fi
    pause
    return 0
}

play_game() {
    if ! has_port; then
        clear_screen
        screen_title "play deltarune"
       echo ${C_RED}" Not ported yet - install the port first (main menu)."$C_RESET
        pause
        return 0
    fi
    local sel="$LAUNCH_CHAPTER" key
    while true; do
        clear_screen
        screen_title "play deltarune"
        echo " Start in:  [0] chapter select   [1] chapter 1   [2] chapter 2"
        echo "            [3] chapter 3        [4] chapter 4   [5] chapter 5"
        echo
       echo ${C_YELLOW}" (current choice: $(chapter_label "$sel"))"$C_RESET
        echo " Press 0-5 to choose, Enter to launch, q to go back."
        if ! read_key; then return 0; fi
        key="$REPLY_KEY"
        case "$key" in
            0 | 1 | 2 | 3 | 4 | 5) sel="$key" ;;
            "" | enter) break ;;
            q | Q | esc) return 0 ;;
        esac
    done
    echo "chapter=$sel" > "$DELTAPORTDIR/.launchopts"
    if ! command -v hpatchz > /dev/null 2>&1; then
       echo ${C_RED}" hpatchz is not installed - run deps.sh first (main menu)."$C_RESET
        pause
        return 0
    fi
    clear_screen
    echo " Starting Deltarune in $(chapter_label "$sel"). The launcher stays open in this window;"
    echo " when the game quits you will be back here."
    echo " (Ctrl+C inside the game works as usual.)"
    echo
    # Let DELTARUNE.sh own Ctrl+C while the game runs (it cleans up the game).
    trap '' SIGINT
    ( "$SCRIPTDIR/DELTARUNE.sh" "$sel" )
    local rc=$?
    trap 'echo; echo "Bye!"; exit 0' SIGINT
    if [ "$rc" -ne 0 ]; then
       echo ${C_RED}" The game launcher exited with code $rc."$C_RESET
    fi
    pause
    return 0
}

# --- Mod installation --------------------------------------------------------

STAGE=""
cleanup_stage() {
    if [ -n "$STAGE" ] && [ -d "$STAGE" ]; then
        rm -rf "$STAGE"
    fi
    STAGE=""
}

# $1 = archive file, $2 = source label ("", "local: path" or the URL)
install_mod_archive() {
    local archive="$1" source="$2"
    local extract modroot entries entry

    clear_screen
    screen_title "installing mod"
    echo " Archive: $archive"

    extract="$STAGE/extract"
    mkdir -p "$extract"

    if unzip -l "$archive" > /dev/null 2>&1; then
        unzip -q -o "$archive" -d "$extract"
    elif tar -tzf "$archive" > /dev/null 2>&1; then
        tar -xzf "$archive" -C "$extract"
    elif tar -tJf "$archive" > /dev/null 2>&1; then
        tar -xJf "$archive" -C "$extract"
    elif tar -tf "$archive" > /dev/null 2>&1; then
        tar -xf "$archive" -C "$extract"
    else
       echo ${C_RED}" This file is not a zip or tar archive."$C_RESET
        pause
        return 0
    fi

    # Flatten: if the archive unpacked into a single folder, use that folder.
    modroot="$extract"
    entries=()
    while IFS= read -r entry; do
        [ -n "$entry" ] && entries+=("$entry")
    done < <(find "$extract" -mindepth 1 -maxdepth 1 | sort)
    if [ "${#entries[@]}" -eq 1 ] && [ -d "${entries[0]}" ]; then
        modroot="${entries[0]}"
    fi

    local found=() i
    # Look for data files (a modded data.win / game.unx, optionally per chapter).
    if [ -f "$modroot/data.win" ] || [ -f "$modroot/game.unx" ]; then
        found+=("root")
    fi
    for i in 1 2 3 4 5; do
        if [ -f "$modroot/chapter${i}_windows/data.win" ] || [ -f "$modroot/chapter${i}_linux/assets/game.unx" ]; then
            found+=("chapter$i")
        fi
    done

    if [ -d "$modroot/files" ] || [ -d "$modroot/patches" ]; then
       echo ${C_CYAN}" Recognized a deltaport mod folder (files/ and/or patches/)."$C_RESET
    elif [ -f "$modroot/modding.xml" ]; then
       echo ${C_RED}" This is a DELTAMOD package (it contains a modding.xml)."$C_RESET
        echo " Deltamod packages use the xdelta patch format, which the deltaport"
        echo " mod loader cannot apply (it uses hpatch/hpatchz). See the README"
        echo " ('Deltamod packages') for how to convert one if you really need it."
        pause
        return 0
    elif [ "${#found[@]}" -gt 0 ]; then
       echo ${C_YELLOW}" No files/ or patches/ folder - found a modded game data file and converting"$C_RESET
       echo ${C_YELLOW}" it into a full-file override:"$C_RESET
        mkdir -p "$modroot/files/assets"
        if [ -f "$modroot/data.win" ]; then
            cp "$modroot/data.win" "$modroot/files/assets/game.unx"
        elif [ -f "$modroot/game.unx" ]; then
            cp "$modroot/game.unx" "$modroot/files/assets/game.unx"
        fi
        for i in 1 2 3 4 5; do
            if [ -f "$modroot/chapter${i}_windows/data.win" ]; then
                mkdir -p "$modroot/files/chapter${i}_linux/assets"
                cp "$modroot/chapter${i}_windows/data.win" "$modroot/files/chapter${i}_linux/assets/game.unx"
            elif [ -f "$modroot/chapter${i}_linux/assets/game.unx" ]; then
                mkdir -p "$modroot/files/chapter${i}_linux/assets"
                cp "$modroot/chapter${i}_linux/assets/game.unx" "$modroot/files/chapter${i}_linux/assets/game.unx"
            fi
        done
       echo ${C_YELLOW}" NOTE: a full replacement made from the ORIGINAL data.win does not carry the"$C_RESET
       echo ${C_YELLOW}" deltaport chapter-switching support - chapter switching may not work with it.$C_RESET"
       echo ${C_YELLOW}" (See mods/README.md, 'files/')."$C_RESET
    else
       echo ${C_RED}" Unrecognized mod layout."$C_RESET
        echo " Expected one of:"
        echo "   a deltaport mod folder:  files/ (overrides) and/or patches/ (.hpatch files)"
        echo "   a modded data file:      data.win / game.unx (optionally in chapter*_windows/)"
        pause
        return 0
    fi

    # Derive a name + the next free NN- prefix.
    local base slug max=0 n dest
    base="$(basename "$modroot")"
    if [ -z "$base" ] || [ "$base" = "extract" ]; then
        base="$(basename "${source#local: }")"
    fi
    base="${base%.*}"
    slug="$(printf '%s' "$base" | tr 'A-Z' 'a-z' | tr -cs 'a-z0-9' '-' | sed 's/^-*//; s/-*$//; s/--*/-/g')"
    slug="${slug:0:30}"
    if [ -z "$slug" ]; then
        slug="mod"
    fi
    if [ -d "$MODSDIR" ]; then
        for d in "$MODSDIR"/*/; do
            n="$(basename "$d")"
            n="${n%%-*}"
            if [[ "$n" =~ ^[0-9]+$ ]]; then
                if [ "$n" -gt "$max" ]; then
                    max="$n"
                fi
            fi
        done
    fi
    local nn
    nn="$(printf '%02d' $(( max + 10 )))"
    dest="$MODSDIR/${nn}-${slug}"
    if [ -e "$dest" ]; then
       echo ${C_RED}" A mod is already installed at $dest - delete or rename it first, or install this as a different mod manually."$C_RESET
        pause
        return 0
    fi

    mkdir -p "$MODSDIR"
    mv "$modroot" "$dest"
    echo "${source:-local}" > "$dest/.modsource"

   echo ${C_GREEN}" Installed as: ${nn}-${slug}$C_RESET"
    if [ -n "$source" ]; then
        echo " Source: $source"
    fi
    if has_port; then
        echo " Rebuilding the working tree..."
        if ( "$SCRIPTDIR/modloader.sh" rebuild ); then
           echo ${C_GREEN}" Done. The mod is ENABLED - use 'Manage mods' to toggle it off at any time."$C_RESET
        else
           echo ${C_RED}" The mod is installed, but rebuilding the working tree failed - check the errors above."$C_RESET
        fi
    else
        echo " (The port is not installed yet, so nothing was rebuilt.)"
    fi
    pause
    return 0
}

install_mod_from_url() {
    local url
    if ! read_line "Mod archive URL (zip / tar.gz / tar.xz): "; then
        return 0
    fi
    url="$REPLY_LINE"
    if ! [[ "$url" =~ ^https?:// ]]; then
       echo ${C_RED}" That doesn't look like an http(s) URL."$C_RESET
        pause
        return 0
    fi
    if ! command -v curl > /dev/null 2>&1; then
       echo ${C_RED}" curl is needed to download mods (run deps.sh from the main menu)."$C_RESET
        pause
        return 0
    fi
    cleanup_stage
    STAGE="$(mktemp -d)"
    trap cleanup_stage EXIT
    local fname dl
    fname="$(basename "${url%%\?*}")"
    if [ -z "$fname" ]; then
        fname="mod"
    fi
    dl="$STAGE/$fname"
    clear_screen
    screen_title "installing mod from URL"
    echo " $url"
    if ! curl -fL --retry 2 --max-time 600 -o "$dl" "$url"; then
       echo ${C_RED}" Download failed (check the URL and your connection)."$C_RESET
        pause
        return 0
    fi
    echo " Downloaded: $(du -h "$dl" | cut -f1)"
    install_mod_archive "$dl" "$url"
    return 0
}

install_mod_from_file() {
    local f
    if ! read_line "Archive file (zip / tar.gz / tar.xz): "; then
        return 0
    fi
    f="$REPLY_LINE"
    if [ -z "$f" ]; then
        return 0
    fi
    # Expand a leading ~ to $HOME (relative paths are resolved against the CWD).
    case "$f" in
        "~")   f="$HOME" ;;
        "~"/*) f="$HOME/${f#"~"}" ;;
    esac
    if [ ! -f "$f" ]; then
       echo ${C_RED}" File not found: $f"$C_RESET
        pause
        return 0
    fi
    cleanup_stage
    STAGE="$(mktemp -d)"
    trap cleanup_stage EXIT
    install_mod_archive "$f" "local: $f"
    return 0
}

browse_index() {
    local index="$SCRIPTDIR/mod-index.json"
    if [ ! -f "$index" ]; then
        clear_screen
        screen_title "known mods"
        echo " No mod-index.json found next to launcher.sh."
        echo " Use 'Install mod from URL' instead."
        pause
        return 0
    fi
    if ! command -v jq > /dev/null 2>&1; then
        clear_screen
        screen_title "known mods"
        echo " jq is needed to read the mod index (run deps.sh)."
        pause
        return 0
    fi
    if ! jq -e '.mods | length >= 1' "$index" > /dev/null 2>&1; then
        clear_screen
        screen_title "known mods"
        echo " The mod index is empty - use 'Install mod from URL' instead,"
        echo " or add entries to mod-index.json (see the README, 'Known mods index')."
        pause
        return 0
    fi

    local rows=() sel=0 key line id name url bundled desc
    while IFS= read -r line; do
        [ -n "$line" ] && rows+=("$line")
    done < <(jq -r '.mods[] | [.id, .name, (.description // ""), (.url // ""), (.bundled // false | tostring)] | @tsv' "$index")

    while true; do
        clear_screen
        screen_title "known mods (from mod-index.json)"
        local i
        for i in "${!rows[@]}"; do
            IFS=$'\t' read -r id name desc url bundled <<< "${rows[$i]}"
            local marker=" "
            if [ "$bundled" = "true" ]; then
                marker="*"
            fi
            local selmark=" "
            if [ "$i" -eq "$sel" ]; then
                selmark=">"
            fi
            if [ -n "$name" ]; then
                printf ' %s%s  %-28s %s\n' "$selmark" "$marker" "$name" "${desc:0:46}"
            fi
        done
        echo
        echo " * ships with deltaport      > selected      Enter: install / info"
        echo " j/k or arrows: move    q/Esc: back"
        if ! read_key; then return 0; fi
        key="$REPLY_KEY"
        case "$key" in
            up | k)
                if [ "$sel" -gt 0 ]; then sel=$(( sel - 1 )); fi
                ;;
            down | j)
                if [ "$sel" -lt $(( ${#rows[@]} - 1 )) ]; then sel=$(( sel + 1 )); fi
                ;;
            "" | enter)
                IFS=$'\t' read -r id name desc url bundled <<< "${rows[$sel]}"
                if [ "$bundled" = "true" ]; then
                    clear_screen
                    screen_title "$name"
                    echo " $desc"
                    echo " This mod ships with deltaport (folder 00-nxrune in the mods folder)."
                    echo " Upstream source: $url"
                    pause
                else
                    # Reuse the URL installer with the URL prefilled.
                    if ! command -v curl > /dev/null 2>&1; then
                       echo ${C_RED}" curl is needed to download mods (run deps.sh from the main menu)."$C_RESET
                        pause
                        return 0
                    fi
                    cleanup_stage
                    STAGE="$(mktemp -d)"
                    trap cleanup_stage EXIT
                    local dl fname
                    fname="$(basename "${url%%\?*}")"
                    if [ -z "$fname" ]; then fname="mod"; fi
                    dl="$STAGE/$fname"
                    clear_screen
                    screen_title "installing: $name"
                    echo " $url"
                    if ! curl -fL --retry 2 --max-time 600 -o "$dl" "$url"; then
                       echo ${C_RED}" Download failed (check the URL and your connection)."$C_RESET
                        pause
                        return 0
                    fi
                    echo " Downloaded: $(du -h "$dl" | cut -f1)"
                    install_mod_archive "$dl" "$url"
                    # Remember it came from the index.
                    if [ -d "$MODSDIR" ]; then
                        for d in "$MODSDIR"/*/; do
                            if [ -f "$d/.modsource" ] && grep -qx "$url" "$d/.modsource" 2> /dev/null; then
                                echo "$id" > "$d/.modid"
                            fi
                        done
                    fi
                fi
                return 0
                ;;
            q | Q | esc) return 0 ;;
        esac
    done
}

# --- Mod management screen ---------------------------------------------------

mod_info() {
    local mod="$1"
    clear_screen
    screen_title "mod: $mod"
    case "$mod" in
        *.disabled) echo " STATE:  DISABLED (rename without the .disabled suffix to enable)" ;;
        *)          echo " STATE:  enabled" ;;
    esac
    if [ -f "$MODSDIR/$mod/.modsource" ]; then
        echo " SOURCE: $(cat "$MODSDIR/$mod/.modsource")"
    fi
    if [ -f "$MODSDIR/$mod/.modid" ]; then
        echo " INDEX ID: $(cat "$MODSDIR/$mod/.modid")"
    fi
    if [ -f "$MODSDIR/$mod/mod-info.json" ]; then
        echo
        echo " mod-info.json:"
        if command -v jq > /dev/null 2>&1; then
            jq . "$MODSDIR/$mod/mod-info.json" | sed 's/^/   /' || cat "$MODSDIR/$mod/mod-info.json" | sed 's/^/   /'
        else
            cat "$MODSDIR/$mod/mod-info.json" | sed 's/^/   /'
        fi
    fi
    echo
    if [ -d "$MODSDIR/$mod/files" ]; then
        echo " files/ (full-file overrides, applied in path order):"
        local f rel
        while IFS= read -r f; do
            rel="${f#"$MODSDIR/$mod/files/"}"
            case "$rel" in
                *assets/game.unx)
                   echo ${C_YELLOW}"   $rel   <- REPLACES a game data file"$C_RESET
                    ;;
                *)
                    echo "   $rel"
                    ;;
            esac
        done < <(find "$MODSDIR/$mod/files" -type f | sort)
        echo
    fi
    if [ -d "$MODSDIR/$mod/patches" ]; then
        echo " patches/ (hpatch deltas, applied in filename order):"
        local p pn
        while IFS= read -r p; do
            [ -n "$p" ] || continue
            pn="$(basename "$p")"
            case "$pn" in
                00-*) echo "   $pn  -> chapter select data" ;;
                01-*) echo "   $pn  -> chapter 1 data" ;;
                02-*) echo "   $pn  -> chapter 2 data" ;;
                03-*) echo "   $pn  -> chapter 3 data" ;;
                04-*) echo "   $pn  -> chapter 4 data" ;;
                05-*) echo "   $pn  -> chapter 5 data" ;;
                *)    echo "   $pn  -> UNRECOGNIZED NAME (will be skipped)" ;;
            esac
        done < <(find "$MODSDIR/$mod/patches" -type f | sort)
        echo
    fi
    pause
    return 0
}

mods_menu() {
    if ! has_port; then
        clear_screen
        screen_title "mods"
       echo ${C_YELLOW}" The port is not installed yet - mods will live in:"$C_RESET
        echo "   $MODSDIR"
        echo " (Install the port from the main menu first. You can still"
        echo "  pre-place mod folders there if you want.)"
        pause
        return 0
    fi
    local mods=()
    if [ -d "$MODSDIR" ]; then
        while IFS= read -r m; do
            [ -n "$m" ] && mods+=("$m")
        done < <(find "$MODSDIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
    fi
    local sel=0 key
    while true; do
        clear_screen
        screen_title "mods ($MODSDIR)"
        local i m
        if [ "${#mods[@]}" -eq 0 ]; then
            echo " No mods installed yet."
            echo
        else
            for i in "${!mods[@]}"; do
                m="${mods[$i]}"
                local state=" "
                case "$m" in
                    *.disabled) state="-" ;;
                    *)          state="x" ;;
                esac
                local selmark=" "
                if [ "$i" -eq "$sel" ]; then
                    selmark=">"
                fi
                local src=""
                if [ -f "$MODSDIR/$m/.modsource" ]; then
                    src="$(cat "$MODSDIR/$m/.modsource")"
                    src="${src:0:44}"
                fi
                printf ' %s[%s] %-28s %s\n' "$selmark" "$state" "$m" "$src"
            done
            echo
        fi
        echo " [t/Enter] toggle   [i]nfo   [d]elete   [j/k|arrows] move"
        echo " [u] from URL   [f] from file   [b] browse index   [q] back"
        if ! read_key; then return 0; fi
        key="$REPLY_KEY"
        case "$key" in
            up | k)
                if [ "${#mods[@]}" -gt 0 ] && [ "$sel" -gt 0 ]; then sel=$(( sel - 1 )); fi
                ;;
            down | j)
                if [ "${#mods[@]}" -gt 0 ] && [ "$sel" -lt $(( ${#mods[@]} - 1 )) ]; then sel=$(( sel + 1 )); fi
                ;;
            "" | enter | t | T | " ")
                if [ "${#mods[@]}" -gt 0 ]; then
                    m="${mods[$sel]}"
                    case "$m" in
                        *.disabled)
                            mv "$MODSDIR/$m" "$MODSDIR/${m%.disabled}"
                           echo ${C_GREEN}" Enabled ${m%.disabled}"$C_RESET
                            ;;
                        *)
                            mv "$MODSDIR/$m" "$MODSDIR/$m.disabled"
                           echo ${C_GREEN}" Disabled $m"$C_RESET
                            ;;
                    esac
                    if ( "$SCRIPTDIR/modloader.sh" rebuild ); then :; else
                       echo ${C_RED}" (Rebuilding the working tree failed - see errors above.)"$C_RESET
                    fi
                    # Reload the list, keep the selection on the same mod.
                    local newmods=() nm
                    while IFS= read -r nm; do
                        [ -n "$nm" ] && newmods+=("$nm")
                    done < <(find "$MODSDIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
                    mods=("${newmods[@]}")
                    local found_sel=0
                    for i in "${!mods[@]}"; do
                        if [ "${mods[$i]}" = "$m" ] || [ "${mods[$i]}" = "${m%.disabled}" ]; then
                            sel="$i"
                            found_sel=1
                        fi
                    done
                    [ "$found_sel" -eq 1 ] || sel=0
                fi
                ;;
            i | I)
                if [ "${#mods[@]}" -gt 0 ]; then
                    mod_info "${mods[$sel]}"
                    # Reload list after coming back
                    local newmods2=() nm2
                    while IFS= read -r nm2; do
                        [ -n "$nm2" ] && newmods2+=("$nm2")
                    done < <(find "$MODSDIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
                    mods=("${newmods2[@]}")
                    if [ "$sel" -ge "${#mods[@]}" ]; then sel=0; fi
                fi
                ;;
            d | D)
                if [ "${#mods[@]}" -gt 0 ]; then
                    m="${mods[$sel]}"
                    clear_screen
                    screen_title "delete mod"
                    echo " Delete this mod FOLDER (its files, your settings included)?"
                   echo ${C_RED}"   $m"$C_RESET
                    if confirm " Delete?"; then
                        rm -rf "${MODSDIR:?}/$m"
                       echo ${C_GREEN}" Deleted $m"$C_RESET
                        if ( "$SCRIPTDIR/modloader.sh" rebuild ); then :; else
                           echo ${C_RED}" (Rebuilding the working tree failed - see errors above.)"$C_RESET
                        fi
                        local newmods3=() nm3
                        while IFS= read -r nm3; do
                            [ -n "$nm3" ] && newmods3+=("$nm3")
                        done < <(find "$MODSDIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
                        mods=("${newmods3[@]}")
                        if [ "$sel" -ge "${#mods[@]}" ]; then
                            if [ "$sel" -gt 0 ]; then sel=$(( sel - 1 )); fi
                        fi
                    fi
                fi
                ;;
            u | U)
                install_mod_from_url
                local newmods4=() nm4
                while IFS= read -r nm4; do
                    [ -n "$nm4" ] && newmods4+=("$nm4")
                done < <(find "$MODSDIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
                mods=("${newmods4[@]}")
                if [ "$sel" -ge "${#mods[@]}" ]; then sel=0; fi
                ;;
            f | F)
                install_mod_from_file
                local newmods5=() nm5
                while IFS= read -r nm5; do
                    [ -n "$nm5" ] && newmods5+=("$nm5")
                done < <(find "$MODSDIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
                mods=("${newmods5[@]}")
                if [ "$sel" -ge "${#mods[@]}" ]; then sel=0; fi
                ;;
            b | B)
                browse_index
                local newmods6=() nm6
                while IFS= read -r nm6; do
                    [ -n "$nm6" ] && newmods6+=("$nm6")
                done < <(find "$MODSDIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
                mods=("${newmods6[@]}")
                if [ "$sel" -ge "${#mods[@]}" ]; then sel=0; fi
                ;;
            q | Q | esc) return 0 ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Main menu
# ---------------------------------------------------------------------------
main_menu() {
    local items=() labels=() sel=0 key
    while true; do
        # Pick up changes made by the sub-screens (e.g. a new launch chapter).
        if [ -f "$DELTAPORTDIR/.launchopts" ]; then
            LAUNCH_CHAPTER="$(grep '^chapter=' "$DELTAPORTDIR/.launchopts" 2> /dev/null | cut -d '=' -f 2 || true)"
            case "$LAUNCH_CHAPTER" in
                0 | 1 | 2 | 3 | 4 | 5) : ;;
                *) LAUNCH_CHAPTER=0 ;;
            esac
        fi
        if has_port; then
            items=( play mods url file browse update deps status help )
            labels=(
                "Play Deltarune  (start: $(chapter_label "$LAUNCH_CHAPTER"))"
                "Manage mods  (enable / disable / install / delete)"
                "Install mod from URL"
                "Install mod from file"
                "Browse known mods"
                "Update port  (new game version)"
                "Install / check dependencies"
                "Port status"
                "Help"
            )
        else
            items=( port deps help )
            labels=(
                "Install the port"
                "Install / check dependencies"
                "Help"
            )
        fi
        clear_screen
        if has_port; then
            screen_title "deltaport launcher   (port $(current_version))"
        else
            screen_title "deltaport launcher   (not ported yet)"
        fi
        echo
        local i
        for i in "${!items[@]}"; do
            local selmark=" "
            if [ "$i" -eq "$sel" ]; then
                selmark=">"
            fi
            local num=$(( i + 1 ))
            printf ' %s %s  %s\n' "$selmark" "$num" "${labels[$i]}"
        done
        echo
        echo " j/k or arrows: move    Enter: select    1-$(( ${#items[@]} )): jump    q: quit"
        if ! read_key; then
            break
        fi
        key="$REPLY_KEY"
        local action=""
        case "$key" in
            up | k)
                if [ "$sel" -gt 0 ]; then sel=$(( sel - 1 )); fi
                ;;
            down | j)
                if [ "$sel" -lt $(( ${#items[@]} - 1 )) ]; then sel=$(( sel + 1 )); fi
                ;;
            q | Q) break ;;
            "" | enter)
                action="${items[$sel]}"
                ;;
            [1-9])
                if [ "$key" -le "${#items[@]}" ]; then
                    action="${items[$(( key - 1 ))]}"
                fi
                ;;
            *) : ;;
        esac
        if [ -z "$action" ]; then
            continue
        fi
        case "$action" in
            play)   play_game ;;
            mods)   mods_menu ;;
            url)    install_mod_from_url ;;
            file)   install_mod_from_file ;;
            browse) browse_index ;;
            update)
                if has_port; then run_update_sh; else
                    clear_screen
                    screen_title "update"
                   echo ${C_YELLOW}" Port not installed yet."$C_RESET
                    pause
                fi
                ;;
            deps)   run_deps_sh ;;
            status) port_status_screen ;;
            help)   help_screen ;;
            port)
                if has_port; then
                    clear_screen
                    screen_title "install"
                   echo ${C_YELLOW}" The port is already installed - use 'Update port' instead."$C_RESET
                    pause
                else
                    run_port_sh
                fi
                ;;
        esac
    done
    return 0
}

trap 'echo; echo "Bye!"; exit 0' SIGINT

main_menu
echo
echo " Bye!"
exit 0
