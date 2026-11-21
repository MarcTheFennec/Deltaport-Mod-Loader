# deltaport mod loader
<img width="160rem" alt="deltaport logo" src=".github/deltaport.png" />[^1]

[![Build](https://github.com/MarcTheFennec/Deltaport-Mod-Loader/actions/workflows/build.yml/badge.svg)](https://github.com/MarcTheFennec/Deltaport-Mod-Loader/actions/workflows/build.yml)

> [!NOTE]
> This project is NOT affiliated with nor endorsed by Toby Fox, Fangamer, YoYo Games Ltd or Opera Norway AS.

A fork of [deltaport](https://github.com/pugdev3/deltaport) (an unofficial attempt at porting DELTARUNE[^2] to Linux) with two goals:

* **Your original game files are never touched.** The old deltaport renamed, moved and patched files inside your Steam game folder. This version installs everything in `~/.local/share/DELTARUNE/deltaport` instead: game data is *copied* and patched there, and music/videos are *linked* (not moved) from your game folder. Steam verification, game updates and the original files all just work.
* **A built-in Deltarune mod loader.** Drop mods into a `mods/` folder and they're applied automatically every time you launch the game (see [Modding](#modding-)).

This was originally made as a learning project for personal use; the upstream game also works fine under Proton.

This doesn't include any game data, you will need to own a copy of the game.

Flatpak Steam and immutable distros are not supported.

Only available for Linux x86_64

## Usage <img width="25rem" alt="ralsei dummy" src="https://github.com/user-attachments/assets/a270cef6-4ec3-4e36-8d18-4df6b297384b" />
> [!IMPORTANT]
> Check out [Supported versions](#supported-versions-) for which game versions you can use.

Download the latest release (built by GitHub Actions), extract it, and double-click `port.sh` or run in your terminal:

```shell
you@puter ~>  ./port.sh
```

Follow the instructions on screen. The port is installed in `~/.local/share/DELTARUNE/deltaport` (the folder is self-contained, so you can delete the extracted release afterwards).

To launch the game:

* **Through Steam:** DELTARUNE → Properties → Launch Options → put this:
  ```
  ~/.local/share/DELTARUNE/deltaport/DELTARUNE.sh -- %command%
  ```
* **Directly:** run `~/.local/share/DELTARUNE/deltaport/DELTARUNE.sh` in a terminal.

When Steam updates the game, run `./port.sh` (or `~/.local/share/DELTARUNE/deltaport/update.sh`) again to update the port to the latest supported version. Your installed mods are kept.

> [!NOTE]
> If you have issues with keyboard input, create a file named `.hide_input` in the deltaport directory (`~/.local/share/DELTARUNE/deltaport/.hide_input`), it should hide all `/dev/input` devices from the runner (although no controllers should work).

## Modding <img width="30rem" alt="kris doing two" src="https://github.com/user-attachments/assets/973789b5-0c1b-4577-a24f-f7cb7314eb6c" />

Mods are installed in:

```
~/.local/share/DELTARUNE/deltaport/mods/
```

Every launch, the game runs from a *working tree* that is built from the patched base game + all **enabled** mods, in folder-name order. The build is cached and only rebuilt when the base or a mod changes, so launching is instant otherwise. Neither your original game files nor the base tree are ever modified by mods.

### Mod layout

```
mods/
└── 10-my-mod/
    ├── files/     (optional) full-file overrides, copied over the game tree
    └── patches/   (optional) hdiffpatch (.hpatch) deltas, applied in filename order
```

**`files/`** — everything under `files/` is copied (overwriting, keeping relative paths) into the game tree. To replace a game data file with a fully modded version (e.g. made with UndertaleModTool) drop it at the exact path:

```
files/assets/game.unx                    (chapter select)
files/chapter1_linux/assets/game.unx     (chapter 1)
files/chapter2_linux/assets/game.unx     (chapter 2)
...
```

> [!IMPORTANT]
> A full `game.unx` replacement **must** be made from a **deltaport-patched** data file (the ones in `~/.local/share/DELTARUNE/deltaport/base/` or `working/`), NOT from the original `data.win` — otherwise the Linux chapter-switching support is lost and the game will not be able to switch chapters.

**`patches/`** — each `.hpatch` file is applied with `hpatchz` to the matching data file, in filename order. Name the file after the chapter it patches:

```
patches/00-chapterselect.hpatch
patches/01-chapter_01.hpatch
patches/02-chapter_02.hpatch
patches/03-chapter_03.hpatch
patches/04-chapter_04.hpatch
patches/05-chapter_05.hpatch
```

Only include the chapters your mod touches.

### Order and enabling

* Mods are applied in lexicographic folder-name order — prefix with numbers (`00-`, `10-`, `20-`, ...).
* To **disable** a mod without deleting it, rename the folder with a `.disabled` suffix (e.g. `10-my-mod.disabled`).
* The Console Borders mod (if installed) lives in `00-nxrune` and applies before your mods.

### Making a patch mod

Create the patch between the base file of the chapter you mod and your modded file (you need [hdiffpatch](https://github.com/sisong/HDiffPatch)):

```shell
hdiffz base/assets/game.unx my-modded-game.unx 10-my-mod/patches/00-chapterselect.hpatch
```

### Making a full-file mod (UndertaleModTool)

1. Open a **deltaport-patched** data file with UndertaleModTool (on Linux, run UMT through Wine; see the [UMT wiki](https://github.com/UnderminersTeam/UndertaleModTool)).
2. Make your changes and save the `game.unx`.
3. Drop it into your mod at `files/assets/game.unx` (and/or `files/chapterN_linux/assets/game.unx`).

### Managing mods

```shell
~/.local/share/DELTARUNE/deltaport/modloader.sh list        # list installed mods
~/.local/share/DELTARUNE/deltaport/modloader.sh check       # validate your mods' layout
~/.local/share/DELTARUNE/deltaport/modloader.sh rebuild     # force a rebuild of the game
~/.local/share/DELTARUNE/deltaport/modloader.sh status      # is the working tree up to date?
```

### Console borders <img height="50rem" alt="kris and ralsei pushing each other" src="https://github.com/user-attachments/assets/ed1143c7-fd1d-440a-8100-137d2ff2f659" />

There is optional support for **[NXRUNE](https://gamejolt.com/games/nxrune/629072)**'s borders mod that enables console borders (cool dynamic borders around the screen exclusive to consoles) on Linux, especially useful for widescreen users.

To enable it, type `y` when prompted during `./port.sh` or run `./port.sh nxrune`. It's installed as the `00-nxrune` mod (so it applies before your other mods); remove or `.disabled`-rename `mods/00-nxrune` to get rid of it.

Currently it's only available for versions: 0.0.244-53 (only includes patches for the latest per release!)

<img width="800em" alt="demo of deltaport with console borders mod" src="https://github.com/user-attachments/assets/c231df57-94fe-47a3-bf29-080a2b22feb9" />

## Other versions <img width="30rem" alt="kris doing two" src="https://github.com/user-attachments/assets/973789b5-0c1b-4577-a24f-f7cb7314eb6c" />

If you're reading this in the future, you may find yourself having a different current version than the one supported here, in that case, here's how you can download a specific version of the game to be able to use the port.

Open your terminal program, and type `steam -console`, it should look like this:
```shell
pug@puter ~> steam -console
```
After opening, click the Console tab:

<img width="617" height="72" alt="steam with console tab" src="https://github.com/user-attachments/assets/cf77220e-07f4-4a34-8d18-4df6b297384b" />

Now, go to **[here on SteamDB](https://steamdb.info/depot/1671212/manifests/)**, you should find a list of manifests (versions) sorted by upload date, choose the one that applies

<img width="378" height="54" alt="steamdb with two copy formats" src="https://github.com/user-attachments/assets/6e3eb9c4-9109-43b2-8044-bf274e28c2f0" />

Make sure the copy format is: `Steam console` and click copy.

Back on Steam, go ahead and paste what you copied, it should look like this:

<img width="800em" alt="steam window with console tab" src="https://github.com/user-attachments/assets/09828c17-e84f-4a62-8167-7c1a53f49c47" />

After this, hit enter, it should start downloading the depot.

<img width="800em" alt="steam console window with dolphin file manager" src="https://github.com/user-attachments/assets/90828c17-e84f-4a62-8167-7c1a53f49c47" />

You may notice that at the end of the path `\steamapps\content\app_1671210\depot_1671212` Steam puts `\` there for some reason, just change it to `/` and open it in your file browser of choice, you should have a copy of the game, run `port.sh` and select this directory and you're good to go!

## Supported versions <img width="35rem" alt="happy cat" src="https://github.com/user-attachments/assets/8dc9e7c9-6ccc-4dd3-bdb9-28a138d09b85" />

Here is a list of the currently supported versions by this port (release archives are built by GitHub Actions; the tables below link the original deltaport releases which carry the same base patches):

| Version  | MD5 Checksum  | Launch date | Release/branch |
| -------- | ------------- | ----------- | -------------- |
| [v1.01C and older](https://steamdb.info/patchnotes/18791270/) <img width="35rem" alt="gerson saying i'm old" src="https://github.com/user-attachments/assets/6839c8c1-4119-4c0e-bcc0-124690ed78de" /> | `bdd3fbeb0f51a7b522ca296092a20853` | < 9 June 2025 | [legacy](https://github.com/pugdev3/deltaport/tree/legacy) (branch) |
| [v1.04](https://steamdb.info/patchnotes/19477244/) | `9d1fea9de81219ea7304f32f1ae7a878` | 5 August 2025 | [v0.01](https://github.com/pugdev3/deltaport/releases/download/v0.01/deltaport-v0.01.tar.xz) |
| [v1.05 (deltarune105 beta)](https://bsky.app/profile/undertale.com/post/3lxbfrqodwc2l) | `5d3e158dbe6888fbf24471019fbde3c9` | 26 August 2025 | [v0.01](https://github.com/pugdev3/deltaport/releases/download/v0.01/deltaport-v0.01.tar.xz) |
| [v0.0.247](https://steamdb.info/patchnotes/24122389/) | `908643b7593b000f5b6c61bb484d086a` | 9 July 2026 | this repo (releases) |
| [v0.0.250](https://steamdb.info/patchnotes/24327867/) | `1f00145d681f830f1249d9493ba8f579` | 22 July 2026 | this repo (releases) |
| [v0.0.253](https://steamdb.info/patchnotes/24484059/) | `83a5a14f9b92a20f21fb9ec6c8528469` | 31 July 2026 | this repo (releases) |

Other versions can be upgraded using the update script + Steam update

> [!NOTE]
> If you're migrating from an **older deltaport** (the one that ported the game in-place inside your Steam folder): this version needs the game in its original state. Restore the original game files (re-download/re-install the game — see above) and run `./port.sh` again.

## How it works <img width="35rem" alt="thinking pug" src="https://github.com/user-attachments/assets/8ce7e9a3-9809-4c02-2d67253a6cab1" />

As GameMaker: Studio exports game code as bytecode instead of native code, we're able to run the game on any platform as long as we have a compatible runner (the GMS runner).

The game is divided into chapters, each with their own game folder and data. Internally, the game switches between them using `game_change()`, which is unsupported on Linux. As a workaround, the game's code is patched (with hdiffpatch) so that when chapters are switched, an empty trigger file is created in DELTARUNE's save directory:

```
~/.config/DELTARUNE/deltaport_chapter#   <- chapter number
```

`DELTARUNE.sh` watches that directory (inotify) and launches the requested chapter, replicating `game_change()`.

This fork's layout (the original game folder is never modified):

```
<your steam game folder>/          <- NEVER modified
    data.win, mus/, chapter1_windows/, ...

~/.local/share/DELTARUNE/deltaport/   <- everything deltaport owns (self-contained)
    port.sh  update.sh  modloader.sh  DELTARUNE.sh  lib.sh  deps.sh
    files/patches/...                <- base patches + nxrune mod patches
    deltarune                        <- the GMS Linux runner
    .gamedir                         <- path of your untouched game folder
    base/                            <- ported tree: game data COPIED + base-patched,
    |    assets/game.unx                  music/videos LINKED (symlinks)
    |    assets/mus/ -> game files
    |    chapter1_linux/ ...
    working/                         <- base + your MODS (rebuilt on demand);
    |    ...                             the game actually runs from here
    mods/                            <- your mods (00-nxrune, 10-my-mod, ...)
```

Saves (and the chapter-switch trigger files) still live in `~/.config/DELTARUNE`.

## Steam Cloud <img width="30rem" alt="cloud" src="https://github.com/user-attachments/assets/ed1143c7-fd1d-440a-8100-137d2ff2f659" />

There is optional Steam Cloud saves support: type `y` when prompted during `./port.sh`, or run `./port.sh steamcloud` on an existing install.

## Building (GitHub Actions) <img width="35rem" alt="happy cat" src="https://github.com/user-attachments/assets/8dc9e7c9-6ccc-4dd3-bdb9-28a138d09b85" />

This repo is built with [GitHub Actions](.github/workflows/build.yml):

* **On every push/PR:** the shell scripts are linted with ShellCheck.
* **On tag push (`v*`)** or manual dispatch: `deltaport-mod-loader-<version>.tar.gz` / `.tar.xz` archives + a `SHA256SUMS` file are packaged (with a sanity check of the archive contents) and published as a GitHub release.

To build a release locally: `git tag v0.01 && git push origin v0.01`.

## Dependencies <img width="35rem" alt="bloated susie" src="https://github.com/user-attachments/assets/215a2ccb-1e54-44e6-bd19-253a6524fc41" />

A `deps.sh` file is already included in the repo and is used by the `port.sh` script.

It should automatically install all the necessary dependencies for you, unless you're on some niche distro.

That being said, it is required to have:
* `hpatchz` - From [HDiffPatch](https://github.com/sisong/HDiffPatch), used for patching the game and applying mod patches
* `inotifywait` - Used to listen for trigger files in the save directory, can be found in distros by the name `inotify-tools`
* `ffmpeg4` - Used to play videos on Chapter 3/5, note that GameMaker 2022 LTS requires specifically FFmpeg4 to work
* `ffmpeg` - Needed to fix video playback in Chapter 5
* `wget`, `curl`, `jq`, `unzip` - Used to download some files
* `git` - Used on Arch *btw* to install the AUR package for hdiffpatch

## Known issues <img width="35rem" alt="shocked ralsei" src="https://github.com/user-attachments/assets/f081e38d-a5a1-4c24-a34e-de28e8c98eb9" />

* If you have an older version of deltaport and your music/audio is gone, go to your save directory: `~/.config/DELTARUNE` and change line **569/570** from a `,` to a `.`
* Controller input may not work
* An annoying dog may appear during gameplay
* A mod that fully replaces a `game.unx` must be based on a deltaport-patched file (see the [Modding](#modding-) section) — otherwise chapter switching will be broken
* After a game update, your mods keep working as-is, but mods that patch code/addresses may need an update from their author for the new game version

## Credits <img width="25rem" alt="cute smile" src="https://github.com/user-attachments/assets/1343f82d-d8cc-40b6-864e-2bd9236814b1" />

[Toby Fox](https://twitter.com/tobyfox) - Creator of this awesome game

[pugdev3/deltaport](https://github.com/pugdev3/deltaport) - The amazing base port this fork is built on

[UndertaleModTool](https://github.com/UnderminersTeam/UndertaleModTool) - The goats who created this amazing tool that made modding this port possible

[Flibitijibibo](https://flibitijibibo.com/) - This guy with the name I can't pronounce that provided the FFmpeg4 libs for initial video playback support

[Iruzz](https://github.com/IruzzArcana) - For the borders mod used in this port

(Other people I may have forgot to put here)

[^1]: The DELTARUNE logo and characters are copyright of Toby Fox, being used under fair use.
[^2]: DELTARUNE is a trademark of Royal Sciences LLC
