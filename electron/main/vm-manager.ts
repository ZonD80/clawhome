import { request as httpRequest } from "node:http";
import { getVmPort } from "./claw-ports.js";

const CLAW_VM_HOST = "127.0.0.1";

export interface VmInfo {
  id: string;
  name: string;
  path: string;
  status: "running" | "stopped" | "installing";
  ramMb: number;
  diskGb: number;
  guestType?: string;
}

function request<T>(path: string, init?: { method?: string; body?: string }): Promise<T> {
  const port = getVmPort();
  if (port == null) {
    return Promise.reject(new Error("ClawVM port not found. Start ClawVM first."));
  }
  return new Promise((resolve, reject) => {
    const body = init?.body;
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (body) headers["Content-Length"] = String(Buffer.byteLength(body, "utf-8"));
    const req = httpRequest(
      {
        host: CLAW_VM_HOST,
        port,
        path,
        method: init?.method ?? "GET",
        headers,
        family: 4,
      },
      (res) => {
        const chunks: Buffer[] = [];
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("end", () => {
          const buf = Buffer.concat(chunks);
          const text = buf.toString("utf-8");
          if (res.statusCode && res.statusCode >= 400) {
            let msg = `HTTP ${res.statusCode}`;
            try {
              const parsed = JSON.parse(text) as { error?: string };
              if (typeof parsed?.error === "string") msg = parsed.error;
            } catch {
              if (text) msg = text;
            }
            reject(new Error(msg));
            return;
          }
          try {
            resolve(JSON.parse(text) as T);
          } catch {
            reject(new Error(text || "Invalid JSON response"));
          }
        });
      }
    );
    req.on("error", (err) => {
      const msg = err.message;
      if (msg.includes("ECONNREFUSED") || msg.includes("connect")) {
        reject(new Error("ClawVM not running. Start ClawVM first."));
      } else {
        reject(err);
      }
    });
    if (body) req.write(body);
    req.end();
  });
}

export async function installProgress(
  vmId: string
): Promise<{ ok: boolean; fractionCompleted?: number; phase?: string; error?: string }> {
  try {
    const data = await request<{
      ok: boolean;
      fractionCompleted?: number;
      phase?: string;
      error?: string;
    }>("/install-progress/" + encodeURIComponent(vmId));
    return data;
  } catch {
    return { ok: false };
  }
}

export async function listVms(): Promise<VmInfo[]> {
  const data = await request<{ ok: boolean; vms?: VmInfo[] }>("/vms");
  if (!data.ok || !data.vms) return [];
  return data.vms;
}

export interface CreateVmOptions {
  name: string;
  ramMb?: number;
  diskGb?: number;
  ipswPath?: string;
}

export async function createVm(
  options: CreateVmOptions
): Promise<{ ok: boolean; vm?: VmInfo; error?: string }> {
  try {
    const body = JSON.stringify({
      guest_type: "macos",
      name: options.name,
      ram_mb: options.ramMb ?? 4096,
      disk_gb: options.diskGb ?? 32,
      ipsw_path: options.ipswPath ?? undefined,
    });
    const data = await request<{ ok: boolean; vm?: VmInfo; error?: string }>("/create", {
      method: "POST",
      body,
    });
    if (data.ok && data.vm) return { ok: true, vm: data.vm };
    return { ok: false, error: data.error ?? "Failed to create VM" };
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

export async function startVm(vmId: string): Promise<{ ok: boolean; error?: string }> {
  try {
    const data = await request<{ ok: boolean; error?: string }>(
      "/start/" + encodeURIComponent(vmId),
      { method: "POST" }
    );
    if (data.ok) return { ok: true };
    return { ok: false, error: data.error ?? "Failed to start VM" };
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

export async function stopVm(vmId: string, force?: boolean): Promise<{ ok: boolean; error?: string }> {
  try {
    const body = force === true ? JSON.stringify({ force: true }) : undefined;
    const data = await request<{ ok: boolean; error?: string }>(
      "/stop/" + encodeURIComponent(vmId),
      { method: "POST", body }
    );
    if (data.ok) return { ok: true };
    return { ok: false, error: data.error ?? "Failed to stop VM" };
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

export async function deleteVm(vmId: string): Promise<{ ok: boolean; error?: string }> {
  try {
    const data = await request<{ ok: boolean; error?: string }>(
      "/delete/" + encodeURIComponent(vmId),
      { method: "POST" }
    );
    if (data.ok) return { ok: true };
    return { ok: false, error: data.error ?? "Failed to delete VM" };
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}

export async function showConsoleVm(vmId: string): Promise<{ ok: boolean; error?: string }> {
  try {
    const data = await request<{ ok: boolean; error?: string }>("/console/" + vmId, {
      method: "POST",
    });
    if (data.ok) return { ok: true };
    return { ok: false, error: (data as { error?: string }).error ?? "Failed to show console" };
  } catch (err) {
    return {
      ok: false,
      error: err instanceof Error ? err.message : String(err),
    };
  }
}
