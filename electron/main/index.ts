import { app, BrowserWindow, ipcMain, dialog, shell } from "electron";
import { join } from "node:path";
import { homedir } from "node:os";
import { mkdirSync, existsSync } from "node:fs";
import { request as httpsRequest } from "node:https";
import {
  listVms,
  createVm,
  installProgress,
  startVm,
  stopVm,
  deleteVm,
  showConsoleVm,
} from "./vm-manager.js";
import { startClawVm, stopClawVm } from "./claw-vm-launcher.js";
import { startSmbBackup, stopSmbBackup } from "./smb-backup-launcher.js";

// Set userData before app is ready so data persists across app updates
const CLAWHOME_DIR = join(homedir(), "clawhome");
app.setPath("userData", join(CLAWHOME_DIR, "userData"));

const CLAWHOME_HOMES_DIR = join(CLAWHOME_DIR, "homes");
const CLAWHOME_BACKUPS_DIR = join(CLAWHOME_DIR, "backups");

function safeForIPC<T>(value: T): T {
  if (value === undefined || value === null) return value;
  if (typeof value === "string" || typeof value === "number" || typeof value === "boolean")
    return value;
  try {
    return JSON.parse(JSON.stringify(value)) as T;
  } catch {
    return String(value) as unknown as T;
  }
}

let mainWindow: BrowserWindow | null = null;
let isQuitting = false;

function createWindow() {
  const preloadPath = join(__dirname, "../preload/index.mjs");
  const iconPath = join(__dirname, "../../icon.png");
  mainWindow = new BrowserWindow({
    width: 420,
    height: 520,
    minWidth: 360,
    minHeight: 400,
    show: false,
    icon: iconPath,
    webPreferences: {
      preload: preloadPath,
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: false,
    },
  });

  if (process.env.VITE_DEV_SERVER_URL) {
    mainWindow.loadURL(process.env.VITE_DEV_SERVER_URL);
  } else {
    mainWindow.loadFile(join(__dirname, "../../dist/index.html"));
  }

  mainWindow.on("ready-to-show", () => {
    mainWindow?.show();
  });

  // On macOS, hide instead of close so dock click restores the window
  mainWindow.on("close", (e) => {
    if (!isQuitting && process.platform === "darwin") {
      e.preventDefault();
      mainWindow?.hide();
    }
  });

  mainWindow.on("closed", () => {
    mainWindow = null;
  });
}

app.whenReady().then(() => {
  mkdirSync(CLAWHOME_HOMES_DIR, { recursive: true });
  mkdirSync(CLAWHOME_BACKUPS_DIR, { recursive: true });
  createWindow();

  (async () => {
    const result = await startClawVm({
      onProgress: (msg) => console.log("[ClawHome]", msg),
    });
    if (!result.ok) {
      console.warn("[ClawHome] ClawVM:", result.message);
    } else {
      const vms = await listVms().catch(() => []);
      if (vms.some((v) => v.status === "running")) {
        setTimeout(() => startSmbBackup(), 10_000);
      }
    }
  })();
});

app.on("before-quit", () => {
  isQuitting = true;
  stopSmbBackup();
  stopClawVm();
});

// On macOS, don't quit when main window closes — keep ClawVM running in background
app.on("window-all-closed", () => {
  if (process.platform !== "darwin") {
    app.quit();
  }
});

// On macOS, restore window when dock icon is clicked
app.on("activate", () => {
  if (mainWindow) {
    mainWindow.show();
  } else {
    createWindow();
  }
});

const RELEASES_LATEST_URL = "https://github.com/ZonD80/clawhome/releases/latest";

function parseVersion(s: string): number[] {
  const m = s.replace(/^v/, "").match(/^(\d+)\.(\d+)\.(\d+)/);
  return m ? [parseInt(m[1], 10), parseInt(m[2], 10), parseInt(m[3], 10)] : [];
}

function isNewer(current: string, latest: string): boolean {
  const c = parseVersion(current);
  const l = parseVersion(latest);
  if (l.length === 0) return false;
  if (c.length === 0) return true;
  for (let i = 0; i < 3; i++) {
    if (l[i]! > c[i]!) return true;
    if (l[i]! < c[i]!) return false;
  }
  return false;
}

async function checkForUpdates(): Promise<
  { hasUpdate: false } | { hasUpdate: true; latestVersion: string; url: string }
> {
  try {
    const redirectUrl = await new Promise<string>((resolve, reject) => {
      const req = httpsRequest(
        RELEASES_LATEST_URL,
        { method: "HEAD" },
        (res) => {
          if (res.statusCode === 301 || res.statusCode === 302) {
            const loc = res.headers.location;
            if (typeof loc === "string") {
              resolve(loc.startsWith("http") ? loc : `https://github.com${loc.startsWith("/") ? "" : "/"}${loc}`);
            } else {
              reject(new Error("No Location header"));
            }
          } else {
            reject(new Error(`Unexpected status ${res.statusCode}`));
          }
        }
      );
      req.on("error", reject);
      req.setTimeout(10000, () => {
        req.destroy();
        reject(new Error("Timeout"));
      });
      req.end();
    });
    const match = redirectUrl.match(/\/tag\/(v[\d.]+)/i);
    if (!match) return { hasUpdate: false };
    const latestVersion = match[1]!;
    const currentVersion = app.getVersion();
    if (!isNewer(currentVersion, latestVersion)) return { hasUpdate: false };
    return {
      hasUpdate: true,
      latestVersion,
      url: redirectUrl,
    };
  } catch {
    return { hasUpdate: false };
  }
}

ipcMain.handle("get-version", () => app.getVersion());
ipcMain.handle("check-for-updates", () => checkForUpdates());
ipcMain.handle("open-clawhome-dir", () => shell.openPath(CLAWHOME_DIR));
ipcMain.handle("open-external", (_, url: string) => shell.openExternal(url));
ipcMain.handle(
  "show-stop-confirm-dialog",
  async (): Promise<"close" | "cancel"> => {
    const { response } = await dialog.showMessageBox(mainWindow!, {
      type: "warning",
      message: "Are you sure to close this Home?",
      detail: "Make sure you shut down macOS inside in order to prevent data loss.",
      buttons: ["Cancel", "Close immediately"],
    });
    return response === 1 ? "close" : "cancel";
  }
);
ipcMain.handle("show-error-dialog", async (_, message: string) => {
  await dialog.showMessageBox(mainWindow!, {
    type: "error",
    message: "Error",
    detail: message,
    buttons: ["OK"],
  });
});
ipcMain.handle(
  "show-vm-exists-dialog",
  async (_, vmId: string): Promise<"overwrite" | "finder"> => {
    const vmPath = join(CLAWHOME_HOMES_DIR, vmId);
    const { response } = await dialog.showMessageBox(mainWindow!, {
      type: "question",
      message: "It looks like directory already exists?",
      buttons: ["Overwrite", "Open in Finder"],
    });
    if (response === 1) {
      shell.showItemInFolder(vmPath);
      return "finder";
    }
    return "overwrite";
  }
);
ipcMain.handle("vm-list", async () => safeForIPC(await listVms()));
ipcMain.handle(
  "vm-create",
  async (
    _,
    options: { name: string; ramMb?: number; diskGb?: number; ipswPath?: string }
  ) => safeForIPC(await createVm(options))
);
ipcMain.handle(
  "vm-install-progress",
  async (_, vmId: string) => safeForIPC(await installProgress(vmId))
);
ipcMain.handle("vm-start", async (_, vmId: string) => {
  const result = await startVm(vmId);
  if (result.ok) {
    setTimeout(() => startSmbBackup(), 10_000);
  }
  return safeForIPC(result);
});
ipcMain.handle(
  "vm-stop",
  async (_, vmId: string, force?: boolean) => {
    const result = await stopVm(vmId, force);
    if (result.ok) {
      const vms = await listVms().catch(() => []);
      if (!vms.some((v) => v.status === "running")) stopSmbBackup();
    }
    return safeForIPC(result);
  }
);
ipcMain.handle("vm-delete", async (_, vmId: string) => safeForIPC(await deleteVm(vmId)));
ipcMain.handle(
  "vm-show-console",
  async (_, vmId: string) => safeForIPC(await showConsoleVm(vmId))
);
