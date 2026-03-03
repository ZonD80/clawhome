/**
 * Parses /var/db/dhcpd_leases to derive the NAT gateway (host) IP.
 * Apple's NAT uses 192.168.64.0/24; the host is the first IP in subnet (192.168.64.1).
 */
import { readFileSync, existsSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import { spawn, type ChildProcess } from "node:child_process";
import { app } from "electron";

const DHCPD_LEASES = "/var/db/dhcpd_leases";

/** Apple NAT uses 192.168.64.0/24; gateway is .1. Fallback when no leases yet. */
const DEFAULT_NAT_GATEWAY = "192.168.64.1";

/**
 * Extracts any ip_address from dhcpd_leases and returns the first IP in that subnet (gateway).
 * Falls back to 192.168.64.1 when file is missing or no lease found (Apple NAT default).
 */
export function getHostIPFromDhcpdLeases(): string {
  try {
    if (!existsSync(DHCPD_LEASES)) return DEFAULT_NAT_GATEWAY;
    const content = readFileSync(DHCPD_LEASES, "utf-8");
    const match = content.match(/ip_address=(\d+\.\d+\.\d+\.\d+)/);
    if (!match) return DEFAULT_NAT_GATEWAY;
    const parts = match[1]!.split(".").map((p) => parseInt(p, 10));
    if (parts.length !== 4 || parts.some((n) => !Number.isFinite(n))) return DEFAULT_NAT_GATEWAY;
    // First IP in /24 subnet = gateway (e.g. 192.168.64.1)
    parts[3] = 1;
    return parts.join(".");
  } catch {
    return DEFAULT_NAT_GATEWAY;
  }
}

let smbProcess: ChildProcess | null = null;

function getGoSmb2Path(): string | null {
  if (app.isPackaged) {
    const p = join(process.resourcesPath, "go-smb2");
    return existsSync(p) ? p : null;
  }
  const p = join(__dirname, "..", "resources", "go-smb2");
  return existsSync(p) ? p : null;
}

export function startSmbBackup(): void {
  if (smbProcess) return;

  const binary = getGoSmb2Path();
  if (!binary) {
    console.warn("[ClawHome] go-smb2 not found, SMB backup share disabled");
    return;
  }

  const hostIP = getHostIPFromDhcpdLeases();
  const backupsDir = join(homedir(), "clawhome", "backups");
  const listenAddr = `${hostIP}:8082`;

  try {
    smbProcess = spawn(binary, ["-g", "-l", listenAddr, "-m", backupsDir, "-s", "ClawHomeBackups"], {
      stdio: ["ignore", "pipe", "pipe"],
      env: { ...process.env },
    });
    smbProcess.stdout?.on("data", (d) => process.stdout.write(`[go-smb2] ${d}`));
    smbProcess.stderr?.on("data", (d) => process.stderr.write(`[go-smb2] ${d}`));
    smbProcess.on("error", (err) => console.error("[ClawHome] go-smb2 error:", err));
    smbProcess.on("exit", (code) => {
      smbProcess = null;
      if (code != null && code !== 0) {
        console.warn("[ClawHome] go-smb2 exited with code", code);
      }
    });
    console.log("[ClawHome] go-smb2 started:", listenAddr, "->", backupsDir);
  } catch (err) {
    console.error("[ClawHome] go-smb2 spawn failed:", err);
    smbProcess = null;
  }
}

export function stopSmbBackup(): void {
  if (smbProcess) {
    smbProcess.kill("SIGTERM");
    smbProcess = null;
  }
}
