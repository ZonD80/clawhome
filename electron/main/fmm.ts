import { chmodSync, readFileSync, writeFileSync } from "node:fs";
import { listChatGptModels, type CloudModel } from "./chatgpt.js";

export type { CloudModel };

/**
 * Same cloud-key check as bia-flash: one streamed request that must call the `say` tool.
 * A model that only answers in text is rejected. The normalized config is what gets
 * written to EFI/bia/fmm.json.
 */

const PROVIDERS = ["openrouter", "openai", "anthropic", "xai", "deepseek", "qwen"] as const;
const QWEN_CN = "https://dashscope.aliyuncs.com/compatible-mode/v1";
const DEFAULT_CTX = 131_072;

const SYSTEM =
  "You are bia, an AI that lives on a USB stick and boots a computer straight into yourself. " +
  "Right now your human is writing you onto a new USB stick: your new home. Call the say tool exactly once, " +
  "and do not answer in plain text. hello: one short, warm sentence greeting your human, saying you are bia " +
  "and you are about to prepare your new home. ready: one short sentence for when the stick is written, " +
  "inviting them to plug it in and boot you. Keep each under 20 words; no emoji, no quotes.";

const SAY_DESC = "Say two short lines to your human.";
const SAY_SCHEMA = {
  type: "object",
  properties: {
    hello: { type: "string", description: "greeting before the stick is written" },
    ready: { type: "string", description: "line for when the stick is written" },
  },
  required: ["hello", "ready"],
};

export interface ChatGptAuth {
  client_id: string;
  host_id?: string;
  access_token: string;
  refresh_token: string;
  id_token?: string;
  expires_at: number;
  refreshed_at?: number;
  email?: string;
  scopes?: string[];
}

export interface FmmRequest {
  provider?: string;
  apiKey?: string;
  model?: string;
  baseUrl?: string;
  ctx?: number;
  chatgpt?: ChatGptAuth | null;
  sourcePath?: string;
}

export interface FmmConfig {
  provider: string;
  api_key: string;
  model: string;
  base_url: string;
  enabled: true;
  ctx: number;
  chatgpt?: ChatGptAuth;
}

export interface FmmCheckResult {
  config: string;
  hello: string;
  summary: string;
  sourcePath?: string;
}

export function providerForKey(key: string): string | null {
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
  return null;
}

export function isDeepseekOrQwenKey(key: string): boolean {
  const rest = key.trim().startsWith("sk-") ? key.trim().slice(3) : "";
  return rest.length === 32 && /^[0-9a-fA-F]+$/.test(rest);
}

export function defaultModel(provider: string): string {
  switch (provider) {
    case "anthropic":
    case "claude":
      return "claude-opus-4-6";
    case "openrouter":
      return "deepseek/deepseek-v4.1-flash";
    case "xai":
      return "grok-4.6";
    case "deepseek":
      return "deepseek-chat";
    case "qwen":
      return "qwen-max";
    default:
      return "gpt-5";
  }
}

function apiBase(provider: string): string {
  switch (provider) {
    case "openrouter":
      return "https://openrouter.ai/api/v1";
    case "xai":
      return "https://api.x.ai/v1";
    case "anthropic":
    case "claude":
      return "https://api.anthropic.com";
    case "deepseek":
      return "https://api.deepseek.com/v1";
    case "chatgpt":
      return "https://api.openai.com/v1";
    case "qwen":
      return "https://dashscope-intl.aliyuncs.com/compatible-mode/v1";
    default:
      return "https://api.openai.com/v1";
  }
}

function resolveBase(provider: string, baseUrl: string): string {
  const trimmed = baseUrl.trim().replace(/\/+$/, "");
  return trimmed || apiBase(provider);
}

function clampCtx(ctx: number): number {
  if (!Number.isFinite(ctx) || ctx === 0) return DEFAULT_CTX;
  return Math.max(512, Math.min(2_000_000, Math.floor(ctx)));
}

function validate(input: FmmRequest): void {
  if ((input.provider ?? "").trim() === "chatgpt") {
    const auth = input.chatgpt;
    if (!auth?.refresh_token || !auth.client_id) {
      throw new Error("ChatGPT is not signed in. Press Continue with ChatGPT, or use an API key.");
    }
    if (!(input.model ?? "").trim()) throw new Error("Pick a ChatGPT model");
    return;
  }
  const key = (input.apiKey ?? "").trim();
  if (!key) throw new Error("API key is required");
  let provider = (input.provider ?? "").trim().toLowerCase();
  if (provider === "claude") provider = "anthropic";
  const detected = providerForKey(key);
  if (!provider) {
    if (!detected && !isDeepseekOrQwenKey(key)) {
      throw new Error(`Cannot tell the provider from this key. Set provider (${PROVIDERS.join(", ")}).`);
    }
    return;
  }
  if (!(PROVIDERS as readonly string[]).includes(provider)) {
    throw new Error(`Provider must be one of ${PROVIDERS.join(", ")}`);
  }
  if (detected && detected !== provider && !(input.baseUrl ?? "").trim()) {
    throw new Error(`This looks like a ${detected} key, but provider is ${provider}`);
  }
}

async function listModels(provider: string, key: string, baseUrl: string): Promise<CloudModel[]> {
  const base = resolveBase(provider, baseUrl);
  const anthropic = provider === "anthropic" || provider === "claude";
  const url = anthropic ? `${base}/v1/models?limit=1000` : `${base}/models`;
  const headers: Record<string, string> = { "User-Agent": "ClawHome" };
  if (anthropic) {
    headers["x-api-key"] = key.trim();
    headers["anthropic-version"] = "2023-06-01";
  } else {
    headers.Authorization = `Bearer ${key.trim()}`;
  }
  let resp: Response;
  try {
    resp = await fetch(url, { headers, signal: AbortSignal.timeout(20_000) });
  } catch (err) {
    throw new Error(`List ${provider} models: ${err instanceof Error ? err.message : String(err)}`);
  }
  if (resp.status === 401 || resp.status === 403) {
    throw new Error(`${provider} rejected this key`);
  }
  if (!resp.ok) {
    throw new Error(`List ${provider} models: HTTP ${resp.status}`);
  }
  const body = (await resp.json()) as {
    data?: { id?: string; name?: string; display_name?: string; context_length?: number }[];
  };
  if (!Array.isArray(body.data)) throw new Error(`Could not parse the ${provider} model list`);
  const models: CloudModel[] = body.data
    .filter((item) => item && typeof item.id === "string" && item.id)
    .map((item) => ({
      id: item.id as string,
      name: item.display_name || item.name || (item.id as string),
      ctx: typeof item.context_length === "number" ? Math.min(item.context_length, 0xffff_ffff) : 0,
    }));
  models.sort((a, b) => a.id.localeCompare(b.id));
  return models;
}

async function probeKey(key: string): Promise<{ provider: string; baseUrl: string; models: CloudModel[] }> {
  for (const [provider, base] of [
    ["deepseek", ""],
    ["qwen", ""],
    ["qwen", QWEN_CN],
  ] as const) {
    try {
      const models = await listModels(provider, key, base);
      return { provider, baseUrl: base, models };
    } catch {
      /* try the next endpoint */
    }
  }
  throw new Error("Neither DeepSeek nor Qwen (DashScope) accepts this key. Set the provider.");
}

/** The account's model list, the same `/models` query bia-flash runs after a key or ChatGPT sign-in. */
export async function listCloudModels(
  input: FmmRequest
): Promise<{ provider: string; baseUrl: string; models: CloudModel[] }> {
  let provider = (input.provider ?? "").trim().toLowerCase();
  if (provider === "claude") provider = "anthropic";
  const key = (input.apiKey ?? "").trim();
  const baseUrl = (input.baseUrl ?? "").trim();
  if (provider === "chatgpt") {
    const token = input.chatgpt?.access_token || key;
    if (!token) throw new Error("ChatGPT is not signed in");
    return { provider, baseUrl: "", models: await listChatGptModels(token) };
  }
  if (!key) throw new Error("API key is required");
  if (!provider) {
    const detected = providerForKey(key);
    if (detected) provider = detected;
    else if (isDeepseekOrQwenKey(key)) return probeKey(key);
    else throw new Error(`Cannot tell the provider from this key. Set provider (${PROVIDERS.join(", ")}).`);
  }
  return { provider, baseUrl, models: await listModels(provider, key, baseUrl) };
}

function toConfig(input: FmmRequest): FmmConfig {
  let provider = (input.provider ?? "").trim().toLowerCase();
  if (provider === "claude") provider = "anthropic";
  const apiKey = (input.apiKey ?? "").trim();
  if (!provider) provider = providerForKey(apiKey) ?? "";
  let model = (input.model ?? "").trim();
  if (!model && provider) model = defaultModel(provider);
  const config: FmmConfig = {
    provider,
    api_key: apiKey,
    model,
    base_url: (input.baseUrl ?? "").trim(),
    enabled: true,
    ctx: clampCtx(Number(input.ctx)),
  };
  if (input.chatgpt) config.chatgpt = input.chatgpt;
  return config;
}

async function resolveInput(input: FmmRequest): Promise<{ config: FmmConfig; refreshed: boolean }> {
  validate(input);
  const next: FmmRequest = { ...input, chatgpt: input.chatgpt ? { ...input.chatgpt } : input.chatgpt };
  if (!(next.provider ?? "").trim() && !providerForKey(next.apiKey ?? "")) {
    const probed = await probeKey(next.apiKey ?? "");
    next.provider = probed.provider;
    if (!(next.baseUrl ?? "").trim()) next.baseUrl = probed.baseUrl;
  }
  let refreshed = false;
  if ((next.provider ?? "").trim() === "chatgpt" && next.chatgpt) {
    refreshed = await ensureFresh(next.chatgpt);
    next.apiKey = next.chatgpt.access_token;
  }
  return { config: toConfig(next), refreshed };
}

async function ensureFresh(auth: ChatGptAuth): Promise<boolean> {
  const now = Math.floor(Date.now() / 1000);
  if (auth.expires_at > now + 300) return false;
  const body = new URLSearchParams({
    grant_type: "refresh_token",
    client_id: auth.client_id,
    refresh_token: auth.refresh_token,
    resource: "https://api.openai.com/v1",
  });
  let resp: Response;
  try {
    resp = await fetch("https://auth.openai.com/api/accounts/oauth/token", {
      method: "POST",
      headers: { "Content-Type": "application/x-www-form-urlencoded", "User-Agent": "ClawHome" },
      body,
      signal: AbortSignal.timeout(30_000),
    });
  } catch (err) {
    throw new Error(
      `ChatGPT sign-in expired (${err instanceof Error ? err.message : String(err)}). Sign in again.`
    );
  }
  const payload = (await resp.json().catch(() => ({}))) as {
    error?: string;
    error_description?: string;
    access_token?: string;
    refresh_token?: string;
    id_token?: string;
    expires_in?: number;
    scope?: string;
  };
  if (!resp.ok) {
    const code = payload.error ?? "error";
    const msg = payload.error_description ?? "";
    throw new Error(`ChatGPT sign-in expired (${code} ${msg}). Sign in again.`);
  }
  if (!payload.access_token) throw new Error("ChatGPT sign-in expired. Sign in again.");
  auth.access_token = payload.access_token;
  if (payload.refresh_token) auth.refresh_token = payload.refresh_token;
  if (payload.id_token) auth.id_token = payload.id_token;
  auth.expires_at = now + (payload.expires_in ?? 3600);
  auth.refreshed_at = now;
  if (payload.scope) auth.scopes = payload.scope.split(/\s+/).filter(Boolean);
  return true;
}

function httpError(provider: string, status: number, body: string): Error {
  let msg = body.slice(0, 300);
  try {
    const parsed = JSON.parse(body) as { error?: { message?: string }; message?: string };
    msg = parsed.error?.message || parsed.message || msg;
  } catch {
    /* body is not JSON */
  }
  if (status === 401 || status === 403) return new Error(`${provider} rejected the key (HTTP ${status}): ${msg}`);
  if (status === 404) return new Error(`${provider}: model or endpoint not found (HTTP 404): ${msg}`);
  if (status === 402) return new Error(`${provider}: no credit on this account (HTTP 402): ${msg}`);
  if (status === 429) return new Error(`${provider}: rate limited or out of quota (HTTP 429): ${msg}`);
  return new Error(`${provider}: HTTP ${status}: ${msg}`);
}

function planError(code: string, msg: string): string {
  switch (code) {
    case "subscription_sharing_user_not_eligible":
      return "this ChatGPT plan can't be used by apps like bia";
    case "subscription_sharing_usage_limit_exceeded":
      return "this ChatGPT plan's usage limit is reached for now (see ChatGPT settings → Usage)";
    case "subscription_sharing_usage_unavailable":
    case "subscription_sharing_user_unavailable":
      return "ChatGPT couldn't check your plan right now; try again in a minute";
    case "subscription_sharing_invalid_user":
      return "ChatGPT did not accept this sign-in; sign in again";
    case "":
      return msg;
    default:
      return `${code}: ${msg}`;
  }
}

async function readBody(resp: Response): Promise<string> {
  return await resp.text();
}

async function chatCompletions(
  config: FmmConfig
): Promise<{ args: Record<string, unknown> | null; text: string }> {
  const base = resolveBase(config.provider, config.base_url);
  const headers: Record<string, string> = {
    Authorization: `Bearer ${config.api_key}`,
    "Content-Type": "application/json",
    "User-Agent": "ClawHome",
  };
  if (config.provider === "openrouter") {
    headers["HTTP-Referer"] = "https://bia.local";
    headers["X-Title"] = "bia";
  }
  const resp = await fetch(`${base}/chat/completions`, {
    method: "POST",
    headers,
    body: JSON.stringify({
      model: config.model,
      messages: [
        { role: "system", content: SYSTEM },
        { role: "user", content: "Hi bia!" },
      ],
      tools: [
        {
          type: "function",
          function: { name: "say", description: SAY_DESC, parameters: SAY_SCHEMA },
        },
      ],
      stream: true,
    }),
    signal: AbortSignal.timeout(120_000),
  });
  if (resp.status >= 400) throw httpError(config.provider, resp.status, await readBody(resp));
  const raw = await readBody(resp);
  let called = false;
  let args = "";
  let text = "";
  let sawSse = false;
  for (const line of raw.split(/\r?\n/)) {
    const data = line.startsWith("data:") ? line.slice(5).trim() : "";
    if (!data) continue;
    sawSse = true;
    if (data === "[DONE]") break;
    let value: {
      error?: { message?: string };
      choices?: { delta?: { tool_calls?: { function?: { name?: string; arguments?: string } }[]; content?: string } }[];
    };
    try {
      value = JSON.parse(data);
    } catch {
      continue;
    }
    if (value.error) throw new Error(`${config.provider}: ${value.error.message || "stream error"}`);
    const delta = value.choices?.[0]?.delta;
    for (const call of delta?.tool_calls ?? []) {
      if (call.function?.name?.includes("say")) called = true;
      if (call.function?.arguments) args += call.function.arguments;
    }
    if (delta?.content) text += delta.content;
  }
  if (!sawSse && raw.trim().startsWith("{")) {
    const value = JSON.parse(raw) as {
      choices?: { message?: { content?: string; tool_calls?: { function?: { name?: string; arguments?: string } }[] } }[];
    };
    const message = value.choices?.[0]?.message;
    text = message?.content ?? "";
    for (const call of message?.tool_calls ?? []) {
      if (call.function?.name?.includes("say")) called = true;
      if (call.function?.arguments) args += call.function.arguments;
    }
  }
  if (!called) return { args: null, text };
  try {
    return { args: JSON.parse(args) as Record<string, unknown>, text };
  } catch {
    return { args: {}, text };
  }
}

async function anthropicMessages(
  config: FmmConfig
): Promise<{ args: Record<string, unknown> | null; text: string }> {
  const base = resolveBase(config.provider, config.base_url);
  const resp = await fetch(`${base}/v1/messages`, {
    method: "POST",
    headers: {
      "x-api-key": config.api_key,
      "anthropic-version": "2023-06-01",
      "Content-Type": "application/json",
      "User-Agent": "ClawHome",
    },
    body: JSON.stringify({
      model: config.model,
      max_tokens: 1024,
      system: SYSTEM,
      messages: [{ role: "user", content: "Hi bia!" }],
      tools: [{ name: "say", description: SAY_DESC, input_schema: SAY_SCHEMA }],
    }),
    signal: AbortSignal.timeout(120_000),
  });
  const raw = await readBody(resp);
  if (resp.status >= 400) throw httpError(config.provider, resp.status, raw);
  const value = JSON.parse(raw) as {
    content?: { type?: string; name?: string; input?: Record<string, unknown>; text?: string }[];
  };
  const blocks = value.content ?? [];
  const tool = blocks.find((block) => block.type === "tool_use" && block.name === "say");
  const text = blocks
    .map((block) => block.text)
    .filter((part): part is string => !!part)
    .join(" ");
  return { args: tool?.input ?? null, text };
}

async function chatgptResponses(
  config: FmmConfig
): Promise<{ args: Record<string, unknown> | null; text: string }> {
  const base = resolveBase(config.provider, config.base_url);
  const say = { type: "function", name: "say", description: SAY_DESC, parameters: SAY_SCHEMA };
  const shapes = [
    [{ type: "namespace", name: "bia", description: "bia's tools", tools: [say] }],
    [say],
  ];
  let last = "chatgpt: request refused";
  for (const tools of shapes) {
    const resp = await fetch(`${base}/responses`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${config.api_key}`,
        "Content-Type": "application/json",
        "User-Agent": "ClawHome",
      },
      body: JSON.stringify({
        model: config.model,
        instructions: SYSTEM,
        input: [{ role: "user", content: [{ type: "input_text", text: "Hi bia!" }] }],
        tools,
        store: false,
        stream: true,
      }),
      signal: AbortSignal.timeout(120_000),
    });
    const raw = await readBody(resp);
    if (resp.status >= 400) {
      let code = "";
      let msg = raw.slice(0, 300);
      try {
        const parsed = JSON.parse(raw) as { error?: { code?: string; message?: string } };
        code = parsed.error?.code ?? "";
        msg = parsed.error?.message ?? msg;
      } catch {
        /* plain text */
      }
      const err = code
        ? `chatgpt: ${planError(code, msg)} (HTTP ${resp.status})`
        : resp.status === 401
          ? "chatgpt: the sign-in was rejected (HTTP 401); sign in again"
          : httpError("chatgpt", resp.status, raw).message;
      if (resp.status === 400) {
        last = err;
        continue;
      }
      throw new Error(err);
    }
    let args: Record<string, unknown> | null = null;
    let text = "";
    let done = false;
    for (const line of raw.split(/\r?\n/)) {
      const data = line.startsWith("data:") ? line.slice(5).trim() : "";
      if (!data) continue;
      let value: {
        type?: string;
        delta?: string;
        item?: { type?: string; name?: string; arguments?: string };
        response?: { error?: { code?: string; message?: string } };
        error?: { code?: string; message?: string };
      };
      try {
        value = JSON.parse(data);
      } catch {
        continue;
      }
      const kind = value.type ?? "";
      if (kind === "response.output_text.delta") text += value.delta ?? "";
      if (kind === "response.output_item.done") {
        const item = value.item;
        if (item?.type === "function_call" && (item.name ?? "").endsWith("say")) {
          try {
            args = JSON.parse(item.arguments || "{}") as Record<string, unknown>;
          } catch {
            args = {};
          }
        }
      }
      if (kind === "response.completed") {
        done = true;
        break;
      }
      if (kind === "response.failed" || kind === "response.incomplete" || kind === "error") {
        const err = value.response?.error ?? value.error;
        throw new Error(`chatgpt: ${planError(err?.code ?? "", err?.message ?? "request failed")}`);
      }
    }
    if (!done && !args) throw new Error("chatgpt: the reply stream ended early");
    return { args, text };
  }
  throw new Error(last);
}

function lineOf(args: Record<string, unknown>, key: string, fallback: string): string {
  const raw = typeof args[key] === "string" ? args[key] : "";
  const trimmed = raw.trim().replace(/^"|"$/g, "").slice(0, 200);
  return trimmed || fallback;
}

export async function checkFmm(input: FmmRequest): Promise<FmmCheckResult> {
  const { config, refreshed } = await resolveInput(input);
  if (refreshed && config.chatgpt && input.sourcePath) {
    const pretty = JSON.stringify(config, null, 2) + "\n";
    writeFileSync(input.sourcePath, pretty, { mode: 0o600 });
    try {
      chmodSync(input.sourcePath, 0o600);
    } catch {
      /* the refreshed tokens are already in the file */
    }
  }
  const started = Date.now();
  let result: { args: Record<string, unknown> | null; text: string };
  try {
    if (config.provider === "anthropic") result = await anthropicMessages(config);
    else if (config.provider === "chatgpt") result = await chatgptResponses(config);
    else result = await chatCompletions(config);
  } catch (err) {
    if (err instanceof Error && err.name === "TimeoutError") {
      throw new Error(`${config.provider} did not answer in time`);
    }
    throw err;
  }
  if (!result.args) {
    const said = result.text.trim().slice(0, 160);
    throw new Error(
      `${config.provider} ${config.model} answered but did not call the tool; bia needs a model with tool calling` +
        (said ? ` (it said: ${said})` : "")
    );
  }
  const secs = ((Date.now() - started) / 1000).toFixed(1);
  return {
    config: JSON.stringify(config, null, 2) + "\n",
    hello: lineOf(result.args, "hello", "Hi! I'm bia. Let's prepare my new home."),
    summary: `${config.provider} ${config.model}, ${secs}s`,
    sourcePath: config.chatgpt && input.sourcePath ? input.sourcePath : undefined,
  };
}

export function readFmmFile(path: string): FmmRequest {
  let parsed: {
    provider?: string;
    api_key?: string;
    model?: string;
    base_url?: string;
    ctx?: number;
    chatgpt?: ChatGptAuth;
  };
  try {
    parsed = JSON.parse(readFileSync(path, "utf8"));
  } catch {
    throw new Error("Could not read that fmm.json");
  }
  if (!parsed || typeof parsed !== "object") throw new Error("fmm.json is not a key file");
  return {
    provider: typeof parsed.provider === "string" ? parsed.provider : "",
    apiKey: typeof parsed.api_key === "string" ? parsed.api_key : "",
    model: typeof parsed.model === "string" ? parsed.model : "",
    baseUrl: typeof parsed.base_url === "string" ? parsed.base_url : "",
    ctx: typeof parsed.ctx === "number" ? parsed.ctx : DEFAULT_CTX,
    chatgpt: parsed.chatgpt && typeof parsed.chatgpt === "object" ? parsed.chatgpt : null,
    sourcePath: path,
  };
}
