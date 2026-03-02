import { app } from "electron";
import { spawn, type ChildProcess } from "node:child_process";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { existsSync, unlinkSync } from "node:fs";
import { createConnection } from "node:net";
import { waitForPortFile, getVmPort, VM_PORT_FILE } from "./claw-ports.js";

const __dirname = dirname(fileURLToPath(import.meta.url));

const isPackaged = app.isPackaged;

function getClawVmDir(): string {
  if (isPackaged) {
    return process.resourcesPath;
  }
  return join(__dirname, "..", "resources");
}

function getClawVmBinary(): string | null {
  // ClawVMManager is the long-lived process; ClawVM is an alias for compatibility
  if (isPackaged) {
    const packagedPath = join(process.resourcesPath, "ClawVMManager");
    if (existsSync(packagedPath)) return packagedPath;
    const legacyPath = join(process.resourcesPath, "ClawVM");
    if (existsSync(legacyPath)) return legacyPath;
    return null;
  }
  const resourcesDir = join(__dirname, "..", "resources");
  const binaryPath = join(resourcesDir, "ClawVMManager");
  if (existsSync(binaryPath)) return binaryPath;
  const legacyPath = join(resourcesDir, "ClawVM");
  if (existsSync(legacyPath)) return legacyPath;
  return null;
}

function isPortInUse(port: number): Promise<boolean> {
  return new Promise((resolve) => {
    const socket = createConnection(port, "127.0.0.1", () => {
      socket.destroy();
      resolve(true);
    });
    socket.on("error", () => resolve(false));
  });
}

let clawVmProcess: ChildProcess | null = null;

export async function startClawVm(options?: {
  onProgress?: (message: string) => void;
}): Promise<{ ok: boolean; message: string }> {
  if (clawVmProcess) {
    return { ok: true, message: "ClawVM already running" };
  }

  const existingPort = getVmPort();
  if (existingPort != null) {
    const alreadyRunning = await isPortInUse(existingPort);
    if (alreadyRunning) {
      return { ok: true, message: "ClawVM already running" };
    }
  }

  const binary = getClawVmBinary();
  const vmDir = getClawVmDir();

  if (!binary || !existsSync(binary)) {
    const debugMsg = `ClawVMManager not found. Build with: npm run build:clawvm`;
    return { ok: false, message: debugMsg };
  }

  const env: Record<string, string> = { ...process.env };
  const onProgress = options?.onProgress;

  try {
    onProgress?.("Spawning ClawVM...");
    if (existsSync(VM_PORT_FILE)) {
      try {
        unlinkSync(VM_PORT_FILE);
      } catch {
        /* ignore */
      }
    }
    clawVmProcess = spawn(binary, [], {
      cwd: vmDir,
      stdio: ["ignore", "pipe", "pipe"],
      detached: true,
      env,
    });
    clawVmProcess.stdout?.on("data", (d) => process.stdout.write(`[ClawVM] ${d}`));
    clawVmProcess.stderr?.on("data", (d) => process.stderr.write(`[ClawVM] ${d}`));
    clawVmProcess.unref();
    clawVmProcess.on("error", (err) => console.error("[ClawHome] ClawVMManager error:", err));
    clawVmProcess.on("exit", () => {
      clawVmProcess = null;
    });
    onProgress?.("Waiting for ClawVM port (up to 15s)...");
    const port = await waitForPortFile(VM_PORT_FILE, 15_000);
    if (port == null) {
      return { ok: false, message: "ClawVM started but vm.port not written after 15s" };
    }
    for (let i = 0; i < 20; i++) {
      await new Promise((r) => setTimeout(r, 500));
      const ready = await isPortInUse(port);
      if (ready) {
        return { ok: true, message: "ClawVM started" };
      }
    }
    return { ok: false, message: `ClawVM port ${port} not ready after 10s` };
  } catch (err) {
    return {
      ok: false,
      message: err instanceof Error ? err.message : "ClawVM spawn failed",
    };
  }
}

export function stopClawVm(): void {
  if (clawVmProcess) {
    clawVmProcess.kill("SIGTERM");
    clawVmProcess = null;
  }
}
