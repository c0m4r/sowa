/* Sowa Linux — site behaviour. Progressive enhancement only: the page is
   complete without this file. */
(function () {
  "use strict";

  /* ---- colour theme ------------------------------------------------ */

  var KEY = "sowa-theme";
  var root = document.documentElement;
  var button = document.getElementById("theme-toggle");

  function stored() {
    try { return localStorage.getItem(KEY); } catch (e) { return null; }
  }

  function remember(value) {
    try { localStorage.setItem(KEY, value); } catch (e) { /* private mode */ }
  }

  function systemIsDark() {
    return !window.matchMedia || window.matchMedia("(prefers-color-scheme: dark)").matches;
  }

  function apply(theme) {
    if (theme === "light" || theme === "dark") {
      root.setAttribute("data-theme", theme);
    } else {
      root.removeAttribute("data-theme");
    }
    if (button) {
      var dark = theme ? theme === "dark" : systemIsDark();
      button.setAttribute("aria-label", dark ? "Switch to the light theme" : "Switch to the dark theme");
      var icon = button.querySelector("[data-theme-icon]");
      if (icon) { icon.textContent = dark ? "☀" : "☾"; }
    }
  }

  apply(stored());

  if (button) {
    button.addEventListener("click", function () {
      var current = stored();
      var dark = current ? current === "dark" : systemIsDark();
      var next = dark ? "light" : "dark";
      remember(next);
      apply(next);
    });
  }

  /* ---- copy buttons on command blocks ------------------------------ */

  if (navigator.clipboard) {
    Array.prototype.forEach.call(document.querySelectorAll("[data-copy]"), function (block) {
      var source = block.querySelector("code");
      if (!source) { return; }

      var copy = document.createElement("button");
      copy.type = "button";
      copy.className = "copy";
      copy.textContent = "copy";
      copy.setAttribute("aria-label", "Copy these commands to the clipboard");

      var reset;
      copy.addEventListener("click", function () {
        navigator.clipboard.writeText(source.textContent.trim()).then(function () {
          copy.textContent = "copied";
          copy.setAttribute("data-done", "1");
          clearTimeout(reset);
          reset = setTimeout(function () {
            copy.textContent = "copy";
            copy.removeAttribute("data-done");
          }, 1600);
        }, function () {
          copy.textContent = "failed";
          clearTimeout(reset);
          reset = setTimeout(function () { copy.textContent = "copy"; }, 1600);
        });
      });

      block.appendChild(copy);
    });
  }
}());
