/* Applied before first paint so a stored choice never flashes the other theme.
   Loaded synchronously in <head>; kept external so the CSP can forbid inline script. */
(function () {
  try {
    var t = localStorage.getItem("relay-theme");
    if (t === "dark" || t === "light") document.documentElement.setAttribute("data-theme", t);
  } catch (e) {}
})();
