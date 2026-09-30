# The .borg format

QBORG worlds were authored with CYBERWORLD International Corporation's tools
between 1999 and 2003. There is no public specification; this document
collects what is known from the surviving worlds, from
[jsborg](https://github.com/DoomTay/jsborg)'s reverse engineering, and from
building OpenQBORG. Corrections are welcome.

## World folder layout

```
borgs/
  level.borg        the world (XML)
  domains/          floor/ceiling/wall images, nav map, emblem, backdrop, .url links
  objects/          .sprite and .ctrl objects
  media/            .wav sounds, .mid music
  scripts/          .js world scripts (OpenQBORG extension)
  html/             pages shown beside the world (convention, not required)
```

File references are resolved case-insensitively for local worlds, because the
original worlds were made on Windows.

## Document structure

```xml
<?xml version="1.0"?>
<brg VER="3.0" BS="00627d">
  <rdf:RDF ...> Dublin Core: Title, Description, Date, Type, Rights </rdf:RDF>
  <gen TP="fffffffe" SP="96" HT="40" APP="3" MFG="cb">
    <tok MN="...">...</tok>          authoring token (kept verbatim)
    <pos> 79 7f 10 e21 </pos>        start: x y eye-height angle
    <web> 107 9e 1 0 8 </web>        unknown (kept verbatim)
  </gen>
  <map RL="10"> one element per layer </map>
  <ext> asset lists </ext>
</brg>
```

All numbers are hexadecimal.

| Field | Meaning |
|---|---|
| `HT` | Ceiling / full wall height in quarter pixels (`40` → 256 px = one tile) |
| `SP` | Walk speed (`96` = 150 is typical) |
| `pos` x, y | Start position, 64 units per tile. y counts from the *bottom* of the map |
| `pos` eye | Eye height in quarter pixels |
| `pos` angle | Facing, 4096 units per turn; yaw = 270° − angle·360/4096 |

## Map layers

Each layer is a run-length encoded list of tokens. The last two hex digits
are the tile value and anything before them is the repeat count: `10000` is
256 × `00`, `e01` is 14 × `01`, `3ff` is 3 × `ff`.

Tiles stream from the bottom row of the map up, left to right. **Floor and
ceiling layers (`flr`, `cei`) are stored transposed and mirrored**: the
stream walks up each column, starting at the left.

| Layer | Value |
|---|---|
| `wal` | 0 walkable, *n* blocked; for textured walls, *n*−1 picks the wall strip |
| `hgt` | Wall block height in quarter pixels (0 = no visible block) |
| `flr` | Floor tile index into the floor image, `ff` = none |
| `cei` | Ceiling tile index, `ff` = none |
| `obj` | 1-based index into `<spr>` |
| `gtw` | 1-based index into `<gtw>`: stepping on it follows the link (world or page) |
| `gtw2` | 1-based index into `<gtw2>`: page shown beside the world while inside the region |
| `wav` | 1-based index into `<wav>`: looping positional sound (OpenQBORG also accepts Ogg, Opus, MP3, AAC, FLAC, ...) |
| `mid` | 1-based index into `<mid>`: background music region (MIDI; OpenQBORG also accepts any audio format) |
| `ent`, `lnk`, `lnk2` | Not fully understood; preserved verbatim |

## Assets (`<ext>`)

* `<spr>`, `<gtw>`, `<gtw2>`, `<gtw3>` (default page), `<wav>`, `<mid>`,
  `<nav>`, `<emb>`: lists of `<file HREF="..."/>`.
* `<flr>`, `<cei>`, `<wal>`: `<cfil HREF="image">offsets</cfil>`. Offsets are
  pixel offsets (`y * width + x`) of each tile. Floor and ceiling images are
  256 pixels wide stacks of 256×256 tiles. Wall images are 1024 wide, and each
  strip is stored sideways: the image's X axis runs up the wall from the
  floor, its Y axis along the wall, so turning a strip a quarter turn
  counter-clockwise stands it upright. (Confirmed by lettering on the walls
  of Zeta Quest 3D; every surviving world stores its walls as JPEG.)
* Any of these images may be **animated**. The original browser played
  animated GIFs; OpenQBORG also plays APNG and Motion JPEG (raw, AVI, MOV,
  multipart). Each frame is a whole image, so every tile or strip taken from it
  animates in step, and unchanged areas just look still. A GIF or APNG shows
  its first frame in software that doesn't animate it, so nothing breaks. Raw
  MJPEG has no frame timing and plays at 25 fps; use AVI or MOV to set a rate.
* `<bdp BC="bgr" POS="n">`: background colour (**BGR** hex) and an optional
  panorama `<file>` whose bottom edge sits `POS` pixels below the horizon
  (signed 32-bit). The panorama scrolls one image width per 90° of turning.
* `<pal>`: palette, unused by OpenQBORG, kept verbatim.

Links are either `.html` pages (relative to the `.borg`), Windows Internet
Shortcuts (`.url`, resolved against `domains/`; `URL=http://../html/x.html`
is a relative link), or bare world names (`name` → `name.borg`).

## Sprites

A `.sprite` is a PNG or JPEG. Its frames are stacked vertically, and its
top-left pixel is the transparent colour key. Metadata lives in a PNG
`cxBX` chunk or a JPEG APPn segment that starts with `CWS2` or `CWS3`,
followed by little-endian uint32 fields: cell count, cell width, cell
height, world Z, world Y, world X, flags (bit 2 = multi-sided), animate on
load, sides, world width, world height, repeat count, frame count, default
frame duration, wall visibility (N S W E as bits 3..0), unknown, then one
duration (ms) per frame. `CWS3` appends mouse-over/click/proximity animation
ranges (see below).

**JPEG sprites are stored upside down** (the tools wrote bottom-up bitmap rows
into the JPEG); flip them vertically before cutting frames. PNG sprites are
the right way up. The authoring tool's source sprites are BMPs followed by
`SP03` and the same fields as a CWS3 block.

### CWS3 behaviours

After the frame durations a CWS3 block continues with the proximity distance
(world pixels, 64 by default), 0, the group count (4) and the group size (6),
then four groups of `enabled, from, to, repeat, end, revert`:

| Group | Plays |
|---|---|
| general | always (moving only if "animate on load" is set) |
| mouse-over | while the pointer rests on the sprite |
| click | when the sprite is clicked (the tile's link is followed too) |
| proximity | while the viewer is within the proximity distance |

Frames run `from`..`to` (backwards if `from > to`), `repeat` times (0 = loop
while active), then hold frame `end` (-1 = return to the general group).
`revert` bit 0 returns to the general group when the trigger ends (the mouse
leaves, the viewer walks away); bit 1 when the animation stops. This layout
was confirmed against 156 CWS3 sprites in ten surviving worlds.

A sprite on a tile with a wall block (`hgt` > 0) is painted onto the block's
faces flagged in the visibility mask instead of standing as a billboard.

## borg:// URLs

| URL | Meaning |
|---|---|
| `borg://host/path.borg` | World over HTTP, port 80 |
| `borgs://host/path.borg` | World over HTTPS (TLS), port 443 |
| `borg://cmd.prev` | Page command: back to the previous world |
| `borg://cmd.web@URL` | Page command: show URL as a page |

Pages used `pushTo3D()`, which navigates to `borg://` + the page's own
directory + a relative `.borg` path. For pages loaded from disk, that
"host" is really a local path without its leading slash.

Pages could also call the host object `window.external` (IE matched its
names case-insensitively, and pages use both spellings). Coordinates are
1-based from the top-left.

| Call | Does |
|---|---|
| `GetVer()` | Browser version |
| `MoveTile(layer, fromX, fromY, toX, toY, keepOriginal)` | Move or copy a tile (layers `FLOOR`, `CEILING`, `WALL`, `SPRITE`, `NOWALK`, `LINK`, `LINK2`, `BORG`, `SOUND`, `MIDI`) |
| `TileValue(layer, x, y, option[, value])` | Read a value, or set it when `value` is given; -1 for bad coordinates (table below) |
| `UserToPoint(x, y, height, rotation, rotation, smooth)` | Move the viewer: `<pos>` units (64 per tile, y from the bottom, eye height in quarter pixels), rotation in degrees. With no arguments it returns `"x y height rotation"` |
| `BorgLocation()` | Address of the current world |
| `BrowserBrand()` | 0x0001 CYBERWORLD, 0x0020 Norstar Mall, 0x0040 Stan Lee Media, 0x0100 Pokémon |
| `BorgMfgType()` | The world's `APP`: 1 Consumer, 2 Prosumer, 3 Professional, 4 Professional Demo |

| `TileValue` layer, option | Value |
|---|---|
| `WALL`, 0 | Wall block height (the `hgt` value) |
| `SPRITE`, 0 | Sprite height, in quarter pixels (setting it scales proportionally) |
| `SPRITE`, 1 | Hidden (true hides) |
| `SPRITE`, 2 | Animating (1 plays, 0 stops) |
| `SPRITE`, 3 | Sprite width, in quarter pixels (scales proportionally, from its base) |
| `CLICK`, 0 | How a link on the tile activates: bit 0x1 by clicking, 0x10 by walking onto it |
| `ENTRY`, 0 | Where a world link on the tile puts you: `((16 - y) << 4) + (x - 1)` for a tile of the next (16×16) world; no value restores its own start |

These come from CYBERWORLD's own scriptlet library (`commands.js`) and
the worlds that use it; the CYBERWORLD Olympiad animates its fountains by
setting `SPRITE` option 3 twenty times a second.

# OpenQBORG extensions

Every extension is optional and only written when it is used, so a classic
world opened and saved in the OpenQBORG Editor stays byte-identical in its
map layers and can still be read by the original tools.

## World size: `<size>`

```xml
<gen ...>
  ...
  <size> 40 28 </size>     <!-- 64 x 40 tiles -->
</gen>
```

Width and height in hex, each 16 to 256 (`10`–`100`). Without `<size>`, a
world is 16×16. Every map layer holds `width × height` tiles, using the same
streaming rules (surface layers stream columns of `height` tiles). `<pos>`
keeps 64 units per tile, so it simply grows past 1024.

## Scripting: `<js>`

```xml
<map ...>
  ...
  <js> 10000 </js>        <!-- optional trigger ids, like any other layer -->
</map>
<ext>
  ...
  <js>
    <file HREF="world.js"/>  <!-- loaded from scripts/ in order -->
  </js>
</ext>
```

See [SCRIPTING.md](SCRIPTING.md) for the API.

## Web surfaces: `<srf>`

```xml
<ext>
  <srf>
    <file HREF="html/film.html" ID="screen" KIND="wall" FACE="s" X="4" Y="0" LEN="8" Z="140" H="870"/>
    <file HREF="art/loop.swf" ID="mural" KIND="floor" X="2" Y="5" W="3" D="2"/>
  </srf>
</ext>
```

A surface shows a web page, a video page or an `.swf` (through Ruffle) on
the world's geometry, spanning as many tiles as needed — enough for a cinema
screen. `KIND="wall"` covers `LEN` tiles starting at `X`,`Y` on the tile side
`FACE` (`n`/`s`/`e`/`w`; north and south faces run east, east and west faces
run south), from `Z` to `Z+H` pixels up. `KIND="floor"` or `"ceiling"`
covers a `W`×`D` tile rectangle. Numbers are decimal. `HREF` may be relative
to the world. The player renders pages live (with positional sound, and
clicks passed to the page); other software can ignore the element. World
scripts can add surfaces too, including ones made from inline HTML5 — see
[SCRIPTING.md](SCRIPTING.md).
