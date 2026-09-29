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
* Walls, floors, ceilings, animated and multi-sided sprites, sprites
  painted onto wall faces, the panorama backdrop, and the nav map with a
  "you are here" marker.
* Links behave as they did originally: doorways (`gtw`), side-pane info
  pages (`gtw2`/`gtw3`), `.url` shortcuts, and `borg://cmd.prev` /
  `borg://cmd.web@`.
* **HTML5 world pages** rendered by Chromium via
  [godot-cef](https://github.com/dsh0416/godot-cef). The original browser
  embedded IE-era HTML; pages now get modern HTML, CSS and JS, plus the
  classic `pushTo3D()` / `window.external.MoveTile()` bridge. Pages from
  local worlds are served over loopback so their cookie-based save games work.
* **Sound**: looping positional `.wav`/`.ogg`/`.mp3` tiles, and MIDI music
  regions played through a General MIDI SoundFont
  ([godot-midi-player](https://github.com/arlez80/godot-midi-player-g4)
  with GeneralUser GS, a GS bank like the one the original relied on in Windows).
* `borgs://` verifies certificates and never downgrades to plain HTTP,
  including for `borg://` links on pages that were loaded over TLS.

**Editor**
* Live 3D viewport using the same renderer as the player: orbit, pan, zoom,
  paint any layer, Ctrl+click to pick a value, and a walk-through preview.
* Colour overlays for the invisible layers (no-walk, links, sounds, music,
  script triggers), undo/redo, and world properties.
* Resource lists (sprites, links, sounds, music, scripts, nav map, emblem),
  texture references with automatic tile detection, and MIDI preview.
* Built-in JavaScript editor for world scripts, plus "Play in Player".
* Opening and saving a classic world leaves its map layers byte-identical.

**New, backward-compatible extensions**
* `<size>`: worlds from 16×16 up to **256×256** tiles. Floors and ceilings
  render as one MultiMesh each, so big worlds stay fast.
* `<js>`: **JavaScript world scripting** with events, tile editing,
  teleports and pages ([docs/SCRIPTING.md](docs/SCRIPTING.md)).

Classic worlds never gain these elements unless you use them.

## Getting started

Requires Godot **4.5+** (developed on 4.7).

```sh
git clone --recursive https://github.com/kramlat/OpenQBORG
cd OpenQBORG
tools/fetch-assets.sh soundfont   # GeneralUser GS, ~31 MB (MIDI music)
tools/fetch-assets.sh cef         # godot-cef runtime for the player, ~560 MB
                                  # (or: tools/fetch-assets.sh cef /path/to/godot-cef)

godot --path player -- borgs://example.org/world/level.borg
godot --path editor -- path/to/level.borg
tools/install-desktop.sh          # optional: open borg:// links and .borg files
```

The player runs without godot-cef too. In that case, world pages open in
your web browser and world scripts don't run.

### Player controls

| Key | Action |
|---|---|
| ↑ ↓ / W S | Walk |
| ← → | Turn |
| A D | Strafe |
| PgUp PgDn | Look up / down |
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
shared/openqborg_core/  Format, URL, sprite, world-building and music code,
                        linked into both projects as addons/openqborg_core
third_party/            godot-midi-player-g4 (submodule, MIT), linked as addons/midi
soundfonts/             SoundFonts (fetched, not committed)
tools/                  fetch-assets.sh, install-desktop.sh
dist/linux/             .desktop entries and the .borg MIME type
docs/                   FORMAT.md, SCRIPTING.md
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

* `CWS3` mouse-over, click and proximity sprite animations
* `window.external.tileValue()` (sprite resizing from pages)
* Flash (`.swf`) in pages. [Ruffle](https://ruffle.rs) is the likely route.
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

MIT, see [LICENSE](LICENSE).
