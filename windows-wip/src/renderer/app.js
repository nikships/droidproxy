const api = window.droidProxy;

const elements = {
  proxyStatus: document.querySelector("#proxy-status"),
  serverDot: document.querySelector("#server-dot"),
  toggleServer: document.querySelector("#toggle-server-btn"),
  endpoint: document.querySelector("#endpoint-code"),
  copyEndpoint: document.querySelector("#copy-endpoint-btn"),
  debug: document.querySelector("#debug-input"),
  accounts: document.querySelector("#accounts-list"),
  usage: document.querySelector("#usage-list"),
  logs: document.querySelector("#log-output"),
  factoryStatus: document.querySelector("#factory-status"),
  toast: document.querySelector("#toast")
};

let currentAccounts = [];
let toastTimer;

function showToast(message) {
  clearTimeout(toastTimer);
  elements.toast.textContent = message;
  elements.toast.hidden = false;
  toastTimer = setTimeout(() => {
    elements.toast.hidden = true;
  }, 5200);
}

function setSettingsForm(settings) {
  elements.debug.checked = settings.debug;
  renderEndpoint(settings);
}

function renderEndpoint(settings) {
  elements.endpoint.textContent = `http://${settings.host}:${settings.port}/v1`;
}

async function saveDebugLogging() {
  try {
    await api.saveSettings({ debug: elements.debug.checked });
    showToast("Logging setting saved.");
  } catch (error) {
    showToast(error.message || String(error));
  }
}

function renderProxyState(state) {
  const running = state.running;
  elements.proxyStatus.textContent = running ? `Running · PID ${state.pid}` : "Stopped";
  elements.serverDot.classList.toggle("running", running);
  elements.endpoint.textContent = state.baseUrl;
}

function renderLogs(logs) {
  elements.logs.textContent = logs.join("\n");
  elements.logs.scrollTop = elements.logs.scrollHeight;
}

function renderAccounts(accounts) {
  currentAccounts = accounts;
  if (!accounts.length) {
    elements.accounts.className = "list muted";
    elements.accounts.textContent = "No Codex account found.";
    return;
  }

  elements.accounts.className = "list";
  elements.accounts.innerHTML = accounts.map((account) => `
    <div class="account">
      <strong>${escapeHtml(account.email)}</strong>
      <span>${account.disabled ? "Disabled" : account.isExpired ? "Expired" : "Ready"} · ${escapeHtml(account.id)}</span>
    </div>
  `).join("");
}

function renderUsage(windows) {
  if (!windows.length) {
    elements.usage.className = "list muted";
    elements.usage.textContent = "Usage response did not include quota windows.";
    return;
  }

  elements.usage.className = "list";
  elements.usage.innerHTML = windows.map((window) => {
    const remaining = typeof window.remainingPercent === "number" ? Math.round(window.remainingPercent) : null;
    const low = remaining !== null && remaining < 20;
    return `
      <div class="usage-window">
        <strong>${escapeHtml(window.title)}</strong>
        ${remaining === null ? "<span>Usage unavailable</span>" : `
          <div class="bar"><div class="bar-fill ${low ? "low" : ""}" style="width: ${remaining}%"></div></div>
          <span>${remaining}% left</span>
        `}
        ${window.resetText ? `<span> · resets ${escapeHtml(window.resetText)}</span>` : ""}
      </div>
    `;
  }).join("");
}

function renderFactoryStatus(status) {
  elements.factoryStatus.textContent = status.installed ? "Applied" : "Not applied";
  elements.factoryStatus.classList.toggle("applied", status.installed);
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

async function refreshAccounts() {
  const accounts = await api.accounts();
  renderAccounts(accounts);
  return accounts;
}

async function refreshUsage() {
  const accounts = currentAccounts.length ? currentAccounts : await refreshAccounts();
  const account = accounts.find((item) => !item.disabled && !item.isExpired && item.hasAccessToken);
  if (!account) {
    elements.usage.className = "list muted";
    elements.usage.textContent = "Connect Codex to display quota windows.";
    return;
  }

  elements.usage.className = "list muted";
  elements.usage.textContent = "Fetching usage limits...";
  try {
    renderUsage(await api.usage(account.id));
  } catch (error) {
    elements.usage.className = "list muted";
    elements.usage.textContent = error.message || String(error);
  }
}

async function toggleServer() {
  try {
    const state = await api.proxyState();
    renderProxyState(state.running ? await api.stopProxy() : await api.startProxy());
  } catch (error) {
    showToast(error.message || String(error));
  }
}

elements.toggleServer.addEventListener("click", toggleServer);

elements.debug.addEventListener("change", saveDebugLogging);

elements.copyEndpoint.addEventListener("click", async () => {
  try {
    await navigator.clipboard.writeText(elements.endpoint.textContent);
    showToast("Endpoint copied to clipboard.");
  } catch (error) {
    showToast("Could not copy endpoint.");
  }
});

document.querySelector("#login-btn").addEventListener("click", async () => {
  try {
    await api.login();
    showToast("Browser opened for Codex login. Complete the sign-in, then refresh accounts.");
    setTimeout(refreshAccounts, 2500);
  } catch (error) {
    showToast(error.message || String(error));
  }
});

document.querySelector("#refresh-accounts-btn").addEventListener("click", refreshAccounts);
document.querySelector("#refresh-usage-btn").addEventListener("click", refreshUsage);
document.querySelector("#auth-folder-btn").addEventListener("click", () => api.openAuthFolder());
document.querySelector("#factory-folder-btn").addEventListener("click", () => api.openFactoryFolder());

document.querySelector("#apply-factory-btn").addEventListener("click", async () => {
  try {
    renderFactoryStatus(await api.applyFactory());
    showToast("Factory custom models updated. Restart Factory or open a new session to see them.");
  } catch (error) {
    showToast(error.message || String(error));
  }
});

document.querySelector("#clear-log-btn").addEventListener("click", () => {
  elements.logs.textContent = "";
});

api.onProxyState(renderProxyState);
api.onLogs(renderLogs);

async function boot() {
  setSettingsForm(await api.getSettings());
  renderProxyState(await api.proxyState());
  renderLogs(await api.getLogs());
  renderFactoryStatus(await api.factoryStatus());
  await refreshAccounts();
  await refreshUsage();
}

boot().catch((error) => showToast(error.message || String(error)));
