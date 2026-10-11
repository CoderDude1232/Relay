/* /proxy#<host[:port]>. The address is only in the fragment, so it never
   reaches this site's server. */
(function () {
  var addr = location.hash.replace(/^#/, "").trim().toLowerCase();
  if (!/^[a-z0-9.-]+\.[a-z0-9-]+(:[0-9]{1,5})?$/.test(addr)) return;
  var shown = document.getElementById("proxy-address");
  shown.textContent = "Proxy address: " + addr;
  shown.hidden = false;
  var open = document.getElementById("open-link");
  open.href = "relay://proxy/" + addr;
  open.hidden = false;
})();
