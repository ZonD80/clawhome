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

function selectedGuestType() {
  return document.querySelector('input[name="guest-type"]:checked')?.value || "macos";
}

function syncLinuxRelease() {
  const linux = selectedGuestType() === "linux";
  const note = document.getElementById("linux-release-note");
  const group = document.getElementById("linux-image-group");
  if (!linux) {
    if (note) note.hidden = true;
    if (group) group.hidden = true;
    return;
  }
  if (!biaRelease) {
    if (note) {
      note.hidden = false;
      note.textContent = "Checking the bia release…";
    }
    if (group) group.hidden = true;
    return;
  }
  if (biaRelease.ok) {
    if (note) {
      note.hidden = false;
      note.textContent = `bia ${biaRelease.version} (${biaRelease.tag}) from GitHub.`;
    }
    if (group) group.hidden = true;
    return;
  }
  if (note) {
    note.hidden = false;
    note.textContent = biaRelease.error || "The bia release could not be used.";
  }
  if (group) group.hidden = false;
}

async function lookupBiaRelease() {
  const seq = ++biaLookup;
  biaRelease = null;
  syncLinuxRelease();
  const result = await api.lookupBiaRelease?.();
  if (seq !== biaLookup) return;
  biaRelease = result?.ok
    ? result
    : { ok: false, error: result?.error || "The bia release could not be used." };
  syncLinuxRelease();
}

function syncGuestTypeFields() {
  const linux = selectedGuestType() === "linux";
  document.getElementById("linux-fmm-group").hidden = !linux;
  document.getElementById("disk-group").hidden = linux;
  const fields = document.getElementById("fmm-fields");
  if (fields) fields.hidden = !document.getElementById("fmm-enabled").checked;
  syncLinuxRelease();
}

const FMM_DEFAULT_MODELS = {
  openrouter: "deepseek/deepseek-v4.1-flash",
  openai: "gpt-5",
  anthropic: "claude-opus-4-6",
  xai: "grok-4.6",
  deepseek: "deepseek-chat",
  qwen: "qwen-max",
  chatgpt: "gpt-5",
};

let loadedChatgpt = null;
let loadedFmmPath = null;
let fmmProvider = "";
let cloudModels = [];
let signingIn = false;
let modelFetch = 0;
let keyTimer = null;
let chatgptBelongsToHome = false;
/** null while the latest bia release is still being checked. */
let biaRelease = null;
let biaLookup = 0;

function providerForKey(key) {
  const k = key.trim();
  if (k.startsWith("sk-or-")) return "openrouter";
  if (k.startsWith("sk-ant-")) return "anthropic";
  if (k.startsWith("xai-")) return "xai";
  if (
    k.startsWith("sk-proj-") ||
    k.startsWith("sk-svcacct-") ||
    k.startsWith("sk-admin-") ||
    (k.startsWith("sk-") && k.includes("T3BlbkFJ"))
  ) {
    return "openai";
  }
  return "";
}

function defaultFmmModel(provider) {
  return FMM_DEFAULT_MODELS[provider] || "";
}

function setFmmProvider(provider, modelFromFile) {
  const providerEl = document.getElementById("fmm-provider");
  const modelEl = document.getElementById("fmm-model");
  const chatgptOption = document.getElementById("fmm-provider-chatgpt");
  const next = provider || "";
  if (chatgptOption) chatgptOption.hidden = next !== "chatgpt";
  const prevDefault = defaultFmmModel(fmmProvider);
  fmmProvider = next;
  providerEl.value = next;
  const nextDefault = defaultFmmModel(next);
  if (modelFromFile !== undefined) {
    modelEl.value = modelFromFile || nextDefault;
  } else if (!modelEl.value.trim() || modelEl.value.trim() === prevDefault) {
    modelEl.value = nextDefault;
  }
}

function setFmmStatus(text) {
  const el = document.getElementById("fmm-status");
  if (el) el.textContent = text || "";
}

function syncChatgptPanel() {
  const signed = document.getElementById("fmm-chatgpt-signed");
  const start = document.getElementById("fmm-chatgpt-start");
  const keys = document.getElementById("fmm-key-block");
  const email = document.getElementById("fmm-chatgpt-email");
  const button = document.getElementById("btn-chatgpt");
  const hasChatgpt = !!loadedChatgpt;
  if (signed) signed.hidden = !hasChatgpt;
  if (start) start.hidden = hasChatgpt;
  if (keys) keys.hidden = hasChatgpt;
  if (email) {
    email.textContent = hasChatgpt
      ? `Signed in to ChatGPT as ${loadedChatgpt.email || "this account"}.`
      : "";
  }
  if (button) {
    button.disabled = signingIn;
    button.textContent = signingIn ? "Waiting for the browser…" : "Continue with ChatGPT";
  }
  const help = document.getElementById("fmm-key-help");
  const key = document.getElementById("fmm-key")?.value.trim() || "";
  if (help && !hasChatgpt) help.open = !key;
}

function renderModelList() {
  const list = document.getElementById("fmm-model-list");
  const searchGroup = document.getElementById("fmm-model-search-group");
  if (!list) return;
  const query = (document.getElementById("fmm-model-search")?.value || "").trim().toLowerCase();
  const words = query.split(/\s+/).filter(Boolean);
  const hits = cloudModels.filter((model) => {
    const hay = `${model.id} ${model.name || ""}`.toLowerCase();
    return words.every((word) => hay.includes(word));
  });
  const show = hits.length > 0;
  list.hidden = !show;
  if (searchGroup) searchGroup.hidden = cloudModels.length === 0;
  const current = document.getElementById("fmm-model")?.value.trim() || "";
  const shown = hits.slice(0, 300);
  list.innerHTML = shown
    .map((model) => {
      let text = model.id;
      if (model.name && model.name !== model.id) text += ` — ${model.name}`;
      if (model.ctx > 0) text += ` (${Math.round(model.ctx / 1000)}k ctx)`;
      return `<button type="button" class="${model.id === current ? "selected" : ""}" data-id="${escapeHtml(model.id)}" data-ctx="${model.ctx || 0}">${escapeHtml(text)}</button>`;
    })
    .join("");
  if (hits.length > 300) {
    list.insertAdjacentHTML("beforeend", `<p class="field-hint">… ${hits.length - 300} more. Refine the search.</p>`);
  }
}

function signOutChatgpt() {
  loadedChatgpt = null;
  loadedFmmPath = null;
  chatgptBelongsToHome = false;
  const key = document.getElementById("fmm-key");
  if (key) key.value = "";
  cloudModels = [];
  const search = document.getElementById("fmm-model-search");
  if (search) search.value = "";
  setFmmProvider("openrouter");
  renderModelList();
  setFmmStatus("");
  syncChatgptPanel();
}

function applyChatgpt(auth) {
  loadedChatgpt = auth;
  loadedFmmPath = null;
  chatgptBelongsToHome = false;
  document.getElementById("fmm-enabled").checked = true;
  document.getElementById("fmm-key").value = auth?.access_token || "";
  document.getElementById("fmm-base-url").value = "";
  setFmmProvider("chatgpt", "");
  document.getElementById("fmm-model").value = "";
  setFmmStatus(auth?.email ? `Signed in to ChatGPT as ${auth.email}` : "Signed in to ChatGPT");
  syncChatgptPanel();
  syncGuestTypeFields();
  fetchModels();
}

async function fetchModels() {
  const seq = ++modelFetch;
  const provider = document.getElementById("fmm-provider").value.trim();
  const apiKey = document.getElementById("fmm-key").value.trim();
  if (provider !== "chatgpt" && !apiKey) {
    cloudModels = [];
    renderModelList();
    return;
  }
  if (provider === "chatgpt" && !loadedChatgpt?.access_token && !apiKey) return;
  setFmmStatus("Loading models…");
  const result = await api.listFmmModels?.({
    provider,
    apiKey,
    baseUrl: document.getElementById("fmm-base-url").value.trim(),
    chatgpt: loadedChatgpt,
  });
  if (seq !== modelFetch) return;
  if (!result?.ok) {
    cloudModels = [];
    renderModelList();
    setFmmStatus(result?.error || "Could not load models");
    return;
  }
  if (result.provider && result.provider !== fmmProvider) setFmmProvider(result.provider);
  if (result.baseUrl) document.getElementById("fmm-base-url").value = result.baseUrl;
  cloudModels = result.models || [];
  renderModelList();
  setFmmStatus(`${result.provider}: ${cloudModels.length} models`);
}

function resetCreateForm() {
  document.getElementById("home-name").value = "";
  document.getElementById("disk-gb").value = "32";
  document.getElementById("ram-gb").value = "4";
  document.getElementById("image-url").value = "";
  document.getElementById("fmm-enabled").checked = true;
  document.getElementById("fmm-provider").value = "";
  document.getElementById("fmm-key").value = "";
  document.getElementById("fmm-model").value = "";
  document.getElementById("fmm-base-url").value = "";
  document.getElementById("fmm-ctx").value = "131072";
  const search = document.getElementById("fmm-model-search");
  if (search) search.value = "";
  loadedChatgpt = null;
  loadedFmmPath = null;
  fmmProvider = "";
  cloudModels = [];
  signingIn = false;
  chatgptBelongsToHome = false;
  const chatgptOption = document.getElementById("fmm-provider-chatgpt");
  if (chatgptOption) chatgptOption.hidden = true;
  renderModelList();
  setFmmStatus("");
  syncChatgptPanel();
  const macos = document.querySelector('input[name="guest-type"][value="macos"]');
  if (macos) macos.checked = true;
  syncGuestTypeFields();
  document.getElementById("config-error").textContent = "";
}

function createOptions() {
  const guestType = selectedGuestType();
  const imageUrl = document.getElementById("image-url").value.trim();
  return {
    name: document.getElementById("home-name").value.trim(),
    ramMb: (parseInt(document.getElementById("ram-gb").value, 10) || 4) * 1024,
    diskGb: parseInt(document.getElementById("disk-gb").value, 10) || 32,
    guestType,
    imageUrl: guestType === "linux" ? (biaRelease?.ok ? biaRelease.url : imageUrl) : undefined,
    fmm:
      guestType === "linux" && document.getElementById("fmm-enabled").checked
        ? {
            provider: document.getElementById("fmm-provider").value.trim(),
            apiKey: document.getElementById("fmm-key").value.trim(),
            model: document.getElementById("fmm-model").value.trim(),
            baseUrl: document.getElementById("fmm-base-url").value.trim(),
            ctx: parseInt(document.getElementById("fmm-ctx").value, 10) || 131072,
            chatgpt: loadedChatgpt,
            sourcePath: loadedChatgpt ? loadedFmmPath : undefined,
          }
        : undefined,
  };
}

document.querySelectorAll('input[name="guest-type"]').forEach((input) => {
  input.addEventListener("change", () => {
    syncGuestTypeFields();
    if (selectedGuestType() === "linux") lookupBiaRelease();
  });
});

document.getElementById("btn-pick-image").addEventListener("click", async () => {
  const url = await api.pickDiskImage?.();
  if (url) document.getElementById("image-url").value = url;
});

document.getElementById("fmm-enabled").addEventListener("change", syncGuestTypeFields);

document.getElementById("fmm-provider").addEventListener("change", () => {
  setFmmProvider(document.getElementById("fmm-provider").value);
  fetchModels();
});

document.getElementById("fmm-key").addEventListener("input", () => {
  loadedChatgpt = null;
  loadedFmmPath = null;
  chatgptBelongsToHome = false;
  const detected = providerForKey(document.getElementById("fmm-key").value);
  if (detected) setFmmProvider(detected);
  syncChatgptPanel();
  clearTimeout(keyTimer);
  keyTimer = setTimeout(fetchModels, 400);
});

document.getElementById("fmm-model").addEventListener("input", renderModelList);
document.getElementById("fmm-model-search").addEventListener("input", renderModelList);
document.getElementById("fmm-model-list").addEventListener("click", (event) => {
  const button = event.target.closest("button[data-id]");
  if (!button) return;
  document.getElementById("fmm-model").value = button.dataset.id || "";
  const ctx = parseInt(button.dataset.ctx || "0", 10);
  if (ctx > 0) document.getElementById("fmm-ctx").value = String(Math.min(ctx, 2000000));
  renderModelList();
});

document.querySelectorAll("#fmm-key-help [data-url]").forEach((button) => {
  button.addEventListener("click", () => api.openExternal?.(button.dataset.url));
});

api.onChatgptStatus?.((status) => setFmmStatus(status));

document.getElementById("btn-chatgpt").addEventListener("click", async () => {
  if (signingIn) return;
  signingIn = true;
  syncChatgptPanel();
  setFmmStatus("Finish signing in in your browser…");
  try {
    const result = await api.signInChatGpt?.();
    if (!result?.ok) {
      setFmmStatus(result?.error || "ChatGPT sign-in failed");
      return;
    }
    applyChatgpt(result.auth);
  } catch (err) {
    setFmmStatus(err?.message || "ChatGPT sign-in failed");
  } finally {
    signingIn = false;
    syncChatgptPanel();
  }
});

document.getElementById("btn-chatgpt-out").addEventListener("click", signOutChatgpt);

document.getElementById("btn-load-fmm").addEventListener("click", async () => {
  const loaded = await api.loadFmmFile?.();
  if (!loaded) return;
  if (!loaded.ok) {
    api.showErrorDialog(loaded.error || "Could not read fmm.json");
    return;
  }
  document.getElementById("fmm-enabled").checked = true;
  document.getElementById("fmm-key").value = loaded.apiKey || "";
  document.getElementById("fmm-base-url").value = loaded.baseUrl || "";
  document.getElementById("fmm-ctx").value = String(loaded.ctx || 131072);
  loadedChatgpt = loaded.chatgpt || null;
  loadedFmmPath = loaded.chatgpt ? loaded.sourcePath || null : null;
  chatgptBelongsToHome = false;
  setFmmProvider(loaded.provider || providerForKey(loaded.apiKey || ""), loaded.model || "");
  syncChatgptPanel();
  syncGuestTypeFields();
  fetchModels();
});

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
  const options = createOptions();

  document.getElementById("config-error").textContent = "";

  if (!options.name) {
    api.showErrorDialog("Enter your bot name");
    return;
  }
  if (options.guestType === "linux" && !options.imageUrl) {
    api.showErrorDialog(
      biaRelease ? "Enter a disk image URL" : "Still checking the bia release…"
    );
    return;
  }

  const btn = document.getElementById("btn-create");
  btn.disabled = true;
  btn.textContent = options.fmm ? "Checking key…" : "Creating…";

  try {
    let prepared = options;
    let hello = "";
    if (options.fmm) {
      const check = await api.checkFmm(options.fmm);
      if (!check?.ok) {
        api.showErrorDialog(check?.error || "Cloud AI key check failed");
        return;
      }
      hello = check.hello || "";
      try {
        const saved = JSON.parse(check.config);
        if (saved?.chatgpt) {
          loadedChatgpt = saved.chatgpt;
          document.getElementById("fmm-key").value = saved.api_key || saved.chatgpt.access_token || "";
          chatgptBelongsToHome = true;
        }
      } catch {
        /* the create still uses the checked config string */
      }
      prepared = {
        ...options,
        fmmJson: check.config,
        fmmSourcePath: check.sourcePath || undefined,
      };
      delete prepared.fmm;
    }
    btn.textContent = "Creating…";
    const r = await api.vmCreate(prepared);
    if (r.ok && r.vm) {
      showScreen("install");
      startInstallPoll(r.vm.id, hello);
    } else if (r.error === "VM already exists") {
      const vmId = sanitizeName(options.name);
      if (!vmId) {
        api.showErrorDialog(r.error);
        return;
      }
      const choice = await api.showVmExistsDialog(vmId);
      if (choice === "overwrite") {
        await api.vmDelete(vmId);
        const r2 = await api.vmCreate(prepared);
        if (r2.ok && r2.vm) {
          showScreen("install");
          startInstallPoll(r2.vm.id, hello);
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

function startInstallPoll(vmId, hello) {
  const statusEl = document.getElementById("install-status");
  const progressEl = document.getElementById("install-progress");
  const percentEl = document.getElementById("install-percent");
  const helloEl = document.getElementById("install-hello");
  if (helloEl) {
    helloEl.hidden = !hello;
    helloEl.textContent = hello || "";
  }

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
      if (chatgptBelongsToHome) signOutChatgpt();
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
        <span class="home-kind">${vm.guestType === "linux" ? "Linux (bia)" : "macOS"}</span>
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
