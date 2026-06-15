const { app, BrowserWindow, ipcMain, shell } = require("electron");
const path = require("path");
const fs = require("fs");
const os = require("os");
const { spawn, execFile } = require("child_process");

const APP_NAME = "DroidProxy Windows";
const AUTH_DIR = path.join(os.homedir(), ".cli-proxy-api");
const SETTINGS_PATH = path.join(AUTH_DIR, "droidproxy-windows.json");
const CONFIG_PATH = path.join(AUTH_DIR, "droidproxy-windows-config.yaml");
const FACTORY_SETTINGS_PATH = path.join(os.homedir(), ".factory", "settings.json");

const DEFAULT_SETTINGS = {
  host: "127.0.0.1",
  port: 8317,
  requestTimeout: "10m",
  requestRetry: 3,
  debug: false,
  model: "gpt-5.5",
  maxOutputTokens: 128000,
  enableThinking: true,
  reasoningEffort: "high"
};

const REASONING_EFFORTS = ["low", "medium", "high", "xhigh"];
const DROIDPROXY_MODEL_PREFIXES = ["custom:droidproxy:", "custom:CC:"];

let mainWindow;
let proxyProcess = null;
let logs = [];
let settings = loadSettings();

function getResourcePath(...parts) {
  if (app.isPackaged) {
    return path.join(process.resourcesPath, "resources", ...parts);
  }
  return path.join(__dirname, "..", "resources", ...parts);
}

function cliBinaryPath() {
  return getResourcePath("bin", "cli-proxy-api.exe");
}

function ensureDir(dir) {
  fs.mkdirSync(dir, { recursive: true });
}

function loadSettings() {
  try {
    const raw = fs.readFileSync(SETTINGS_PATH, "utf8");
    return { ...DEFAULT_SETTINGS, ...JSON.parse(raw) };
  } catch {
    return { ...DEFAULT_SETTINGS };
  }
}

function saveSettings(nextSettings) {
  settings = sanitizeSettings({ ...settings, ...nextSettings });
  ensureDir(AUTH_DIR);
  fs.writeFileSync(SETTINGS_PATH, JSON.stringify(settings, null, 2));
  writeConfig();
  return settings;
}

function sanitizeSettings(value) {
  const port = Number(value.port);
  const retry = Number(value.requestRetry);
  const maxOutputTokens = Number(value.maxOutputTokens);
  const host = String(value.host || DEFAULT_SETTINGS.host).trim();
  const timeout = String(value.requestTimeout || DEFAULT_SETTINGS.requestTimeout).trim();
  const model = ["gpt-5.4", "gpt-5.5"].includes(value.model) ? value.model : DEFAULT_SETTINGS.model;
  const reasoningEffort = REASONING_EFFORTS.includes(value.reasoningEffort) ? value.reasoningEffort : DEFAULT_SETTINGS.reasoningEffort;

  return {
    host: /^[a-zA-Z0-9.:-]+$/.test(host) ? host : DEFAULT_SETTINGS.host,
    port: Number.isInteger(port) && port >= 1024 && port <= 65535 ? port : DEFAULT_SETTINGS.port,
    requestTimeout: timeout || DEFAULT_SETTINGS.requestTimeout,
    requestRetry: Number.isInteger(retry) && retry >= 0 && retry <= 10 ? retry : DEFAULT_SETTINGS.requestRetry,
    debug: Boolean(value.debug),
    model,
    maxOutputTokens: Number.isInteger(maxOutputTokens) && maxOutputTokens >= 1024 ? maxOutputTokens : DEFAULT_SETTINGS.maxOutputTokens,
    enableThinking: Boolean(value.enableThinking),
    reasoningEffort
  };
}

function writeConfig() {
  ensureDir(AUTH_DIR);
  const templatePath = getResourcePath("config.template.yaml");
  let config = fs.readFileSync(templatePath, "utf8");
  config = config
    .replaceAll("__PORT__", String(settings.port))
    .replaceAll("__HOST__", settings.host)
    .replaceAll("__DEBUG__", String(Boolean(settings.debug)))
    .replaceAll("__REQUEST_RETRY__", String(settings.requestRetry))
    .replaceAll("__REQUEST_TIMEOUT__", settings.requestTimeout);
  fs.writeFileSync(CONFIG_PATH, config);
  return CONFIG_PATH;
}

function log(line) {
  const stamp = new Date().toLocaleTimeString();
  logs.push(`[${stamp}] ${line}`);
  logs = logs.slice(-500);
  if (mainWindow) {
    mainWindow.webContents.send("state:logs", logs);
  }
}

function proxyState() {
  return {
    running: Boolean(proxyProcess && !proxyProcess.killed),
    pid: proxyProcess?.pid ?? null,
    baseUrl: `http://${settings.host}:${settings.port}/v1`
  };
}

function sendState() {
  if (!mainWindow) return;
  mainWindow.webContents.send("state:proxy", proxyState());
}

function killOrphanedProxy() {
  return new Promise((resolve) => {
    execFile("taskkill.exe", ["/IM", "cli-proxy-api.exe", "/F"], { windowsHide: true }, () => resolve());
  });
}

async function startProxy() {
  if (proxyProcess) return proxyState();

  const binary = cliBinaryPath();
  if (!fs.existsSync(binary)) {
    throw new Error(`Missing bundled proxy binary at ${binary}`);
  }

  writeConfig();
  await killOrphanedProxy();

  proxyProcess = spawn(binary, ["-config", CONFIG_PATH], {
    cwd: path.dirname(binary),
    windowsHide: true,
    env: process.env
  });

  log(`Started cli-proxy-api on ${settings.host}:${settings.port} (PID ${proxyProcess.pid})`);

  proxyProcess.stdout.on("data", (chunk) => log(chunk.toString().trim()));
  proxyProcess.stderr.on("data", (chunk) => log(chunk.toString().trim()));
  proxyProcess.on("exit", (code) => {
    log(`cli-proxy-api exited with code ${code}`);
    proxyProcess = null;
    sendState();
  });

  sendState();
  return proxyState();
}

function stopProxy() {
  if (!proxyProcess) return proxyState();
  log(`Stopping cli-proxy-api (PID ${proxyProcess.pid})`);
  proxyProcess.kill();
  proxyProcess = null;
  sendState();
  return proxyState();
}

function runCodexLogin() {
  return new Promise((resolve, reject) => {
    const binary = cliBinaryPath();
    if (!fs.existsSync(binary)) {
      reject(new Error(`Missing bundled proxy binary at ${binary}`));
      return;
    }

    writeConfig();
    const login = spawn(binary, ["--config", CONFIG_PATH, "-codex-login"], {
      cwd: path.dirname(binary),
      windowsHide: true,
      env: process.env,
      stdio: ["pipe", "pipe", "pipe"]
    });

    log(`Started Codex login flow (PID ${login.pid})`);
    let output = "";
    login.stdout.on("data", (chunk) => {
      const text = chunk.toString();
      output += text;
      log(text.trim());
    });
    login.stderr.on("data", (chunk) => {
      const text = chunk.toString();
      output += text;
      log(text.trim());
    });

    setTimeout(() => {
      if (!login.killed) {
        login.stdin.write("\n");
      }
    }, 12000);

    setTimeout(() => resolve({ started: true, output }), 1000);
    login.on("error", reject);
    login.on("exit", (code) => log(`Codex login command exited with code ${code}`));
  });
}

function listCodexAccounts() {
  try {
    return fs.readdirSync(AUTH_DIR)
      .filter((file) => file.endsWith(".json"))
      .map((file) => {
        const filePath = path.join(AUTH_DIR, file);
        try {
          const data = JSON.parse(fs.readFileSync(filePath, "utf8"));
          if (String(data.type || "").toLowerCase() !== "codex") return null;
          const expired = data.expired ? Date.parse(data.expired) : null;
          return {
            id: file,
            email: data.email || data.login || file,
            disabled: Boolean(data.disabled),
            expired: Number.isFinite(expired) ? new Date(expired).toISOString() : null,
            isExpired: Number.isFinite(expired) ? expired < Date.now() : false,
            path: filePath,
            hasAccessToken: Boolean(data.access_token)
          };
        } catch {
          return null;
        }
      })
      .filter(Boolean);
  } catch {
    return [];
  }
}

function readAuthValues(filePath) {
  return JSON.parse(fs.readFileSync(filePath, "utf8"));
}

async function fetchCodexUsage(accountId) {
  const account = listCodexAccounts().find((item) => item.id === accountId);
  if (!account) throw new Error("Codex account not found");

  const auth = readAuthValues(account.path);
  if (!auth.access_token) throw new Error("Missing access token");

  const headers = {
    Authorization: `Bearer ${auth.access_token}`,
    Accept: "application/json",
    "User-Agent": "codex-cli"
  };
  if (auth.account_id) {
    headers["ChatGPT-Account-Id"] = auth.account_id;
  }

  const response = await fetch("https://chatgpt.com/backend-api/wham/usage", { headers });
  if (!response.ok) {
    throw new Error(`Usage API returned ${response.status}`);
  }

  const json = await response.json();
  return parseUsageWindows(json);
}

function parseUsageWindows(json) {
  const rateLimit = json?.rate_limit;
  if (rateLimit) {
    return [
      usageWindow("5-hour", rateLimit.primary_window),
      usageWindow("Weekly", rateLimit.secondary_window)
    ].filter(Boolean);
  }
  return [];
}

function usageWindow(title, value) {
  if (!value || typeof value !== "object") return null;
  const usedPercent = numberValue(value.used_percent);
  const resetDate = resetDateFrom(value);
  return {
    title,
    usedPercent,
    remainingPercent: typeof usedPercent === "number" ? Math.max(0, 100 - usedPercent) : null,
    resetText: resetDate ? formatReset(resetDate) : resetTextFrom(value),
    resetDate: resetDate ? resetDate.toISOString() : null
  };
}

function numberValue(value) {
  if (typeof value === "number") return value;
  if (typeof value === "string") {
    const parsed = Number(value.replace("%", ""));
    return Number.isFinite(parsed) ? parsed : null;
  }
  return null;
}

function resetDateFrom(value) {
  for (const [key, item] of Object.entries(value)) {
    if (!key.toLowerCase().includes("reset")) continue;
    if (typeof item === "string") {
      const parsed = Date.parse(item);
      if (Number.isFinite(parsed)) return new Date(parsed);
    }
    if (typeof item === "number") {
      if (key.toLowerCase().includes("after")) return new Date(Date.now() + item * 1000);
      return new Date(item > 10000000000 ? item : item * 1000);
    }
  }
  return null;
}

function resetTextFrom(value) {
  for (const [key, item] of Object.entries(value)) {
    if (key.toLowerCase().includes("reset") && typeof item === "string") return item;
  }
  return null;
}

function formatReset(date) {
  const absolute = new Intl.DateTimeFormat(undefined, { dateStyle: "medium", timeStyle: "short" }).format(date);
  const diffMs = date.getTime() - Date.now();
  const diffMinutes = Math.round(diffMs / 60000);
  const relative = Math.abs(diffMinutes) < 120
    ? `${Math.abs(diffMinutes)} minute${Math.abs(diffMinutes) === 1 ? "" : "s"} ${diffMinutes >= 0 ? "from now" : "ago"}`
    : `${Math.round(Math.abs(diffMinutes) / 60)} hour${Math.round(Math.abs(diffMinutes) / 60) === 1 ? "" : "s"} ${diffMinutes >= 0 ? "from now" : "ago"}`;
  return `${relative} (${absolute})`;
}

function factoryModels() {
  const baseUrl = `http://${settings.host}:${settings.port}/v1`;
  return ["gpt-5.4", "gpt-5.5"].map((model, index) => {
    const entry = {
      model,
      id: `custom:droidproxy:${model}`,
      index,
      baseUrl,
      apiKey: "dummy-not-used",
      displayName: `DroidProxy: ${model.toUpperCase()}`,
      maxOutputTokens: settings.maxOutputTokens,
      noImageSupport: false,
      provider: "openai"
    };
    if (settings.enableThinking) {
      entry.enableThinking = true;
      entry.supportedReasoningEfforts = REASONING_EFFORTS;
      entry.defaultReasoningEffort = settings.reasoningEffort;
      entry.reasoningEffort = settings.reasoningEffort;
    }
    return entry;
  });
}

function factoryStatus() {
  try {
    const settingsJson = JSON.parse(fs.readFileSync(FACTORY_SETTINGS_PATH, "utf8"));
    const customModels = Array.isArray(settingsJson.customModels) ? settingsJson.customModels : [];
    const expectedIds = new Set(factoryModels().map((model) => model.id));
    const installedIds = new Set(customModels
      .map((model) => model?.id)
      .filter((id) => typeof id === "string" && DROIDPROXY_MODEL_PREFIXES.some((prefix) => id.startsWith(prefix))));
    const installed = expectedIds.size > 0
      && installedIds.size === expectedIds.size
      && [...expectedIds].every((id) => installedIds.has(id));
    return { installed, path: FACTORY_SETTINGS_PATH };
  } catch {
    return { installed: false, path: FACTORY_SETTINGS_PATH };
  }
}

function applyFactoryModels() {
  ensureDir(path.dirname(FACTORY_SETTINGS_PATH));
  let factorySettings = {};
  if (fs.existsSync(FACTORY_SETTINGS_PATH)) {
    factorySettings = JSON.parse(fs.readFileSync(FACTORY_SETTINGS_PATH, "utf8"));
    const timestamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\..+/, "");
    fs.copyFileSync(FACTORY_SETTINGS_PATH, path.join(path.dirname(FACTORY_SETTINGS_PATH), `settings.json.droidproxy-windows-${timestamp}.bak`));
  }

  const existing = Array.isArray(factorySettings.customModels) ? factorySettings.customModels : [];
  const kept = existing.filter((model) => {
    const id = model?.id;
    return typeof id !== "string" || !DROIDPROXY_MODEL_PREFIXES.some((prefix) => id.startsWith(prefix));
  });

  const startIndex = kept.length;
  const nextModels = factoryModels().map((model, offset) => ({ ...model, index: startIndex + offset }));
  factorySettings.customModels = [...kept, ...nextModels];
  fs.writeFileSync(FACTORY_SETTINGS_PATH, JSON.stringify(factorySettings, null, 2).replaceAll("\\/", "/"));
  return factoryStatus();
}

function createWindow() {
  mainWindow = new BrowserWindow({
    width: 520,
    height: 820,
    minWidth: 420,
    minHeight: 640,
    title: APP_NAME,
    icon: getResourcePath("icon.png"),
    backgroundColor: "#0b0e11",
    webPreferences: {
      preload: path.join(__dirname, "preload.js"),
      contextIsolation: true,
      nodeIntegration: false
    }
  });

  mainWindow.loadFile(path.join(__dirname, "renderer", "index.html"));
  mainWindow.on("closed", () => {
    mainWindow = null;
  });
}

app.whenReady().then(() => {
  ensureDir(AUTH_DIR);
  writeConfig();
  createWindow();
});

app.on("window-all-closed", () => {
  stopProxy();
  if (process.platform !== "darwin") app.quit();
});

app.on("before-quit", () => {
  stopProxy();
});

ipcMain.handle("settings:get", () => settings);
ipcMain.handle("settings:save", (_event, nextSettings) => saveSettings(nextSettings));
ipcMain.handle("proxy:start", () => startProxy());
ipcMain.handle("proxy:stop", () => stopProxy());
ipcMain.handle("proxy:state", () => proxyState());
ipcMain.handle("logs:get", () => logs);
ipcMain.handle("auth:login", () => runCodexLogin());
ipcMain.handle("auth:accounts", () => listCodexAccounts());
ipcMain.handle("usage:fetch", (_event, accountId) => fetchCodexUsage(accountId));
ipcMain.handle("factory:status", () => factoryStatus());
ipcMain.handle("factory:apply", () => applyFactoryModels());
ipcMain.handle("paths:openAuth", () => {
  ensureDir(AUTH_DIR);
  shell.openPath(AUTH_DIR);
});
ipcMain.handle("paths:openFactory", () => {
  ensureDir(path.dirname(FACTORY_SETTINGS_PATH));
  shell.openPath(path.dirname(FACTORY_SETTINGS_PATH));
});
