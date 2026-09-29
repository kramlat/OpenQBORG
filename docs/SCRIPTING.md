# World scripting

OpenQBORG worlds can carry JavaScript. Scripts are listed in the world's
`<ext><js>` element and live in its `scripts/` folder. The player runs them
in a hidden Chromium page (via godot-cef), so you get a current V8: ES2024,
`async`/`await`, timers, `fetch` (subject to CORS), and so on. Scripts run on
a `res://` origin with no access to the local disk.

Older players ignore the `<js>` elements, so a scripted world still works
there without its scripted behaviour.

```js
// scripts/world.js
borg.on("load", world => {
  borg.message(`Welcome to ${world.title} (${world.width}×${world.height})`);
});

// Paint trigger ids with the editor's "Script triggers" layer.
borg.on("enter", tile => {
  if (tile.id === 1) {
    borg.setTile("hgt", 5, 5, 0);   // open a door: flatten the wall block...
    borg.setTile("wal", 5, 5, 0);   // ...and make it walkable
    borg.message("A door opens somewhere.");
  }
});

borg.on("click", tile => borg.log("clicked", tile.x, tile.y));
```

## API

Coordinates are 0-based tiles, with `x` to the right and `y` down the map.

### Events

`borg.on(event, handler)` / `borg.off(event, handler)`

| Event | Argument | When |
|---|---|---|
| `load` | `world` | Scripts finished loading |
| `enter` | `{x, y, id}` | The player walked onto a tile |
| `leave` | `{x, y, id}` | The player walked off a tile |
| `click` | `{x, y, id}` | A tile was clicked in 3D or on the nav map |

`id` is the tile's value on the `js` trigger layer (0 if none).

### State

* `borg.world`: `{width, height, title, url}`
* `borg.player`: `{x, y, yaw}`, updated with each event (x/y in tiles, fractional)
* `borg.version`: API version, currently `"1"`

### Tiles

* `borg.getTile(layer, x, y)`
* `borg.setTile(layer, x, y, value)`: edits are batched, and the world is
  rebuilt once per frame
* `borg.moveTile(layer, fromX, fromY, toX, toY, keepOriginal)`

Layers use the `.borg` names: `wal`, `hgt`, `flr`, `cei`, `obj`, `gtw`,
`gtw2`, `wav`, `mid`, `js`. See [FORMAT.md](FORMAT.md) for their values.

### Player and pages

* `borg.setSurface(id, def)`: show a web page, video or `.swf` on a surface
  that can span many tiles. `def` is `{url, kind, face, x, y, len, z, h}` for
  walls (`kind: "wall"`, `face` `"n"`/`"s"`/`"e"`/`"w"`, `len` tiles long, `z`
  and `h` in pixels) or `{url, kind: "floor"|"ceiling", x, y, w, d}`. The same
  `id` replaces it; relative URLs are relative to the world.
* Script-made screens: pass `html: "<!doctype html>..."` instead of `url` to
  show your own HTML5 (canvas, animation, a scoreboard). Relative links in it
  resolve against the world.
* `borg.postToSurface(id, data)`: send data to a surface's page, which
  receives it with `qborg.onMessage(fn)`. A page sends back with
  `qborg.send(data)`, arriving as `borg.on("surfaceMessage", ({id, data}) => ...)`.
* `borg.removeSurface(id)`
* `borg.teleport(x, y[, yaw])`
* `borg.go(url)`: go to another world (relative to this one, or `borg://`/`borgs://`)
* `borg.showPage(url)`: show a page in place of the 3D view
* `borg.showSidePage(url)`: show a page in the side pane
* `borg.message(text)`: status bar text
* `borg.log(...)`: print to the player's console

## Classic page scripting still works

Pages shown beside the world keep the original CYBERWORLD interfaces:
`borg://` links, `pushTo3D()`/`pushTo2D()` and `window.external.MoveTile()`.
Pages from local worlds are served from `http://127.0.0.1` so that cookies
(which the Pokémon 2000 game uses for its save state) work.
