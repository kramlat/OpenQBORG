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
  var ruffleBase = window.__OQB_RUFFLE;
  var ruffleLoaded = false;
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
