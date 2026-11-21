#!/usr/bin/env bash
# deltaport mod loader
#
# Builds the 'working' game tree from the patched 'base' tree plus the mods
# installed in mods/. Neither the base tree nor your original game files are
# ever modified by this tool.
#
# Usage:
#   modloader.sh            # show status (up to date / stale)
#   modloader.sh rebuild    # (re)build the working tree from base + mods
#   modloader.sh status     # same as the default
#   modloader.sh list       # list installed mods
#   modloader.sh check      # validate the mods' layout
#   modloader.sh fingerprint# internal: hash of base + mods state

# NOTE: 'set -e pipefail' would clobber the positional parameters, so use -o.
set -e -o pipefail
set -E
shopt -s nullglob

SCRIPTDIR=$( cd -- "$( dirname -- "${BASH_SOURCE[0]}" )" &> /dev/null && pwd )
# shellcheck source=lib.sh
source "$SCRIPTDIR/lib.sh"

# A rebuild works on a temporary directory that is swapped into place only
# when it succeeds - a failed rebuild must never destroy the last good tree.
NEWWORK=""
cleanup_newwork() {
    if [ -n "$NEWWORK" ] && [ -d "$NEWWORK" ]; then
        rm -rf "$NEWWORK"
    fi
}
trap 'warn "WARNING: Mod loader cancelled by user." && cleanup_newwork && exit 1' SIGINT
trap 'error "An error occurred while running the mod loader :("; cleanup_newwork' ERR
trap cleanup_newwork EXIT

# Names of the game data files that can be patched/replaced, relative to the
# tree root.
DATA_FILES=(
    "assets/game.unx"
    "chapter1_linux/assets/game.unx"
    "chapter2_linux/assets/game.unx"
    "chapter3_linux/assets/game.unx"
    "chapter4_linux/assets/game.unx"
    "chapter5_linux/assets/game.unx"
)

usage() {
    cat <<EOF
deltaport mod loader - manages the mods folder and builds the working game tree.

Usage: $(basename "$0") [command]

  status       Show whether the working tree is up to date (default)
  rebuild      (Re)build the working tree from the base tree + enabled mods
  list         List the installed mods
  check        Validate the layout of your mods
  fingerprint  Print the hash of the current base+mods state (internal)

Mods live in: $MODSDIR
See $MODSDIR/README.md for the mod format.
EOF
}

# Print the names (sorted) of all enabled mod folders.
list_enabled_mods() {
    [ -d "$MODSDIR" ] || return 0
    find "$MODSDIR" -mindepth 1 -maxdepth 1 -type d ! -name '*.disabled' -printf '%f\n' | sort
}

# Map a patch file name to the data file it patches (relative to tree root).
# Returns 1 when the name is unknown or the target chapter is missing.
patch_target() {
    local name="$1"
    local rel=""

    case "$name" in
        00-*) rel="assets/game.unx" ;;
        01-*) rel="chapter1_linux/assets/game.unx" ;;
        02-*) rel="chapter2_linux/assets/game.unx" ;;
        03-*) rel="chapter3_linux/assets/game.unx" ;;
        04-*) rel="chapter4_linux/assets/game.unx" ;;
        05-*) rel="chapter5_linux/assets/game.unx" ;;
        *) return 1 ;;
    esac
    [ -f "$BASEDIR/$rel" ] || return 1
    echo "$rel"
    return 0
}

# Hash of everything that influences the working tree: base stamp, mod
# contents (names/sizes/mtimes) and the loader scripts themselves.
fingerprint() {
    {
        printf 'base-stamp:'
        if [ -f "$BASEDIR/.stamp" ]; then
            cat "$BASEDIR/.stamp"
        else
            printf 'missing'
        fi
        printf '\nmods:'
        if [ -d "$MODSDIR" ]; then
            find "$MODSDIR" -mindepth 1 -printf '%y %T@ %s %P\n' | sort
        fi
        printf '\nloader:'
        md5sum "$SCRIPTDIR/modloader.sh" "$SCRIPTDIR/lib.sh" 2> /dev/null || printf 'n/a'
    } | md5sum | cut -d ' ' -f 1
}

working_is_current() {
    [ -f "$WORKDIR/.modstamp" ] || return 1
    [ "$(cat "$WORKDIR/.modstamp" 2> /dev/null)" = "$(fingerprint)" ]
}

rebuild() {
    [ -d "$BASEDIR" ] || error "Base tree not found at $BASEDIR - run port.sh first."
    [ -f "$BASEDIR/.stamp" ] || error "Base tree is incomplete (missing .stamp) - run port.sh again."
    if game_is_running; then
        error "DELTARUNE appears to be running - close the game before rebuilding."
    fi

    log "Rebuilding the working tree at $WORKDIR ..."
    # Build in a temp dir and swap in only on success, so a failing rebuild
    # can never leave the last good working tree broken.
    rm -rf "${WORKDIR}".new.* 2> /dev/null || true
    NEWWORK="${WORKDIR}.new.$$"
    rm -rf "$NEWWORK"
    mkdir -p "$NEWWORK"
    cp -a "$BASEDIR/." "$NEWWORK/"

    local mod patch target rel
    local applied=0
    while IFS= read -r mod; do
        [ -n "$mod" ] || continue
        log "Applying mod: $mod"
        applied=1

        # 1) full-file overrides
        if [ -d "$MODSDIR/$mod/files" ]; then
            cp -a "$MODSDIR/$mod/files/." "$NEWWORK/"
            for rel in "${DATA_FILES[@]}"; do
                if [ -e "$MODSDIR/$mod/files/$rel" ]; then
                    warn "Mod '$mod' fully replaces $rel."
                    warn "It must have been made from a deltaport-patched game.unx, or chapter switching will break!"
                fi
            done
        fi

        # 2) hdiffpatch deltas, in filename order
        if [ -d "$MODSDIR/$mod/patches" ]; then
            for patch in "$MODSDIR/$mod"/patches/*.hpatch; do
                if target=$(patch_target "$(basename "$patch")"); then
                    if hpatchz -f "$NEWWORK/$target" "$patch" "$NEWWORK/$target"; then
                        log "  $(basename "$patch") -> $target"
                    else
                        # A failed hpatchz means the source data no longer
                        # matches - this usually means an EARLIER mod replaced
                        # this file with a version made from the original
                        # (unpatched) data. Skip the patch but keep building.
                        warn "Mod '$mod': failed to apply '$(basename "$patch")' to $target (source data does not match - an earlier mod likely replaced this file with one made from unpatched data). Skipping this patch."
                    fi
                else
                    warn "Mod '$mod': cannot apply '$(basename "$patch")' (expected names like 00-chapterselect.hpatch, and the chapter must exist) - skipping."
                fi
            done
        fi
    done < <(list_enabled_mods)

    if [ "$applied" = "0" ]; then
        log "No enabled mods - the working tree is a clean copy of the base game."
    fi

    fingerprint > "$NEWWORK/.modstamp"
    rm -rf "$WORKDIR"
    mv "$NEWWORK" "$WORKDIR"
    NEWWORK=""
    log "Working tree is up to date."
    return 0
}

status() {
    if working_is_current; then
        log "Working tree is up to date."
    else
        log "Working tree is missing or stale - it will be rebuilt automatically on the next game launch,"
        log "or you can run: $DELTAPORTDIR/modloader.sh rebuild"
    fi
    return 0
}

list_mods() {
    [ -d "$MODSDIR" ] || { log "No mods installed yet. (The mods folder is $MODSDIR)"; return 0; }
    local mod state
    while IFS= read -r mod; do
        [ -n "$mod" ] || continue
        state="enabled "
        case "$mod" in
            *.disabled) state="DISABLED" ;;
        esac
        printf '[%-8s] %s\n' "$state" "$mod"
    done < <(find "$MODSDIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
    return 0
}

check_mods() {
    [ -d "$MODSDIR" ] || { log "No mods folder yet - nothing to check. (It is created when you run port.sh)"; return 0; }

    local f mod patch
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        warn "Stray file in mods/ (files must live inside a mod folder): $f"
    done < <(find "$MODSDIR" -mindepth 1 -maxdepth 1 -type f ! -name 'README.md' -printf '%f\n')

    while IFS= read -r mod; do
        [ -n "$mod" ] || continue
        if [ ! -d "$MODSDIR/$mod/files" ] && [ ! -d "$MODSDIR/$mod/patches" ]; then
            warn "Mod '$mod' contains neither a files/ nor a patches/ folder - it will do nothing."
        fi
        if [ -d "$MODSDIR/$mod/patches" ]; then
            for patch in "$MODSDIR/$mod"/patches/*.hpatch; do
                if patch_target "$(basename "$patch")" > /dev/null; then
                    :
                else
                    warn "Mod '$mod': patch '$(basename "$patch")' has an unrecognized target (expected NN-chapter_XX.hpatch with NN=00..05, and the chapter must exist)."
                fi
            done
        fi
    done < <(find "$MODSDIR" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort)
    return 0
}

main() {
    local cmd="${1:-status}"
    case "$cmd" in
        status) status ;;
        rebuild) install_mods_readme; rebuild ;;
        list) list_mods ;;
        check) check_mods ;;
        fingerprint) fingerprint ;;
        help | -h | --help) usage ;;
        *)
            usage
            exit 1
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
