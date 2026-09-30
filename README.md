# OpenQBORG

An open source player and world editor for **QBORG** worlds: the tile-based
3D spaces CYBERWORLD International Corporation put on the web from 1999 to
2003 (Pokémon 2000 Adventure, Zeta Quest 3D, The Olympiad, ...). Both are
built with Godot 4.

* **OpenQBORG Player** (`player/`) opens `borg://` (HTTP, port 80) and
  `borgs://` (HTTPS/TLS, port 443) addresses and local `.borg` files.
* **OpenQBORG Editor** (`editor/`) is a from-scratch take on CYBERWORLD's
  authoring tool: you paint worlds live in a 3D viewport.

Neither contains CYBERWORLD code or assets. The format was worked out from
surviving worlds; see [docs/FORMAT.md](docs/FORMAT.md).

## Features

**Player**
* **A built-in web browser** (Chromium): type any web address, or a bare
  `example.com`, and it opens in place of the 3D view with back, forward and
  reload. Links to `borg://` or `.borg` addresses on any site lead back into
  3D, even when the server sends the `.borg` as a download. Only a world's own
  pages may change it through `window.external`.
* A menu bar with **File** (open a .borg file, open an address, reload, back),
  **Bookmarks** and **Help**. The window resizes freely, and the side pane is
  on a draggable splitter.
* **Bookmarks** come with the example worlds and with original CYBERWORLD
  worlds that still survive online in the Internet Archive's Wayback Machine
  (Zeta Quest 3D, complete; the CYBERWORLD Olympiad, partly archived) or
  kept whole in Internet Archive items (Pokémon 2000 Adventure, straight
  from its ZIP). New defaults reach existing bookmark files, and ones you
  remove stay removed. Bookmarks are written as soon as they change, and again
  on exit if a save failed.
* Friendly to busy servers: failed downloads are retried with backoff
  (honouring `Retry-After`), the Wayback Machine gets two connections at a
  time, and archived files are cached on disk, so a world cut short by
  throttling fills in on the next visit and revisits are instant.
* Files that don't arrive (a busy or rate-limiting server) keep being asked
  for in the background while you explore, and the world is patched in place
  as they come in.
* Pages of archived worlds are proxied through the player's loopback page
  server, so they get real file types and folder paths (archive.org serves
  HTML inside ZIPs as plain text), the disk cache, and Flash through Ruffle.
* CWS3 sprite behaviours: sprites that react to the mouse pointer, to clicks
  and to the player coming near, as authored in the original worlds.
* Walls, floors, ceilings, animated and multi-sided sprites, sprites
  painted onto wall faces, the panorama backdrop, and the nav map with a
  "you are here" marker.
* Links behave as they did originally: doorways (`gtw`), side-pane info
  pages (`gtw2`/`gtw3`), `.url` shortcuts, and `borg://cmd.prev` /
  `borg://cmd.web@`.
* Pages drive the world through `window.external` as they did in IE:
  `MoveTile()`, `TileValue()` (sprite size, visibility and animation, wall
  heights, how links fire, entry points), `UserToPoint()` and the rest, with
  getters answering at once. See [docs/FORMAT.md](docs/FORMAT.md).
* **HTML5 world pages** rendered by Chromium via
  [godot-cef](https://github.com/dsh0416/godot-cef). The original browser
  embedded IE-era HTML; pages now get modern HTML, CSS and JS, plus the
  classic `pushTo3D()` / `window.external.MoveTile()` bridge. JavaScript `alert()`/`confirm()`/
  `prompt()` appear as Godot dialogs (they can't block, so `confirm()` answers
  OK and `prompt()` returns its default). Pages from
  local worlds are served over loopback so their cookie-based save games work.
* **Web surfaces**: pages, HTML5 video and SWF on walls, floors and ceilings,
  spanning as many tiles as you like (a cinema screen), with sound coming from
  the screen and clicks passed to the page. Worlds declare them (`<srf>`) or
  scripts create them, including script-made HTML5 screens that talk to the
  world script. The editor places them with a Surfaces dialog.
* **Flash** in world pages plays through [Ruffle](https://ruffle.rs), an open source
  Flash emulator in WebAssembly, sandboxed inside Chromium (`tools/fetch-assets.sh
  ruffle`). It loads only on pages that contain Flash. Where Ruffle can't
  play a movie inside the page (the page's security policy blocks it, or it
  fails to load), the player draws its own Ruffle view over that spot instead,
  kept aligned as the page scrolls. Local pages you open directly are served
  over loopback like world pages, so they behave as they would on a server.
* **Animated GIF, APNG and Motion JPEG sprites**: frames, timing and
  transparency come from the file (an APNG can still carry CWS3 behaviours).
* **Animated textures**: floor, ceiling and wall images, the backdrop and the
  emblem can be animated GIFs (as in the original), APNGs or Motion JPEGs.
  Floors and ceilings step through a texture array in the shader, so it stays
  one draw call.
* **Sound**: looping positional sound tiles and music regions in almost any
  format: WAV, Ogg Vorbis and MP3 natively, plus Opus (`.opus`/`.oga`), AAC
  (`.aac`/`.m4a`), FLAC, ALAC, WMA, AIFF, WebM/Matroska audio and ADPCM WAV
  through the bundled FFmpeg media extension. MIDI music plays through a
  General MIDI SoundFont
  ([godot-midi-player](https://github.com/arlez80/godot-midi-player-g4)
  with GeneralUser GS, a GS bank like the one the original relied on in Windows).
* Page audio (HTML5 `<audio>`, WebAudio) is captured from Chromium into
  Godot's mixer, so it follows the player's volume and goes quiet when its page
  is hidden.
* `borgs://` verifies certificates and never downgrades to plain HTTP,
  including for `borg://` links on pages that were loaded over TLS.

**Editor**
* Live 3D viewport using the same renderer as the player: orbit, pan, zoom,
  paint any layer, Ctrl+click to pick a value, and a walk-through preview.
* **Picture palettes**: the Floor, Ceiling, wall-texture and Objects layers show
  the world's own tiles, strips and sprites as a grid of previews (names on
  hover), and the Resources list previews sprites too.
* **Sprite behaviours** (Resources → Sprites → Behaviour…, or double-click a
  sprite in the Objects palette): edit the animation and the CWS3 mouse-over,
  click and proximity behaviours with a live preview and a Try button per
  behaviour. The Walk preview reacts to hover, clicks and proximity.
* **Audio testing**: ▶ Test (or double-click) on the Sounds and Music palettes
  and ▶ Play in Resources play what a tile would. The Walk preview plays music
  regions and positional sound tiles as the player does, and a "Hear sounds"
  toggle lets sound tiles play while you edit.
* Colour overlays for the invisible layers (no-walk, links, sounds, music,
  script triggers), undo/redo, and world properties.
* Resource lists (sprites, links, sounds, music, scripts, nav map, emblem),
  texture references with automatic tile detection, and MIDI preview.
* **Starter library** (Library tab): 14 sprites (one an animated GIF campfire), 11 floor tiles, 7 ceiling tiles and 7 wall strips (floors and
  walls in a still set and an animated GIF set with moving water, lava and a
  waterfall), a sky backdrop, 6 sound loops, 3 music tracks, and page and script
  templates, all original and free to use. New worlds start furnished from it,
  and whatever a world uses is copied into the world's own folders when you
  save, so it stays self-contained.
* Built-in JavaScript editor for world scripts, plus "Play in Player".
* Opening and saving a classic world leaves its map layers byte-identical.

**Example worlds**: a classic courtyard, a 128×128 island and a scripted
puzzle vault, all generated from code. See [examples/](examples/README.md).

**New, backward-compatible extensions**
* `<size>`: worlds from 16×16 up to **256×256** tiles. Floors and ceilings
  render as one MultiMesh each, so big worlds stay fast.
* Modern audio formats in `<wav>` and `<mid>` lists (the original only knew
  `.wav` and `.mid`).
* `<js>`: **JavaScript world scripting** with events, tile editing,
  teleports and pages ([docs/SCRIPTING.md](docs/SCRIPTING.md)).

Classic worlds never gain these elements unless you use them.

## Getting started

Requires Godot **4.5+** (developed on 4.7).

```sh
git clone --recursive https://github.com/kramlat/OpenQBORG
cd OpenQBORG
tools/fetch-assets.sh soundfont   # GeneralUser GS, ~31 MB (MIDI music)
tools/fetch-assets.sh ruffle      # Ruffle Flash emulator for pages, ~28 MB
tools/fetch-assets.sh cef         # godot-cef runtime for the player, ~560 MB
                                  # (or build it from source: tools/fetch-assets.sh cef --source)
tools/build-media-ext.sh          # FFmpeg media extension (AAC, Opus, FLAC, ...,
                                  # animated GIF/APNG/MJPEG textures)

godot --path player -- examples/borgs/hello.borg   # the example worlds
godot --path player -- borgs://example.org/world/level.borg
godot --path editor -- path/to/level.borg
tools/install-desktop.sh          # optional: open borg:// links and .borg files
```

### Building a copy

```sh
tools/build-release.sh            # exports both apps to build/linux/ (with the examples)
tools/install-system.sh           # installs it to /opt/openqborg (asks for your password)
tools/install-system.sh --uninstall
```

The system install puts launchers in `/usr/local/bin` and desktop entries, the
`.borg` MIME type and icons under `/usr/local/share`, and makes the player
your default for `.borg` files and `borg://` / `borgs://` links. Its desktop
entries run `/opt/openqborg/openqborg-player` and `-editor` directly and use
the `player.svg` / `editor.svg` shipped in the package. To register the build
for just your user instead, without root, run `tools/install-desktop.sh`.

`build-release.sh` uses `godot-mono` when it's installed (else `godot`; override
with `GODOT=...`). Both editors work, since OpenQBORG has no C#. It needs the
export templates for that editor. If your distro installed
them system-wide (as Arch does), it links them into your user data folder.
The copy ships the LGPL-only FFmpeg build next to the media extension.
Windows export presets are included, but a Windows build still needs the
godot-cef and media extension binaries for Windows.

The player runs without godot-cef too. In that case, world pages open in
your web browser and world scripts don't run. Without the media extension,
WAV, Ogg Vorbis, MP3 and MIDI still play, and textures show without animation
(GIFs need the extension).

### Player controls

| Key | Action |
|---|---|
| ↑ ↓ / W S | Walk |
| ← → | Turn |
| A D | Strafe |
| PgUp PgDn | Look up / down |
| Hold right mouse | Free look (up to ±80°; the original stopped at ±36°) |
| Ctrl+O / Ctrl+L | Open a file / type an address |
| Ctrl+D | Bookmark this world |
| F5 / Alt+← | Reload / previous world |
| Click | Follow the link on a tile (in 3D or on the nav map) |

### Editor controls

| Input | Action |
|---|---|
| Left drag | Paint the selected layer/value |
| Ctrl+click | Pick the tile's value |
| Right drag | Orbit |
| Middle drag / Shift+right drag | Pan |
| Wheel | Zoom |
| Ctrl+Z, Ctrl+Shift+Z / Ctrl+Y | Undo, redo |
| Ctrl+S / Ctrl+O / Ctrl+N | Save / open / new |
| Walk, then Esc | Walk-through preview |

## Repository layout

```
player/                 Godot project: OpenQBORG Player
editor/                 Godot project: OpenQBORG Editor
  library/              the starter library (generated, laid out like a world folder)
shared/openqborg_core/  Format, URL, sprite, world-building and music code,
                        linked into both projects as addons/openqborg_core
third_party/            godot-midi-player-g4 (MIT, linked as addons/midi) and
                        godot-cpp (MIT), as submodules
contrib/godot-cef/      godot-cef source (MIT, submodule pinned to the release the
                        player uses): build it with fetch-assets.sh cef --source
extensions/             openqborg_media GDExtension source (C++, FFmpeg)
shared/openqborg_media/ its .gdextension + built binaries, linked as addons/openqborg_media
soundfonts/             SoundFonts (fetched, not committed)
tools/                  fetch-assets.sh, install-desktop.sh, build-media-ext.sh,
                        build-ffmpeg-lgpl.sh, make_examples.gd
dist/                   .desktop entries, the .borg MIME type and its icon
docs/                   FORMAT.md, SCRIPTING.md
examples/               example worlds; tools/make_examples.gd generates them and
                        the editor's starter library
```

The shared code is included through symlinks, so on Windows enable
`core.symlinks` (developer mode) before cloning.

### Tests

```sh
godot --headless --path player --script res://addons/openqborg_core/tests/run_tests.gd -- path/to/world
```

With a world folder, every `.borg` in it is parsed and re-encoded. Each map
layer must come out byte-identical, and every sprite must decode.

## Not done yet

* One player window per `borg://` link (there is no single-instance handoff yet)

## Credits

* Format research: [jsborg](https://github.com/DoomTay/jsborg) by DoomTay,
  and preservation of the Pokémon 2000 assets by former CYBERWORLD employee
  Eddie Ruminski and the Internet Archive.
* [godot-cef](https://github.com/dsh0416/godot-cef) (MIT) by Delton Ding
* [godot-midi-player](https://github.com/arlez80/godot-midi-player-g4) (MIT) by Yui Kinomoto
* [GeneralUser GS](https://github.com/mrbumpy409/GeneralUser-GS) by S. Christian Collins

QBORG and CYBERWORLD are trademarks of their respective owners. This project
is not affiliated with them.

## License

OpenQBORG is free software under the **GNU General Public License v3.0 or
later**; see [LICENSE](LICENSE).

Third-party components keep their own licenses: godot-cef, godot-cpp and
godot-midi-player are MIT, CEF/Chromium is BSD-style, GeneralUser GS has its
own permissive license, and FFmpeg is LGPL-2.1-or-later. Release builds bundle
an LGPL-only, audio-only FFmpeg built by `tools/build-ffmpeg-lgpl.sh` and link
it dynamically. To rebuild the exact godot-cef a release uses, run
`tools/fetch-assets.sh cef --source`.
