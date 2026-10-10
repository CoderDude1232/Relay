/* Relay — waitlist form handling.
 *
 * SET THIS before you deploy. Any endpoint that accepts a POST works:
 * Formspree, Buttondown, Listmonk, a Cloudflare Worker, your own API.
 *   e.g. "https://api.buttondown.com/v1/subscribers"
 *        "https://formspree.io/f/xxxxxxx"
 * Leave it empty and the form tells the visitor it isn't live yet,
 * instead of silently swallowing their address.
 */
var WAITLIST_ENDPOINT = "";

(function () {
  "use strict";

  var EMAIL = /^[^\s@]+@[^\s@]+\.[^\s@]{2,}$/;

  function attach(form) {
    var input = form.querySelector('input[type="email"]');
    var button = form.querySelector('button[type="submit"]');
    var status = form.querySelector(".form-status");
    if (!input || !button || !status) return;

    function say(message, state) {
      status.textContent = message;
      status.setAttribute("data-state", state);
    }

    form.addEventListener("submit", function (event) {
      event.preventDefault();
      var address = input.value.trim();

      if (!EMAIL.test(address)) {
        say("That address doesn't look complete — check it and try again.", "error");
        input.focus();
        return;
      }

      if (!WAITLIST_ENDPOINT) {
        say("The waitlist isn't connected yet. Email hello@relaymsg.app and we'll add you by hand.", "error");
        return;
      }

      button.disabled = true;
      say("Sending…", "pending");

      fetch(WAITLIST_ENDPOINT, {
        method: "POST",
        headers: { "Content-Type": "application/json", "Accept": "application/json" },
        body: JSON.stringify({ email: address })
      })
        .then(function (response) {
          if (!response.ok) throw new Error("HTTP " + response.status);
          form.reset();
          say("You're on the list. One email, on launch day.", "ok");
        })
        .catch(function () {
          say("That didn't go through. Try again, or email hello@relaymsg.app.", "error");
        })
        .then(function () {
          button.disabled = false;
        });
    });

    input.addEventListener("input", function () {
      if (status.textContent) say("", "");
    });
  }

  var forms = document.querySelectorAll("form.signup");
  for (var i = 0; i < forms.length; i++) attach(forms[i]);

  /* Theme toggle.
   * Three states, not two: with nothing stored the OS preference decides, and
   * the page keeps following it as the OS changes. Clicking stores an explicit
   * choice, which then wins over the OS until it's cleared.
   */
  var KEY = "relay-theme";
  var root = document.documentElement;
  var media = window.matchMedia ? window.matchMedia("(prefers-color-scheme: dark)") : null;

  function stored() {
    try { return localStorage.getItem(KEY); } catch (e) { return null; }
  }

  function isDark() {
    var t = stored();
    if (t === "dark") return true;
    if (t === "light") return false;
    return !!(media && media.matches);
  }

  function label(button) {
    var next = isDark() ? "light" : "dark";
    button.setAttribute("aria-label", "Switch to " + next + " theme");
    button.setAttribute("title", "Switch to " + next + " theme");
  }

  /* The <head> snippet normally applies a stored choice before first paint.
     Re-applying here is belt and braces, and makes the toggle work anywhere the
     page is embedded without that snippet. */
  var saved = stored();
  if (saved === "dark" || saved === "light") root.setAttribute("data-theme", saved);

  var button = document.getElementById("theme-toggle");
  if (button) {
    label(button);

    button.addEventListener("click", function () {
      var next = isDark() ? "light" : "dark";
      root.setAttribute("data-theme", next);
      try { localStorage.setItem(KEY, next); } catch (e) {}
      label(button);
    });

    /* Follow the OS while no explicit choice has been made. */
    if (media && media.addEventListener) {
      media.addEventListener("change", function () {
        if (!stored()) label(button);
      });
    }
  }
})();
