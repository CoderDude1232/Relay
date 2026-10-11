/* /call/<callId>#<host>.<secret> — a call link. The fragment never reaches a
   server; it only goes into the deep link. */
(function () {
  var parts = location.pathname.replace(/\/+$/, "").split("/").filter(Boolean);
  var id = parts.length ? parts[parts.length - 1] : "";
  if (!/^[0-9A-Fa-f-]{36}$/.test(id)) return;
  var frag = location.hash.replace(/^#/, "");
  if (!/^[0-9A-Fa-f-]{36}\.[A-Za-z0-9_-]{16,64}$/.test(frag)) return;
  var open = document.getElementById("open-link");
  open.href = "relay://call/" + id + "#" + frag;
  open.textContent = "Already have Relay? Open it";
  open.hidden = false;
})();
