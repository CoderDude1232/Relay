/* The invite handle comes from the path: /add/ethan or /add/@ethan.
   Anything that isn't a plausible handle is ignored rather than printed — this
   text goes straight into the page, so it doesn't get to be arbitrary. */
(function () {
  var parts = location.pathname.replace(/\/+$/, "").split("/").filter(Boolean);
  var last = parts.length ? parts[parts.length - 1] : "";
  /* /add/, and the file itself when it's opened directly rather than through
     the /add/* rewrite */
  if (last === "add" || /\.html?$/i.test(last)) return;

  var handle = last.charAt(0) === "@" ? last.slice(1) : last;
  if (!/^[A-Za-z0-9_.-]{1,30}$/.test(handle)) return;

  document.getElementById("invite-label").textContent = "You were invited by";
  var h = document.getElementById("invite-heading");
  h.textContent = "";
  var at = document.createElement("span");
  at.className = "handle";
  at.textContent = "@" + handle;
  h.appendChild(at);
  h.appendChild(document.createElement("br"));
  h.appendChild(document.createTextNode("wants to chat."));

  var open = document.getElementById("open-link");
  open.href = "relay://add/" + encodeURIComponent(handle);
  open.hidden = false;
})();
