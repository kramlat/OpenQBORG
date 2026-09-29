// The Starlight Cinema: a scripted HTML5 marquee on the west wall.
const MARQUEE = `<!doctype html>
<style>html, body { margin: 0; height: 100%; background: #12040a; overflow: hidden; }
canvas { width: 100%; height: 100%; display: block; }</style>
<canvas id="c" width="512" height="256"></canvas>
<script>
const c = document.getElementById("c"), g = c.getContext("2d");
let text = "NOW SHOWING", t = 0;
qborg.onMessage((m) => { text = String(m); });   // from borg.postToSurface
(function frame() {
  t += 1;
  g.fillStyle = "#12040a"; g.fillRect(0, 0, 512, 256);
  for (let i = 0; i < 28; i++) {                    // chasing marquee bulbs
    const on = (i + (t >> 3)) % 3 === 0;
    g.fillStyle = on ? "#ffd23f" : "#5a3a10";
    const x = 16 + (i % 14) * 34, y = i < 14 ? 14 : 232;
    g.beginPath(); g.arc(x, y, 7, 0, 7); g.fill();
  }
  g.fillStyle = "#ff5a7a"; g.font = "bold 44px sans-serif"; g.textAlign = "center";
  g.fillText(text, 256, 140 + Math.sin(t / 20) * 6);
  requestAnimationFrame(frame);
})();
qborg.send("ready");                                 // to borg.on("surfaceMessage")
<\/script>`;

borg.on("load", () => {
  borg.setSurface("marquee", {
    html: MARQUEE, kind: "wall", face: "e", x: 0, y: 3, len: 4, z: 300, h: 400,
  });
});

// Trigger 1 is painted on the start tile: greet whoever stands there.
let greeting = false;
const show = () => borg.postToSurface("marquee", greeting ? "ENJOY THE SHOW!" : "NOW SHOWING");

// The marquee page says "ready" once loaded; messages sent before then would
// be lost, so (re)send the current text.
borg.on("surfaceMessage", ({ id, data }) => {
  if (id === "marquee" && data === "ready") {
    borg.log("marquee is up");
    show();
  }
});

borg.on("enter", ({ id }) => { if (id === 1) { greeting = true; show(); } });
borg.on("leave", ({ id }) => { if (id === 1) { greeting = false; show(); } });
