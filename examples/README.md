# Example worlds

Three small worlds that show what QBORG and OpenQBORG can do. Every texture,
sprite, sound, tune and page in them is generated from code by
[`tools/make_examples.gd`](../tools/make_examples.gd), so they're original
work under the project's license (GPL-3.0-or-later) and can be rebuilt:

```sh
godot --headless --path player --script ../tools/make_examples.gd
```

(ffmpeg is used for the Ogg/Opus/FLAC/AAC files and ImageMagick for the
emblem lettering; both are optional.) The same run also rebuilds the editor's
starter library in `editor/library/`, and the examples use its assets.

## Try them

```sh
godot --path player -- examples/borgs/hello.borg
godot --path editor -- examples/borgs/hello.borg
```

The portals in the courtyard lead to the other two worlds.

| World | Size | Shows |
|---|---|---|
| [`hello.borg`](borgs/hello.borg) | 16×16 | **Classic format only**, so the original tools could open it. Animated GIF textures (a waterfall behind the fountain, a rippling pond), Brick and hedge walls, grass, path and water tiles, trees, animated torches, a fountain with a looping WAV sound, a MIDI theme, banners painted onto wall faces, a panorama backdrop, signposts that show side pages, portals (`gtw`), and a page that moves a torch with `window.external.MoveTile()`. |
| [`sprawl.borg`](borgs/sprawl.borg) | 128×128 | The `<size>` extension: a noise-generated island with an animated sea with paths, ruins, a forest, FLAC wave sounds along the shore, and AAC (`.m4a`) music. |
| [`puzzle.borg`](borgs/puzzle.borg) | 16×16 | `<js>` world scripting ([`scripts/puzzle.js`](borgs/scripts/puzzle.js)): collect three orbs, teleport between pads, and a pressure plate that opens a gate. Also pulsing teleport pads, a stone ceiling, an Opus sound tile and Ogg Vorbis music. |

## Layout

```
borgs/
  *.borg      the worlds
  domains/    starter.flr, starter.wal, starter-sky.bck (from the starter library),
              per-world .nav maps and .emb emblems, .url shortcuts to the pages
  objects/    the starter library's sprites (CWS2)
  media/      the starter library's sounds and music
  scripts/    puzzle.js
  html/       side pages (plain HTML5), style.css, qborg.js
```
