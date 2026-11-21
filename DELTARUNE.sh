#!/usr/bin/env bash
# deltaport launcher
#
# Runs the game from the modded 'working' tree. The working tree is rebuilt
# automatically (via modloader.sh) whenever the base tree or the mods change.
# Your original game files are never touched.

DELTAPORTDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )

log() { echo -e "\e[1;34m::\e[0m \e[1m$1\e[0m"; }
warn() { echo -e "\n\e[38;5;172m::\e[0m \e[1m\e[38;5;208m$1\e[0m"; }
error() { echo -e "\n\e[38;5;203m::\e[0m \e[1m\e[38;5;196m$1\e[0m" && exit 1; }

DELTARUNEPID=""
SAVEDIR="$HOME/.config/DELTARUNE"
FIRST_RUN=1
HIDE_INPUT_DEVICES=0
HIDE_INPUT_COMMAND=""
GAME_WATCH=0
WATCH_LOOP_PID=""

WORKDIR="$DELTAPORTDIR/working"

CHAPTERSELECT_FILE="deltaport_chapterselect"
CHAPTER1_FILE="deltaport_chapter1"
CHAPTER2_FILE="deltaport_chapter2"
CHAPTER3_FILE="deltaport_chapter3"
CHAPTER4_FILE="deltaport_chapter4"
CHAPTER5_FILE="deltaport_chapter5"

main() {
    # Just in case
    mkdir -p "$SAVEDIR"
    cd "$SAVEDIR" || exit 1

    if [ ! -d "$DELTAPORTDIR/base" ]; then
        error "deltaport base tree not found. Run port.sh first."
    fi

    # Rebuild the working tree if the base or any mod changed since last build.
    if [ ! -f "$WORKDIR/.modstamp" ] || [ "$(cat "$WORKDIR/.modstamp" 2> /dev/null)" != "$("$DELTAPORTDIR/modloader.sh" fingerprint 2> /dev/null)" ]; then
        log "Base or mods changed - rebuilding the working tree..."
        "$DELTAPORTDIR/modloader.sh" rebuild
    fi

    if [ ! -f "$WORKDIR/assets/game.unx" ]; then
        error "Working game data not found ($WORKDIR/assets/game.unx). The mod loader failed to build the working tree - check the errors above."
    fi

    # If we are on Ubuntu/Debian, export the specific compatibility libraries
    # folder. This gets appended to the $LD_LIBRARY_PATH exported by
    # steam-runtime's script.
    if [ -f "$DELTAPORTDIR/.ubuntu" ]; then
        export LD_LIBRARY_PATH="$DELTAPORTDIR/lib"
    fi

    # Check if trigger files are somehow there and delete them
    local f
    local trigger_files=("$CHAPTERSELECT_FILE" "$CHAPTER1_FILE" "$CHAPTER2_FILE" "$CHAPTER3_FILE" "$CHAPTER4_FILE" "$CHAPTER5_FILE")
    for f in "${trigger_files[@]}"; do
        if [ -n "$f" ] && [ -f "$SAVEDIR/$f" ]; then
            rm "$SAVEDIR/$f"
        fi
    done

    if [ -f "$SAVEDIR/.exit_lock" ]; then
        rm "$SAVEDIR/.exit_lock"
    fi

    # .hide_input: keep it in the deltaport directory (also accepted in the
    # game folder for people migrating from older deltaport versions).
    local gamedir=""
    gamedir="$(cat "$DELTAPORTDIR/.gamedir" 2> /dev/null || true)"
    if [ -f "$DELTAPORTDIR/.hide_input" ] || { [ -n "$gamedir" ] && [ -f "$gamedir/.hide_input" ]; }; then
        HIDE_INPUT_DEVICES=1
    fi

    if [ "$HIDE_INPUT_DEVICES" = "1" ]; then
        # The GMS runner constantly reads /dev/input for gamepad devices every
        # frame; this uses bubblewrap to hide that directory from the runner.
        HIDE_INPUT_COMMAND="bwrap --bind / / --tmpfs /dev/input"
    fi

    # Run the game!
    local arg="${1:-}"
    case "$arg" in
        0 | 1 | 2 | 3 | 4 | 5)
            change_chapter "$arg"
            ;;
        *)
            # No chapter requested (Steam may pass '-- <exe>' noise, ignore it)
            cd "$WORKDIR" || exit 1
            run_game
            ;;
    esac

    # Watch the game save directory for chapter-switch trigger files.
    # Run in the background and wait for it: if we're blocked in 'wait' when a
    # trapped signal arrives (e.g. Ctrl+C), the trap runs right away and can
    # clean up the game. (With a foreground pipeline, the pending trap would
    # be lost when the script ends.)
    (
        inotifywait -m "$SAVEDIR" |
        while read -r _filepath _operation file; do
            if [[ "$_operation" == *CREATE* ]]; then
                parse_file "$file"
            fi
        done
    ) &
    WATCH_LOOP_PID=$!
    wait "$WATCH_LOOP_PID"
}

function exit_game {
    # To prevent it running twice
    if [ -f "$SAVEDIR/.exit_lock" ]; then
        exit 0
    fi
    touch "$SAVEDIR/.exit_lock"
    echo "Thanks for playing, hope you had fun :D"
    if [ -n "$WATCH_LOOP_PID" ]; then
        kill -9 "$WATCH_LOOP_PID" 2> /dev/null || true
    fi
    if pidof inotifywait > /dev/null 2>&1; then
        # Intentionally unquoted: pidof can return several pids
        # shellcheck disable=SC2046
        kill -9 $(pidof inotifywait) 2> /dev/null || true
    fi
    if pidof deltarune > /dev/null 2>&1; then
        # Intentionally unquoted: pidof can return several pids
        # shellcheck disable=SC2046
        kill -9 $(pidof deltarune) 2> /dev/null || true
    fi
    exit 0
}

function watch_game {
    while true; do
        sleep 4
        if [ "$(pidof deltarune 2> /dev/null)" = "" ]; then
            exit_game
        fi
    done
}

function run_game {
    # We need to set the locale to C (standard locale) because it uses a dot
    # for decimals and GMS requires it.
    # shellcheck disable=SC2086  # HIDE_INPUT_COMMAND is intentionally split
    LC_ALL=C "$HOME/.local/share/Steam/ubuntu12_32/steam-runtime/run.sh" $HIDE_INPUT_COMMAND gamemoderun ./deltarune &
    # After the first run during the chapter switch, we want to wait a bit
    # before killing the first one.
    if [ "$FIRST_RUN" = "0" ]; then
        sleep 4
    fi
    if [ "$DELTARUNEPID" != "" ]; then
        # Intentionally unquoted: pidof can return several pids
        # shellcheck disable=SC2046
        kill -9 $DELTARUNEPID 2> /dev/null || true
    fi
    until DELTARUNEPID="$(pidof deltarune)"; do
        sleep 1
    done
    FIRST_RUN=0
    if [ "$GAME_WATCH" = "0" ]; then
        watch_game &
    fi
    GAME_WATCH=1
}

# =- All the logic for changing chapters / parsing trigger files -=
function parse_file {
    cd "$SAVEDIR" || return 1
    local chapter=""
    case "$1" in
        "$CHAPTERSELECT_FILE") chapter=0 ;;
        "$CHAPTER1_FILE")      chapter=1 ;;
        "$CHAPTER2_FILE")      chapter=2 ;;
        "$CHAPTER3_FILE")      chapter=3 ;;
        "$CHAPTER4_FILE")      chapter=4 ;;
        "$CHAPTER5_FILE")      chapter=5 ;;
        *) return 0 ;;
    esac
    rm -f "$1"
    change_chapter "$chapter"
}

function change_chapter {
    local target="$WORKDIR"
    case "$1" in
        0) target="$WORKDIR" ;;
        1) target="$WORKDIR/chapter1_linux" ;;
        2) target="$WORKDIR/chapter2_linux" ;;
        3) target="$WORKDIR/chapter3_linux" ;;
        4) target="$WORKDIR/chapter4_linux" ;;
        5) target="$WORKDIR/chapter5_linux" ;;
        *) return 0 ;;
    esac
    cd "$target" || return 1
    run_game
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    trap 'exit_game' SIGINT
    main "$@"
fi
