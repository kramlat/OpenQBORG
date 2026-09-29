// A world script: see docs/SCRIPTING.md for the full borg API.
// Paint trigger ids with the editor's "Script triggers" layer.

borg.on("load", (world) => {
  borg.message(`Welcome to !`);
});

borg.on("enter", ({ x, y, id }) => {
  if (id === 1) {
    borg.message(`You stepped on trigger 1 at ,.`);
  }
});

borg.on("click", ({ x, y, id }) => {
  if (id === 2) {
    // Example: open a door by flattening a wall block and making it walkable.
    borg.setTile("hgt", x, y - 1, 0);
    borg.setTile("wal", x, y - 1, 0);
  }
});
