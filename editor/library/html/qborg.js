// Page helpers, compatible with the original CYBERWORLD browser: they
// navigate to borg:// URLs, which OpenQBORG (and the old browser) intercept.
function pushTo3D(borg) {
  var slashes = location.protocol.indexOf("http") === 0 ? "//" : "///";
  var here = location.href.substring(location.href.indexOf(slashes) + slashes.length,
      location.href.lastIndexOf("/") + 1);
  location = "borg://" + here + borg;
}
function pushTo2D(html) {
  location = "borg://cmd.web@" + location.href.substring(0, location.href.lastIndexOf("/") + 1) + html;
}
