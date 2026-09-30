// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (c) 2026 Mark Toman and OpenQBORG contributors
// Injected by OpenQBORG into every page shown in the player (godot-cef
// preload script). CYBERWORLD pages talked to the 3D view two ways:
//   1. navigating to borg:// URLs (pushTo3D / pushTo2D / borg://cmd.prev)
//   2. calling methods on window.external (the old IE host object)
// Chromium doesn't know borg://, so both are forwarded over godot-cef IPC.
(function () {
  "use strict";
  function send(msg) {
    // The player only lets the world's own pages change the world.
    msg.origin = location.href;
    if (typeof window.sendIpcMessage === "function") {
      window.sendIpcMessage(JSON.stringify(msg));
    }
  }

  // --- borg:// links -------------------------------------------------------
  function isBorg(url) {
    return typeof url === "string" && /^borgs?:/i.test(url.trim());
  }
  // A link to a .borg file is a world, whatever server it is on.
  function isWorldFile(url) {
    return typeof url === "string" && /\.borg($|[?#])/i.test(url.trim()) && !isBorg(url);
  }

  document.addEventListener("click", function (e) {
    var a = e.target && e.target.closest ? e.target.closest("a[href]") : null;
    if (a && isBorg(a.getAttribute("href"))) {
      e.preventDefault();
      e.stopPropagation();
      send({ type: "borg", url: a.getAttribute("href"), base: location.href });
    } else if (a && isWorldFile(a.href)) {
      e.preventDefault();
      e.stopPropagation();
      send({ type: "world", url: a.href });
    }
  }, true);

  // Location assignments to borg:// can't be trapped directly; the Navigation
  // API sees them in current Chromium. Godot also watches load errors.
  if (window.navigation && window.navigation.addEventListener) {
    window.navigation.addEventListener("navigate", function (e) {
      if (isBorg(e.destination.url)) {
        e.preventDefault();
        send({ type: "borg", url: e.destination.url, base: location.href });
      } else if (isWorldFile(e.destination.url) && e.cancelable) {
        e.preventDefault();
        send({ type: "world", url: e.destination.url });
      }
    });
  }

  // The stock CYBERWORLD helpers (html/scripts/player.js) build borg:// URLs
  // from location.href. Resolve against the page instead and skip the detour.
  function wrapHelpers() {
    window.pushTo3D = function (borg) {
      send({ type: "world", url: new URL(borg, location.href).href });
    };
    window.pushTo2D = function (html) {
      send({ type: "web", url: new URL(html, location.href).href });
    };
  }
  document.addEventListener("DOMContentLoaded", wrapHelpers);
  window.addEventListener("load", wrapHelpers);

  // --- Flash, via Ruffle ----------------------------------------------------
  // The player serves Ruffle (an open source Flash emulator in WebAssembly)
  // and passes its address in __OQB_RUFFLE. Ruffle is only loaded once a
  // page actually contains Flash; its polyfill then replaces every
  // <object>/<embed> SWF, including ones added later by document.write().
  // Only on real pages: Chromium's own (error pages, viewers) forbid it anyway.
  var ruffleBase = /^(https?|file):$/.test(location.protocol) ? window.__OQB_RUFFLE : "";
  var ruffleLoaded = false;
  var ruffleFailed = false;
  var FLASH = 'embed[src$=".swf" i], embed[type="application/x-shockwave-flash" i],' +
      ' object[data$=".swf" i], object[type="application/x-shockwave-flash" i],' +
      ' object[classid*="D27CDB6E" i], param[name="movie" i][value$=".swf" i]';
  function loadRuffle() {
    if (ruffleLoaded || !ruffleBase) return;
    ruffleLoaded = true;
    window.RufflePlayer = window.RufflePlayer || {};
    window.RufflePlayer.config = Object.assign({
      publicPath: ruffleBase, polyfills: true, autoplay: "on", unmuteOverlay: "hidden",
      splashScreen: false, letterbox: "on", warnOnUnsupportedContent: false,
      showSwfDownload: false, contextMenu: "rightClickOnly"
    }, window.RufflePlayer.config || {});
    var s = document.createElement("script");
    s.onerror = function () { ruffleFailed = true; };
    s.src = ruffleBase + "ruffle.js";
    (document.head || document.documentElement).appendChild(s);
  }
  if (ruffleBase) {
    var watch = new MutationObserver(function () {
      if (!ruffleLoaded && document.querySelector && document.querySelector(FLASH)) {
        loadRuffle();
        watch.disconnect();
      }
    });
    watch.observe(document, { childList: true, subtree: true });
  }

  // --- Flash overlays ---------------------------------------------------
  // When Ruffle can't play a movie inside the page, the player draws Ruffle
  // over the spot instead: report where each such movie is, and hide what
  // Chromium or the failed Ruffle shows underneath. Decided by outcome, not by
  // guesses: a movie is rescued when Ruffle never took it over (its script was
  // blocked or didn't load), when Ruffle shows its error screen (the page's
  // policy blocks it from running or fetching), or when it still hasn't loaded
  // after 20 seconds.
  var rescued = [];
  var watching = false;
  function watchLayout() {
    if (watching) return;
    watching = true;
    var queued = false;
    function queue() {
      if (queued) return;
      queued = true;
      requestAnimationFrame(function () { queued = false; reportFlash(); });
    }
    window.addEventListener("scroll", queue, true);
    window.addEventListener("resize", queue);
    new MutationObserver(queue).observe(document, { childList: true, subtree: true, attributes: true });
    queue();
  }
  function swfOf(el) {
    var src = el.getAttribute("src") || el.getAttribute("data") || "";
    if (!src) {
      var p = el.querySelector('param[name="movie" i], param[name="src" i]');
      if (p) src = p.getAttribute("value") || "";
    }
    if (!src && /OBJECT$/.test(el.tagName)) {
      var inner = el.querySelector("embed, ruffle-embed");
      if (inner) return swfOf(inner);
    }
    try { return src ? new URL(src, document.baseURI).href : ""; } catch (e) { return ""; }
  }
  function isFlash(el) {
    return el.matches(FLASH) || /\.swf($|[?#])/i.test(swfOf(el));
  }
  function ruffleFailedOn(el) {
    var panic = el.shadowRoot && el.shadowRoot.querySelector("#panic");
    return !!panic && getComputedStyle(panic).display !== "none";
  }
  function needsRescue(el, elapsed) {
    if (/^RUFFLE-/.test(el.tagName)) {
      return el.readyState !== 2 && (ruffleFailedOn(el) || elapsed >= 20000);
    }
    // A plain <embed>/<object>: Ruffle never took it over.
    return isFlash(el) && (!ruffleBase || ruffleFailed || elapsed >= 5000);
  }
  function checkFlash(elapsed) {
    document.querySelectorAll("embed, object, ruffle-embed, ruffle-object").forEach(function (el) {
      // An <embed> inside an <object> is the same movie.
      if (/EMBED$/.test(el.tagName) && el.parentElement && el.parentElement.closest("object, ruffle-object")) return;
      if (rescued.indexOf(el) >= 0 || !needsRescue(el, elapsed)) return;
      rescued.push(el);
      if (typeof el.pause === "function") { try { el.pause(); } catch (e) {} }
      watchLayout();
    });
    if (rescued.length) reportFlash();
  }
  var lastReport = "";
  function reportFlash() {
    var items = [];
    rescued = rescued.filter(function (el) { return el.isConnected; });
    rescued.forEach(function (el) {
      var src = swfOf(el);
      if (!src) return;
      el.style.visibility = "hidden";
      var r = el.getBoundingClientRect();
      if (r.width < 1 || r.height < 1) return;
      items.push({ src: src, x: r.left, y: r.top, w: r.width, h: r.height });
    });
    var json = JSON.stringify(items);
    if (json === lastReport) return;
    lastReport = json;
    send({ type: "flashOverlay", items: items, vw: window.innerWidth, vh: window.innerHeight });
  }
  window.addEventListener("load", function () {
    var start = Date.now();
    (function tick() {
      var elapsed = Date.now() - start;
      checkFlash(elapsed);
      if (elapsed < 21000) setTimeout(tick, 1000);
    })();
  });

  // --- Surface screens ---------------------------------------------------
  // Pages shown on web surfaces can talk to the world's script:
  //   qborg.send(data)       -> borg.on("surfaceMessage", ({id, data}) => ...)
  //   qborg.onMessage(fn)    <- borg.postToSurface(id, data)
  var listeners = [];
  window.qborg = {
    send: function (data) { send({ type: "surfaceMessage", data: data }); },
    onMessage: function (fn) { if (typeof fn === "function") listeners.push(fn); }
  };
  if (window.ipcMessage && window.ipcMessage.addListener) {
    window.ipcMessage.addListener(function (raw) {
      var msg;
      try { msg = JSON.parse(raw); } catch (e) { return; }
      if (msg && msg.type === "surfaceMessage") {
        listeners.forEach(function (fn) { try { fn(msg.data); } catch (e) { console.error(e); } });
      }
    });
  }

  // --- JS dialogs -----------------------------------------------------------
  // Native JS dialogs crash godot-cef on current Godot builds, and old pages
  // use them freely. Show them as Godot dialogs instead. They can't block,
  // so confirm() answers "OK" and prompt() returns its default value.
  function dialog(kind, message, value) {
    send({ type: "dialog", kind: kind, text: String(message === undefined ? "" : message) });
    return value;
  }
  window.alert = function (m) { dialog("alert", m, undefined); };
  window.confirm = function (m) { return dialog("confirm", m, true); };
  window.prompt = function (m, d) { return dialog("prompt", m, d === undefined ? "" : String(d)); };
  // "Leave this page?" is a native dialog too.
  window.addEventListener("beforeunload", function (e) { e.stopImmediatePropagation(); }, true);
  Object.defineProperty(window, "onbeforeunload", { get: function () { return null; }, set: function () {} });

  // --- window.external -----------------------------------------------------
  var host = {
    GetVer: function () { return "5.3"; },
    MoveTile: function (layer, fromX, fromY, toX, toY, keepOriginal) {
      send({ type: "moveTile", layer: String(layer), fromX: fromX, fromY: fromY,
             toX: toX, toY: toY, keepOriginal: !!keepOriginal });
    },
    tileValue: function (layer, x, y, option, value) {
      send({ type: "tileValue", layer: String(layer), x: x, y: y, option: option,
             value: value === undefined ? null : value });
    }
  };
  host.moveTile = host.MoveTile;
  host.getVer = host.GetVer;
  try {
    Object.defineProperty(window, "external", { value: host, configurable: true });
  } catch (err) {
    for (var k in host) { try { window.external[k] = host[k]; } catch (e2) {} }
  }
  // BorgLocation is filled in by the player after each page load.
})();
