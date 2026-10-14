import { createHash, randomBytes } from "node:crypto";
import { chmodSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { createServer, type Server } from "node:net";
import { homedir } from "node:os";
import { join } from "node:path";
import type { ChatGptAuth } from "./fmm.js";

/**
 * "Continue with ChatGPT", the same Sign in with ChatGPT flow as bia-flash.
 * Registration (host id, client id, last ID token) is stored in bia-flash's
 * chatgpt.json so a later sign-in reuses the issued client. Access tokens are
 * not kept there; they go onto the home's disk.
 */

const AUTHORIZE_URL = "https://auth.openai.com/api/accounts/authorize";
const TOKEN_URL = "https://auth.openai.com/api/accounts/oauth/token";
const RESOURCE = "https://api.openai.com/v1";
const SCOPES = "openid profile email offline_access resource.invoke chatgpt.tokens.use.direct";
const PLAN_SCOPE = "chatgpt.tokens.use.direct";
const ISSUER = "https://auth.openai.com";
const CALLBACK_PATH = "/auth/callback";

export interface CloudModel {
  id: string;
  name: string;
  ctx: number;
}

interface LocalAccount {
  email: string;
  client_id: string;
  id_token: string;
}

interface LocalRegistration {
  host_id: string;
  accounts: LocalAccount[];
  pending_client_id: string;
}

class OAuthError extends Error {
  code: string;
  constructor(code: string, message: string) {
    super(message);
    this.code = code;
  }
}

function now(): number {
  return Math.floor(Date.now() / 1000);
}

function randomB64(n: number): string {
  return randomBytes(n).toString("base64url");
}

function uuidUrn(): string {
  const b = randomBytes(16);
  b[6] = ((b[6] ?? 0) & 0x0f) | 0x40;
  b[8] = ((b[8] ?? 0) & 0x3f) | 0x80;
  const h = [...b].map((x) => x.toString(16).padStart(2, "0")).join("");
  return `urn:uuid:${h.slice(0, 8)}-${h.slice(8, 12)}-${h.slice(12, 16)}-${h.slice(16, 20)}-${h.slice(20)}`;
}

function enc(s: string): string {
  return [...s]
    .map((ch) => (/^[A-Za-z0-9\-_.~]$/.test(ch) ? ch : `%${ch.charCodeAt(0).toString(16).toUpperCase().padStart(2, "0")}`))
    .join("");
}

function localPath(): string {
  if (process.platform === "win32") {
    const base = process.env.APPDATA;
    if (!base) throw new Error("APPDATA is not set");
    return join(base, "bia-flash", "chatgpt.json");
  }
  if (process.platform === "darwin") {
    return join(homedir(), "Library/Application Support/bia-flash/chatgpt.json");
  }
  const base = process.env.XDG_CONFIG_HOME || join(homedir(), ".config");
  return join(base, "bia-flash", "chatgpt.json");
}

function loadLocal(): LocalRegistration {
  let local: Partial<LocalRegistration> = {};
  try {
    local = JSON.parse(readFileSync(localPath(), "utf8")) as Partial<LocalRegistration>;
  } catch {
    local = {};
  }
  const loaded: LocalRegistration = {
    host_id: typeof local.host_id === "string" ? local.host_id : "",
    accounts: Array.isArray(local.accounts) ? local.accounts : [],
    pending_client_id: typeof local.pending_client_id === "string" ? local.pending_client_id : "",
  };
  if (!loaded.host_id) {
    loaded.host_id = uuidUrn();
    saveLocal(loaded);
  }
  return loaded;
}

function saveLocal(local: LocalRegistration): void {
  const path = localPath();
  mkdirSync(join(path, ".."), { recursive: true });
  const tmp = `${path}.tmp`;
  writeFileSync(tmp, JSON.stringify(local, null, 2) + "\n", { mode: 0o600 });
  try {
    chmodSync(tmp, 0o600);
  } catch {
    /* owner-only mode is already requested */
  }
  renameSync(tmp, path);
}

function jwtClaims(jwt: string): Record<string, unknown> | null {
  const payload = jwt.split(".")[1];
  if (!payload) return null;
  try {
    return JSON.parse(Buffer.from(payload, "base64url").toString("utf8")) as Record<string, unknown>;
  } catch {
    return null;
  }
}

async function tokenRequest(form: Record<string, string>): Promise<Record<string, unknown>> {
  const body = Object.entries(form)
    .map(([k, v]) => `${enc(k)}=${enc(v)}`)
    .join("&");
  let resp: Response;
  try {
    resp = await fetch(TOKEN_URL, {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "ClawHome" },
      body,
      signal: AbortSignal.timeout(30_000),
    });
  } catch (err) {
    throw new Error(`Could not reach auth.openai.com (${err instanceof Error ? err.message : String(err)})`);
  }
  const payload = (await resp.json().catch(() => ({}))) as Record<string, unknown>;
  if (resp.status >= 400) {
    const code = typeof payload.error === "string" ? payload.error : "error";
    const msg = typeof payload.error_description === "string" ? payload.error_description : "";
    throw new OAuthError(code, `ChatGPT sign-in: ${code} ${msg} (HTTP ${resp.status})`);
  }
  return payload;
}

function applyTokens(auth: ChatGptAuth, payload: Record<string, unknown>): void {
  if (typeof payload.access_token !== "string" || !payload.access_token) {
    throw new Error("ChatGPT sign-in: no access token in the reply");
  }
  auth.access_token = payload.access_token;
  if (typeof payload.refresh_token === "string") auth.refresh_token = payload.refresh_token;
  if (typeof payload.id_token === "string") auth.id_token = payload.id_token;
  const t = now();
  auth.expires_at = t + (typeof payload.expires_in === "number" ? payload.expires_in : 3600);
  auth.refreshed_at = t;
  if (typeof payload.scope === "string") {
    auth.scopes = payload.scope.split(/\s+/).filter(Boolean);
  }
}

function listen(port: number): Promise<Server> {
  return new Promise((resolve, reject) => {
    const server = createServer();
    const onError = (err: Error) => {
      server.close();
      reject(err);
    };
    server.once("error", onError);
    server.listen(port, "127.0.0.1", () => {
      server.removeListener("error", onError);
      resolve(server);
    });
  });
}

function readCallback(server: Server): Promise<URLSearchParams> {
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      server.close();
      reject(new Error("ChatGPT sign-in timed out"));
    }, 300_000);
    server.on("connection", (socket) => {
      let buf = "";
      const onData = (chunk: Buffer) => {
        buf += chunk.toString("utf8");
        if (!buf.includes("\n")) return;
        socket.off("data", onData);
        const line = buf.split("\r\n")[0] ?? "";
        const target = line.split(" ")[1] ?? "";
        const qIndex = target.indexOf("?");
        const pathname = qIndex >= 0 ? target.slice(0, qIndex) : target;
        if (pathname !== CALLBACK_PATH) {
          socket.end("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
          return;
        }
        const query = qIndex >= 0 ? target.slice(qIndex + 1) : "";
        const ok = new URLSearchParams(query).has("code");
        const page = ok
          ? "<h2>ClawHome is signed in to ChatGPT.</h2><p>You can close this tab and go back to ClawHome.</p>"
          : "<h2>Sign-in was not completed.</h2><p>Go back to ClawHome to try again.</p>";
        const html = `<!doctype html><meta charset=utf-8><title>ClawHome</title><body style="font-family:sans-serif;margin:3em">${page}</body>`;
        socket.end(
          `HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: ${Buffer.byteLength(html)}\r\nConnection: close\r\n\r\n${html}`
        );
        clearTimeout(timer);
        server.close();
        resolve(new URLSearchParams(query));
      };
      socket.on("data", onData);
      socket.on("error", () => {
        /* a dropped browser connection is not the sign-in result */
      });
    });
    server.on("error", (err) => {
      clearTimeout(timer);
      reject(err);
    });
  });
}

async function signInOnce(
  local: LocalRegistration,
  known: LocalAccount | null,
  openBrowser: (url: string) => Promise<void> | void,
  onStatus: (status: string) => void
): Promise<ChatGptAuth> {
  let server: Server;
  try {
    server = await listen(1455);
  } catch {
    server = await listen(0);
  }
  const addr = server.address();
  if (!addr || typeof addr === "string") {
    server.close();
    throw new Error("Could not open a local port for the sign-in callback");
  }
  const redirect = `http://127.0.0.1:${addr.port}${CALLBACK_PATH}`;
  const verifier = randomB64(48);
  const challenge = createHash("sha256").update(verifier).digest("base64url");
  const state = randomB64(24);
  const nonce = randomB64(24);
  const params: [string, string][] = [
    ["response_type", "code"],
    ["redirect_uri", redirect],
    ["scope", SCOPES],
    ["resource", RESOURCE],
    ["state", state],
    ["nonce", nonce],
    ["code_challenge_method", "S256"],
    ["code_challenge", challenge],
    ["ext_agent_host_id", local.host_id],
  ];
  if (known) {
    params.push(["client_id", known.client_id]);
    if (known.id_token) params.push(["id_token_hint", known.id_token]);
    if (known.email) params.push(["login_hint", known.email]);
  } else {
    params.push(["client_id", "dynamic_agent_client"]);
    params.push(["agent_name_hint", "bia"]);
  }
  const url = `${AUTHORIZE_URL}?${params.map(([k, v]) => `${k}=${enc(v)}`).join("&")}`;
  const waiting = readCallback(server);
  onStatus("Opening ChatGPT sign-in in your browser…");
  try {
    await openBrowser(url);
  } catch {
    onStatus(`Open this address in your browser: ${url}`);
  }
  const query = await waiting;
  const get = (key: string) => query.get(key) ?? "";
  if (get("state") !== state) throw new Error("ChatGPT sign-in: state mismatch. Try again.");
  if (get("error")) {
    if (get("error") === "access_denied") throw new Error("ChatGPT sign-in was declined");
    throw new Error(`ChatGPT sign-in: ${get("error")}`);
  }
  const code = get("code");
  if (!code) throw new Error("ChatGPT sign-in: no code returned");
  const issued = get("client_id");
  const issuedClient = issued && issued !== "dynamic_agent_client" ? issued : "";
  if (known && issuedClient && issuedClient !== known.client_id) {
    throw new Error("ChatGPT sign-in returned a different client. Try again.");
  }
  const clientId = issuedClient || known?.client_id;
  if (!clientId) throw new Error("ChatGPT sign-in: no client id returned");
  if (!known) {
    local.pending_client_id = clientId;
    saveLocal(local);
  }
  onStatus("Finishing sign-in…");
  const payload = await tokenRequest({
    grant_type: "authorization_code",
    client_id: clientId,
    code,
    code_verifier: verifier,
    redirect_uri: redirect,
    resource: RESOURCE,
  });
  const auth: ChatGptAuth = {
    client_id: clientId,
    host_id: local.host_id,
    access_token: "",
    refresh_token: "",
    expires_at: 0,
  };
  applyTokens(auth, payload);
  if (!auth.scopes?.length && get("scope")) auth.scopes = get("scope").split(/\s+/).filter(Boolean);
  const claims = jwtClaims(auth.id_token ?? "");
  if (!claims) throw new Error("ChatGPT sign-in: no valid ID token");
  const aud = claims.aud;
  const audOk = aud === clientId || (Array.isArray(aud) && aud.includes(clientId));
  const iss = typeof claims.iss === "string" ? claims.iss.replace(/\/$/, "") : "";
  const exp = typeof claims.exp === "number" ? claims.exp : 0;
  if (iss !== ISSUER || !audOk || claims.nonce !== nonce || exp < now()) {
    throw new Error("ChatGPT sign-in: the ID token did not check out. Try again.");
  }
  auth.email = typeof claims.email === "string" ? claims.email : "";
  local.pending_client_id = "";
  local.accounts = local.accounts.filter((account) => account.email !== auth.email);
  local.accounts.push({ email: auth.email, client_id: clientId, id_token: auth.id_token ?? "" });
  saveLocal(local);
  if (!auth.scopes?.includes(PLAN_SCOPE)) {
    throw new Error(
      `Signed in as ${auth.email || "this account"}, but ChatGPT plan use was not allowed. Sign in again and allow it, or use an API key.`
    );
  }
  return auth;
}

export async function signInChatGpt(
  openBrowser: (url: string) => Promise<void> | void,
  onStatus: (status: string) => void = () => {}
): Promise<ChatGptAuth> {
  const local = loadLocal();
  let known: LocalAccount | null =
    (local.pending_client_id
      ? { email: "", client_id: local.pending_client_id, id_token: "" }
      : null);
  for (let attempt = 0; attempt < 2; attempt++) {
    try {
      return await signInOnce(local, known, openBrowser, onStatus);
    } catch (err) {
      if (attempt === 0 && err instanceof OAuthError && err.code === "invalid_grant" && local.pending_client_id) {
        onStatus("ChatGPT wants one more confirmation. Continue in your browser…");
        known = { email: "", client_id: local.pending_client_id, id_token: "" };
        continue;
      }
      throw err;
    }
  }
  throw new Error("ChatGPT sign-in failed");
}

/** Models this ChatGPT account may use (`visibility` missing or `list`). */
export async function listChatGptModels(accessToken: string): Promise<CloudModel[]> {
  let resp: Response;
  try {
    resp = await fetch(`${RESOURCE}/models`, {
      headers: { Authorization: `Bearer ${accessToken}`, "User-Agent": "ClawHome" },
      signal: AbortSignal.timeout(20_000),
    });
  } catch (err) {
    throw new Error(`ChatGPT model list: ${err instanceof Error ? err.message : String(err)}`);
  }
  const text = await resp.text();
  if (resp.status >= 400) {
    throw new Error(`ChatGPT model list: HTTP ${resp.status}: ${text.slice(0, 300)}`);
  }
  const payload = JSON.parse(text) as { data?: unknown; models?: unknown };
  const items = Array.isArray(payload.data)
    ? payload.data
    : Array.isArray(payload.models)
      ? payload.models
      : Array.isArray(payload)
        ? payload
        : [];
  const models: CloudModel[] = [];
  for (const item of items) {
    if (!item || typeof item !== "object") continue;
    const row = item as Record<string, unknown>;
    if (typeof row.visibility === "string" && row.visibility !== "list") continue;
    const id = typeof row.slug === "string" ? row.slug : typeof row.id === "string" ? row.id : "";
    if (!id) continue;
    const name = typeof row.display_name === "string" ? row.display_name : id;
    const ctxRaw = typeof row.context_window === "number" ? row.context_window : 0;
    models.push({ id, name, ctx: Math.min(ctxRaw, 0xffff_ffff) });
  }
  models.sort((a, b) => a.id.localeCompare(b.id));
  return models;
}
