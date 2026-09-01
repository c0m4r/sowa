(function () {
  "use strict";

  const root = document.documentElement;
  const storageKey = "sowa-theme";
  const systemTheme = window.matchMedia("(prefers-color-scheme: dark)");
  const themeColor = document.querySelector("#theme-color");
  const validThemes = new Set(["system", "light", "dark"]);

  const normaliseTheme = (value) => validThemes.has(value) ? value : "system";

  const readTheme = () => {
    try {
      return normaliseTheme(window.localStorage.getItem(storageKey));
    } catch (_) {
      return "system";
    }
  };

  let selectedTheme = readTheme();
  let themeSelect;

  const effectiveTheme = () => {
    if (selectedTheme !== "system") return selectedTheme;
    return systemTheme.matches ? "dark" : "light";
  };

  const updateThemeColor = () => {
    if (!themeColor) return;
    themeColor.content = effectiveTheme() === "dark" ? "#11130f" : "#f6f3e8";
  };

  const applyTheme = () => {
    if (selectedTheme === "system") {
      root.removeAttribute("data-theme");
    } else {
      root.dataset.theme = selectedTheme;
    }

    if (themeSelect) themeSelect.value = selectedTheme;
    updateThemeColor();
  };

  const storeTheme = () => {
    try {
      if (selectedTheme === "system") {
        window.localStorage.removeItem(storageKey);
      } else {
        window.localStorage.setItem(storageKey, selectedTheme);
      }
    } catch (_) {
      // Storage may be unavailable; the selector still works for this page.
    }
  };

  root.classList.add("js");
  applyTheme();

  const initialiseSelector = () => {
    themeSelect = document.querySelector("#theme-select");
    if (!themeSelect) return;

    themeSelect.value = selectedTheme;
    themeSelect.addEventListener("change", () => {
      selectedTheme = normaliseTheme(themeSelect.value);
      applyTheme();
      storeTheme();
    });
  };

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", initialiseSelector, { once: true });
  } else {
    initialiseSelector();
  }

  const followSystemTheme = () => {
    if (selectedTheme === "system") updateThemeColor();
  };

  if (typeof systemTheme.addEventListener === "function") {
    systemTheme.addEventListener("change", followSystemTheme);
  } else {
    systemTheme.addListener(followSystemTheme);
  }

  window.addEventListener("storage", (event) => {
    if (event.key !== storageKey) return;
    selectedTheme = normaliseTheme(event.newValue);
    applyTheme();
  });
}());
