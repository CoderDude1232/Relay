/* /g/<token>#<key> — a group invite.
 *
 * The fragment is the group's decryption key. A browser never puts a fragment
 * on the wire, and nothing here changes that: it is read from location.hash,
 * checked against the URL-safe base64 alphabet, and written verbatim into the
 * button's href. It is never rendered, never stored, never handed to anything
 * that performs a request. There is no analytics on this site; don't add any
 * to these pages.
 *
 * The group's name isn't shown because it's encrypted with that key and is
 * only readable inside the app.
 */
(function () {
  var parts = location.pathname.replace(/\/+$/, "").split("/").filter(Boolean);
  var token = parts.length ? parts[parts.length - 1] : "";
  if (token === "g" || /\.html?$/i.test(token)) return;
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(token)) return;

  var key = location.hash.slice(1);
  var hasKey = /^[A-Za-z0-9_-]{1,512}$/.test(key);

  if (!hasKey) {
    document.getElementById("no-key").hidden = false;
    return;
  }

  var open = document.getElementById("open-link");
  open.href = "relay://join/" + token + "#" + key;
  open.hidden = false;
})();
