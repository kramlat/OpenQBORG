// The Orb Vault: collect three orbs, then stand on the plate to open the gate.
// Trigger ids (painted on the editor's "Script triggers" layer):
//   1 orb, 2 plate, 3 pad A (west), 4 pad B (east)
const ORBS = 3;
const GATE = [[7,12],[8,12]];
const PAD_A_EXIT = [3.5, 4.5];   // step off beside pad A
const PAD_B_EXIT = [12.5, 4.5];   // step off beside pad B
let collected = 0;
let open = false;

borg.on("load", () => {
  borg.message(`Find the ${ORBS} orbs. The glowing pad is a teleporter.`);
});

borg.on("enter", ({ x, y, id }) => {
  switch (id) {
    case 1:                                   // an orb
      borg.setTile("obj", x, y, 0);
      borg.setTile("js", x, y, 0);
      collected++;
      borg.message(collected < ORBS ? `Orb ${collected} of ${ORBS}.` : "All orbs found! Now the plate.");
      break;
    case 2:                                   // the pressure plate
      if (open) break;
      if (collected < ORBS) {
        borg.message(`The plate won't budge. ${ORBS - collected} orb(s) to go.`);
        break;
      }
      for (const [gx, gy] of GATE) {
        borg.setTile("hgt", gx, gy, 0);
        borg.setTile("wal", gx, gy, 0);
      }
      open = true;
      borg.message("The gate grinds open. The portal leads home.");
      break;
    case 3:
      borg.teleport(...PAD_B_EXIT);
      break;
    case 4:
      borg.teleport(...PAD_A_EXIT);
      break;
  }
});

borg.on("click", ({ id }) => {
  if (id === 2) borg.message(open ? "The gate is open." : `${collected}/${ORBS} orbs.`);
});
