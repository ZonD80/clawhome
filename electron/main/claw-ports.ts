import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

const CLAWHOME_DIR = join(homedir(), "clawhome");
const VM_PORT_FILE = join(CLAWHOME_DIR, "vm.port");

export function getVmPort(): number | null {
  try {
    if (!existsSync(VM_PORT_FILE)) return null;
    const s = readFileSync(VM_PORT_FILE, "utf-8").trim();
    const p = parseInt(s, 10);
    return Number.isFinite(p) && p > 0 && p < 65536 ? p : null;
  } catch {
    return null;
  }
}

export async function waitForPortFile(
  portFile: string,
  timeoutMs: number = 15_000
): Promise<number | null> {
  const start = Date.now();
  while (Date.now() - start < timeoutMs) {
    try {
      if (existsSync(portFile)) {
        const s = readFileSync(portFile, "utf-8").trim();
        const p = parseInt(s, 10);
        if (Number.isFinite(p) && p > 0 && p < 65536) return p;
      }
    } catch {
      /* ignore */
    }
    await new Promise((r) => setTimeout(r, 200));
  }
  return null;
}

export { VM_PORT_FILE };
