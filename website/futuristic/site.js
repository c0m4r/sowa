(function () {
  "use strict";

  const root = document.documentElement;
  const clock = document.querySelector("#clock");
  const filterButtons = document.querySelectorAll("[data-filter]");
  const artifactRows = document.querySelectorAll(".artifact-row[data-category]");
  const copyButtons = document.querySelectorAll("[data-copy]");
  const terminalForm = document.querySelector("#terminal-form");
  const terminalInput = document.querySelector("#terminal-input");
  const terminalOutput = document.querySelector("#terminal-output");

  const updateClock = () => {
    if (!clock) return;
    const now = new Date();
    clock.dateTime = now.toISOString();
    clock.textContent = now.toLocaleTimeString([], {
      hour: "2-digit",
      minute: "2-digit",
      second: "2-digit",
      hour12: false
    });
  };

  updateClock();
  window.setInterval(updateClock, 1000);

  filterButtons.forEach((button) => {
    button.addEventListener("click", () => {
      const activeFilter = button.dataset.filter;

      filterButtons.forEach((item) => {
        const isActive = item === button;
        item.classList.toggle("is-active", isActive);
        item.setAttribute("aria-pressed", String(isActive));
      });

      artifactRows.forEach((row) => {
        row.hidden = activeFilter !== "all" && row.dataset.category !== activeFilter;
      });
    });
  });

  const copyText = async (text) => {
    if (navigator.clipboard && window.isSecureContext) {
      await navigator.clipboard.writeText(text);
      return;
    }

    const field = document.createElement("textarea");
    field.value = text;
    field.setAttribute("readonly", "");
    field.style.position = "fixed";
    field.style.opacity = "0";
    document.body.appendChild(field);
    field.select();
    document.execCommand("copy");
    field.remove();
  };

  copyButtons.forEach((button) => {
    button.addEventListener("click", async () => {
      const original = button.textContent;
      try {
        await copyText(button.dataset.copy);
        button.textContent = "[ copied ]";
      } catch (_) {
        button.textContent = "[ copy failed ]";
      }
      window.setTimeout(() => {
        button.textContent = original;
      }, 1500);
    });
  });

  if (!terminalForm || !terminalInput || !terminalOutput) return;

  const lines = {
    help: [
      "Available commands:",
      "  help          show this list",
      "  ls            list this site",
      "  uname -a      print system information",
      "  downloads     jump to release artifacts",
      "  about         jump to project notes",
      "  date          print local time",
      "  theme amber   switch phosphor color",
      "  theme green   restore phosphor color",
      "  clear         clear the terminal"
    ].join("\n"),
    ls: "downloads/  about/  quickstart/  terminal/  README",
    "uname -a": "Linux sowa 6.18.44 #1 SMP x86_64 GNU/Linux",
    whoami: "guest",
    pwd: "/home/guest",
    readme: "Sowa: small / inspectable / built from source.",
    sudo: "guest is not in the sudoers file. This incident will be ignored.",
    "sudo su": "Nice try. Boot the ISO if you want root."
  };

  const print = (text) => {
    terminalOutput.textContent += `\n${text}`;
    terminalOutput.scrollTop = terminalOutput.scrollHeight;
  };

  terminalForm.addEventListener("submit", (event) => {
    event.preventDefault();
    const rawCommand = terminalInput.value.trim();
    const command = rawCommand.toLowerCase().replace(/\s+/g, " ");
    terminalInput.value = "";

    if (!command) return;

    if (command === "clear") {
      terminalOutput.textContent = "";
      return;
    }

    print(`guest@sowa:~$ ${rawCommand}`);

    if (Object.prototype.hasOwnProperty.call(lines, command)) {
      print(lines[command]);
      return;
    }

    if (command === "date") {
      print(new Date().toString());
      return;
    }

    if (command === "downloads" || command === "about") {
      print(`opening /${command}/ ...`);
      const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
      document.querySelector(`#${command}`)?.scrollIntoView({
        behavior: reducedMotion ? "auto" : "smooth"
      });
      return;
    }

    if (command === "theme amber" || command === "amber") {
      root.dataset.theme = "amber";
      print("terminal phosphor set to amber");
      return;
    }

    if (command === "theme green" || command === "green") {
      delete root.dataset.theme;
      print("terminal phosphor set to green");
      return;
    }

    print(`sh: ${rawCommand}: command not found`);
  });
})();
