const api = window.electronAPI;
if (!api) {
  document.body.innerHTML = "<p>Electron API not available</p>";
  throw new Error("No electronAPI");
}

const versionEl = document.getElementById("app-version");
const footerVersionEl = document.getElementById("footer-version");
if (api.version) {
  api.version().then((v) => {
    if (v) {
      if (versionEl) versionEl.textContent = `v${v}`;
      if (footerVersionEl) footerVersionEl.textContent = `v${v}`;
    }
  });
}

document.getElementById("btn-open-clawhome")?.addEventListener("click", () => {
  api.openClawhomeDir?.();
});

async function runVersionCheck() {
  if (!api.checkForUpdates) return;
  try {
    const result = await api.checkForUpdates();
    if (result.hasUpdate) {
      const banner = document.getElementById("update-banner");
      const link = document.getElementById("update-link");
      if (banner && link) {
        link.textContent = result.latestVersion;
        link.href = result.url;
        link.onclick = (e) => {
          e.preventDefault();
          api.openExternal?.(result.url);
        };
        banner.style.display = "flex";
      }
    }
  } catch (e) {
    console.warn("[ClawHome] Version check failed:", e);
  }
}

document.getElementById("update-dismiss")?.addEventListener("click", () => {
  document.getElementById("update-banner").style.display = "none";
});

const screens = {
  welcome: document.getElementById("screen-welcome"),
  config: document.getElementById("screen-config"),
  install: document.getElementById("screen-install"),
  homes: document.getElementById("screen-homes"),
};

function showScreen(name) {
  if (homesPollInterval) {
    clearInterval(homesPollInterval);
    homesPollInterval = null;
  }
  Object.values(screens).forEach((s) => s.classList.remove("active"));
  const screen = screens[name];
  if (screen) screen.classList.add("active");
  if (name === "homes") {
    homesPollInterval = setInterval(() => renderHomeList(), 2000);
  }
}

let installPollInterval = null;
let installTipsInterval = null;
let homesPollInterval = null;

function resetCreateForm() {
  document.getElementById("home-name").value = "";
  document.getElementById("disk-gb").value = "32";
  document.getElementById("ram-gb").value = "4";
  document.getElementById("config-error").textContent = "";
}

document.getElementById("btn-give-home").addEventListener("click", () => {
  resetCreateForm();
  showScreen("config");
});

document.getElementById("btn-back-config").addEventListener("click", () => {
  showScreen("welcome");
});

document.getElementById("btn-new-home").addEventListener("click", () => {
  resetCreateForm();
  showScreen("config");
});

document.getElementById("btn-create").addEventListener("click", async () => {
  const name = document.getElementById("home-name").value.trim();
  const ramGb = parseInt(document.getElementById("ram-gb").value, 10) || 4;
  const diskGb = parseInt(document.getElementById("disk-gb").value, 10) || 32;

  document.getElementById("config-error").textContent = "";

  if (!name) {
    api.showErrorDialog("Enter your bot name");
    return;
  }

  const btn = document.getElementById("btn-create");
  btn.disabled = true;
  btn.textContent = "Creating…";

  try {
    const r = await api.vmCreate({
      name,
      ramMb: ramGb * 1024,
      diskGb,
    });
    if (r.ok && r.vm) {
      showScreen("install");
      startInstallPoll(r.vm.id);
    } else if (r.error === "VM already exists") {
      const vmId = sanitizeName(name);
      if (!vmId) {
        api.showErrorDialog(r.error);
        return;
      }
      const choice = await api.showVmExistsDialog(vmId);
      if (choice === "overwrite") {
        await api.vmDelete(vmId);
        const r2 = await api.vmCreate({
          name,
          ramMb: ramGb * 1024,
          diskGb,
        });
        if (r2.ok && r2.vm) {
          showScreen("install");
          startInstallPoll(r2.vm.id);
        } else {
          api.showErrorDialog(r2.error || "Failed to create");
        }
      }
    } else {
      api.showErrorDialog(r.error || "Failed to create");
    }
  } catch (e) {
    api.showErrorDialog(e.message || "Failed");
  } finally {
    btn.disabled = false;
    btn.textContent = "Create";
  }
});

document.getElementById("btn-install-back").addEventListener("click", () => {
  showScreen("homes");
  renderHomeList();
});

function startInstallTipsCarousel() {
  if (installTipsInterval) clearInterval(installTipsInterval);
  const tips = document.querySelectorAll(".install-tip");
  let idx = 0;
  tips.forEach((t, i) => t.classList.toggle("active", i === 0));
  installTipsInterval = setInterval(() => {
    tips[idx].classList.remove("active");
    idx = (idx + 1) % tips.length;
    tips[idx].classList.add("active");
  }, 5000);
}

function stopInstallTipsCarousel() {
  if (installTipsInterval) {
    clearInterval(installTipsInterval);
    installTipsInterval = null;
  }
}

function startInstallPoll(vmId) {
  const statusEl = document.getElementById("install-status");
  const progressEl = document.getElementById("install-progress");
  const percentEl = document.getElementById("install-percent");

  document.getElementById("install-error-actions").style.display = "none";
  statusEl.style.color = "";
  startInstallTipsCarousel();
  if (installPollInterval) clearInterval(installPollInterval);
  installPollInterval = setInterval(async () => {
    const r = await api.vmInstallProgress(vmId);
    if (r.error) {
      statusEl.textContent = "Install failed: " + r.error;
      statusEl.style.color = "#c72c2c";
      document.getElementById("install-error-actions").style.display = "flex";
      stopInstallTipsCarousel();
      clearInterval(installPollInterval);
      installPollInterval = null;
      return;
    }
    if (r.ok && r.phase) {
      statusEl.textContent = r.phase;
      statusEl.style.color = "";
      const pct = Math.round((r.fractionCompleted ?? 0) * 100);
      progressEl.style.width = pct + "%";
      percentEl.textContent = pct + "%";
    }
    const vms = await api.vmList();
    const vm = vms.find((v) => v.id === vmId);
    if (vm && vm.status !== "installing") {
      stopInstallTipsCarousel();
      clearInterval(installPollInterval);
      installPollInterval = null;
      showScreen("homes");
      renderHomeList();
    }
  }, 1000);
}

async function renderHomeList() {
  const listEl = document.getElementById("home-list");
  const vms = await api.vmList();

  if (!vms || vms.length === 0) {
    listEl.innerHTML = '<p class="empty-homes">No homes yet. Create one!</p>';
    return;
  }

  listEl.innerHTML = vms
    .map(
      (vm) => `
    <div class="home-item" data-id="${vm.id}">
      <div class="home-info">
        <span class="home-name">${escapeHtml(vm.name)}'s</span>
        <span class="home-status ${vm.status}">${escapeHtml(vm.status)}</span>
      </div>
      <div class="home-actions">
        ${vm.status === "stopped" ? `<button class="btn-small btn-start">Start</button>` : ""}
        ${vm.status === "running" ? `<button class="btn-small btn-secondary btn-stop">Stop</button>` : ""}
        ${vm.status === "running" ? `<button class="btn-small btn-secondary btn-console" title="Open Home Access. Right-click dock icon → Paste to [name]'s home">Home Access</button>` : ""}
        ${vm.status !== "installing" ? `<button class="btn-small btn-delete">Delete</button>` : ""}
      </div>
    </div>
  `
    )
    .join("");

  listEl.querySelectorAll(".btn-start").forEach((btn) => {
    btn.addEventListener("click", async (e) => {
      const id = e.target.closest(".home-item").dataset.id;
      const r = await api.vmStart(id);
      if (!r?.ok && r?.error) api.showErrorDialog(r.error);
      else runVersionCheck();
      renderHomeList();
    });
  });
  listEl.querySelectorAll(".btn-stop").forEach((btn) => {
    btn.addEventListener("click", async (e) => {
      const id = e.target.closest(".home-item").dataset.id;
      const choice = await api.showStopConfirmDialog();
      if (choice !== "close") return;
      const r = await api.vmStop(id, true);
      if (!r?.ok && r?.error) api.showErrorDialog(r.error);
      renderHomeList();
    });
  });
  listEl.querySelectorAll(".btn-console").forEach((btn) => {
    btn.addEventListener("click", async (e) => {
      const id = e.target.closest(".home-item").dataset.id;
      const r = await api.vmShowConsole(id);
      if (!r?.ok && r?.error) api.showErrorDialog(r.error);
    });
  });
  listEl.querySelectorAll(".btn-delete").forEach((btn) => {
    btn.addEventListener("click", async (e) => {
      const item = e.target.closest(".home-item");
      const id = item.dataset.id;
      const name = item.querySelector(".home-name")?.textContent || id;
      if (!confirm(`Delete "${name}"? This cannot be undone.`)) return;
      const r = await api.vmDelete(id);
      if (!r?.ok && r?.error) api.showErrorDialog(r.error);
      renderHomeList();
    });
  });
}

function sanitizeName(name) {
  return name
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "");
}

function escapeHtml(s) {
  const div = document.createElement("div");
  div.textContent = s;
  return div.innerHTML;
}

async function waitForVmList(maxWaitMs = 20000) {
  const interval = 500;
  const start = Date.now();
  while (Date.now() - start < maxWaitMs) {
    try {
      const vms = await api.vmList();
      return vms;
    } catch {
      await new Promise((r) => setTimeout(r, interval));
    }
  }
  return null;
}

async function init() {
  runVersionCheck();
  const listEl = document.getElementById("home-list");
  listEl.innerHTML = '<p class="loading">Loading…</p>';
  showScreen("homes");

  const vms = await waitForVmList();
  const installing = vms?.find((v) => v.status === "installing");
  if (installing) {
    showScreen("install");
    startInstallPoll(installing.id);
  } else if (vms?.length) {
    await renderHomeList();
  } else {
    showScreen("welcome");
  }
}

init();
