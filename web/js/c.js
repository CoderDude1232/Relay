/* /c/<token> — a connect invite. The token is opaque and never displayed; it
   only goes into the deep link. */
(function () {
  var parts = location.pathname.replace(/\/+$/, "").split("/").filter(Boolean);
  var token = parts.length ? parts[parts.length - 1] : "";
  if (token === "c" || /\.html?$/i.test(token)) return;
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(token)) return;

  var open = document.getElementById("open-link");
  open.href = "relay://contact/" + token;
  open.hidden = false;
})();
