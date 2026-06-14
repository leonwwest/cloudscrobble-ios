import { md5 } from "js-md5";

interface Env {
  SOUNDCLOUD_CLIENT_ID?: string;
  SOUNDCLOUD_CLIENT_SECRET?: string;
  SOUNDCLOUD_TOKEN_URL?: string;
  LASTFM_API_KEY?: string;
  LASTFM_API_SECRET?: string;
  LASTFM_API_URL?: string;
  ALLOWED_ORIGIN?: string;
  RATE_LIMIT_PER_MINUTE?: string;
  RATE_LIMIT_WINDOW_SECONDS?: string;
}

interface ExchangeRequest {
  code?: string;
  codeVerifier?: string;
  redirectUri?: string;
}

interface RefreshRequest {
  refreshToken?: string;
}

interface LastFMAuthRequest {
  username?: string;
  password?: string;
}

interface LastFMNowPlayingRequest {
  sessionKey?: string;
  artist?: string;
  track?: string;
  durationSeconds?: number;
}

interface LastFMScrobbleRequest {
  sessionKey?: string;
  scrobbles?: LastFMScrobblePayload[];
}

interface LastFMTasteRequest {
  username?: string;
  limit?: number;
}

interface LastFMScrobblePayload {
  artist?: string;
  track?: string;
  timestamp?: number;
}

interface RateLimitBucket {
  count: number;
  resetAt: number;
}

interface WorkerExecutionContext {
  waitUntil(promise: Promise<unknown>): void;
}

type RequestWithCF = Request & {
  cf?: {
    colo?: string;
  };
};

const VERSION = "2026.06.13.1";
const MAX_JSON_BODY_BYTES = 64 * 1024;
const MAX_UPSTREAM_JSON_BYTES = 2 * 1024 * 1024;
const rateLimitBuckets = new Map<string, RateLimitBucket>();

export default {
  async fetch(request: Request, env: Env, ctx: WorkerExecutionContext): Promise<Response> {
    const requestID = crypto.randomUUID();
    const startedAt = Date.now();
    const url = new URL(request.url);
    let response: Response;

    try {
      if (request.method === "OPTIONS") {
        response = new Response(null, { status: 204 });
      } else {
        const rateLimit = await checkRateLimit(request, env, url);
        if (!rateLimit.ok) {
          response = json(
            {
              error: "rate_limited",
              message: "Too many requests. Try again shortly."
            },
            429,
            {
              "Retry-After": String(rateLimit.retryAfterSeconds)
            }
          );
        } else {
          response = await routeRequest(request, env, url);
        }
      }
    } catch (error) {
      response = json({ error: "internal_error", message: "Request failed." }, 500);
      ctx.waitUntil(logWorkerError(requestID, url, error));
    }

    const finalResponse = withRequestID(withSecurityHeaders(withCORS(env, response)), requestID);
    ctx.waitUntil(logRequest(request, url, finalResponse, startedAt, requestID));
    return finalResponse;
  }
};

async function routeRequest(request: Request, env: Env, url: URL): Promise<Response> {
    if (url.pathname === "/healthz" && request.method === "GET") {
      return json({
        status: "ok",
        version: VERSION,
        services: {
          soundcloud: Boolean(env.SOUNDCLOUD_CLIENT_ID && env.SOUNDCLOUD_CLIENT_SECRET),
          lastfm: Boolean(env.LASTFM_API_KEY && env.LASTFM_API_SECRET)
        },
        rateLimit: loadRateLimitConfig(env)
      });
    }

    if (url.pathname === "/version" && request.method === "GET") {
      return json({ version: VERSION });
    }

    if (url.pathname === "/oauth/soundcloud/exchange") {
      return handleExchange(request, env);
    }

    if (url.pathname === "/oauth/soundcloud/refresh") {
      return handleRefresh(request, env);
    }

    if (url.pathname === "/oauth/soundcloud/client-credentials") {
      return handleClientCredentials(request, env);
    }

    if (url.pathname === "/oauth/lastfm/mobile-session") {
      return handleLastFMMobileSession(request, env);
    }

    if (url.pathname === "/lastfm/now-playing") {
      return handleLastFMNowPlaying(request, env);
    }

    if (url.pathname === "/lastfm/scrobble") {
      return handleLastFMScrobble(request, env);
    }

    if (url.pathname === "/lastfm/taste") {
      return handleLastFMTaste(request, env);
    }

    return json({ error: "not_found" }, 404);
}

async function handleExchange(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const cfg = loadConfig(env);
  if (!cfg.ok) {
    return json({ error: cfg.error }, 500);
  }

  const body = await parseJSON<ExchangeRequest>(request);
  if (!body.ok) {
    return jsonParseError(body.error);
  }

  const { code, codeVerifier, redirectUri } = body.value;
  if (!code || !codeVerifier || !redirectUri) {
    return json({ error: "missing_required_fields" }, 400);
  }

  const payload = new URLSearchParams({
    grant_type: "authorization_code",
    client_id: cfg.value.clientID,
    client_secret: cfg.value.clientSecret,
    code,
    code_verifier: codeVerifier,
    redirect_uri: redirectUri
  });

  return proxyTokenRequest(cfg.value, payload);
}

async function handleRefresh(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const cfg = loadConfig(env);
  if (!cfg.ok) {
    return json({ error: cfg.error }, 500);
  }

  const body = await parseJSON<RefreshRequest>(request);
  if (!body.ok) {
    return jsonParseError(body.error);
  }

  const { refreshToken } = body.value;
  if (!refreshToken) {
    return json({ error: "missing_refresh_token" }, 400);
  }

  const payload = new URLSearchParams({
    grant_type: "refresh_token",
    client_id: cfg.value.clientID,
    client_secret: cfg.value.clientSecret,
    refresh_token: refreshToken
  });

  return proxyTokenRequest(cfg.value, payload);
}

async function handleClientCredentials(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const cfg = loadConfig(env);
  if (!cfg.ok) {
    return json({ error: cfg.error }, 500);
  }

  const payload = new URLSearchParams({
    grant_type: "client_credentials"
  });

  return proxyTokenRequest(cfg.value, payload, {
    Authorization: `Basic ${btoa(`${cfg.value.clientID}:${cfg.value.clientSecret}`)}`
  });
}

async function handleLastFMMobileSession(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const cfg = loadLastFMConfig(env);
  if (!cfg.ok) {
    return json({ error: cfg.error }, 500);
  }

  const body = await parseJSON<LastFMAuthRequest>(request);
  if (!body.ok) {
    return jsonParseError(body.error);
  }

  const username = body.value.username?.trim();
  const { password } = body.value;
  if (!username || !password) {
    return json({ error: "missing_required_fields" }, 400);
  }

  const params: Record<string, string> = {
    method: "auth.getMobileSession",
    username,
    password,
    api_key: cfg.value.apiKey
  };
  params.api_sig = signLastFM(params, cfg.value.apiSecret);

  return proxyLastFMRequest(cfg.value, params);
}

async function handleLastFMNowPlaying(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const cfg = loadLastFMConfig(env);
  if (!cfg.ok) {
    return json({ error: cfg.error }, 500);
  }

  const body = await parseJSON<LastFMNowPlayingRequest>(request);
  if (!body.ok) {
    return jsonParseError(body.error);
  }

  const { sessionKey, artist, track, durationSeconds } = body.value;
  if (!sessionKey || !artist || !track) {
    return json({ error: "missing_required_fields" }, 400);
  }

  const params: Record<string, string> = {
    method: "track.updateNowPlaying",
    artist,
    track,
    api_key: cfg.value.apiKey,
    sk: sessionKey
  };

  if (typeof durationSeconds === "number" && Number.isFinite(durationSeconds) && durationSeconds > 0) {
    params.duration = String(Math.floor(durationSeconds));
  }

  params.api_sig = signLastFM(params, cfg.value.apiSecret);
  return proxyLastFMRequest(cfg.value, params);
}

async function handleLastFMScrobble(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const cfg = loadLastFMConfig(env);
  if (!cfg.ok) {
    return json({ error: cfg.error }, 500);
  }

  const body = await parseJSON<LastFMScrobbleRequest>(request);
  if (!body.ok) {
    return jsonParseError(body.error);
  }

  const { sessionKey, scrobbles } = body.value;
  if (!sessionKey || !Array.isArray(scrobbles) || scrobbles.length === 0) {
    return json({ error: "missing_required_fields" }, 400);
  }

  const batch = scrobbles.slice(0, 50);
  const params: Record<string, string> = {
    method: "track.scrobble",
    api_key: cfg.value.apiKey,
    sk: sessionKey
  };

  for (const [index, item] of batch.entries()) {
    if (!item.artist || !item.track || typeof item.timestamp !== "number" || !Number.isFinite(item.timestamp) || item.timestamp <= 0) {
      return json({ error: "invalid_scrobble_payload" }, 400);
    }
    params[`artist[${index}]`] = item.artist;
    params[`track[${index}]`] = item.track;
    params[`timestamp[${index}]`] = String(Math.floor(item.timestamp));
  }

  params.api_sig = signLastFM(params, cfg.value.apiSecret);
  return proxyLastFMRequest(cfg.value, params);
}

async function handleLastFMTaste(request: Request, env: Env): Promise<Response> {
  if (request.method !== "POST") {
    return json({ error: "method_not_allowed" }, 405);
  }

  const cfg = loadLastFMConfig(env);
  if (!cfg.ok) {
    return json({ error: cfg.error }, 500);
  }

  const body = await parseJSON<LastFMTasteRequest>(request);
  if (!body.ok) {
    return jsonParseError(body.error);
  }

  const username = body.value.username?.trim();
  if (!username) {
    return json({ error: "missing_required_fields" }, 400);
  }

  const limit = clampLimit(body.value.limit, 50, 100);
  const [recent, artists] = await Promise.all([
    fetchLastFMJSON(cfg.value, {
      method: "user.getRecentTracks",
      user: username,
      limit: String(limit),
      extended: "0",
      api_key: cfg.value.apiKey
    }),
    fetchLastFMJSON(cfg.value, {
      method: "user.getTopArtists",
      user: username,
      period: "1month",
      limit: String(Math.min(limit, 30)),
      api_key: cfg.value.apiKey
    })
  ]);

  if (!recent.ok) {
    return json(recent.payload, recent.status);
  }

  if (!artists.ok) {
    return json(artists.payload, artists.status);
  }

  return json({
    username,
    recentTracks: normalizeRecentTracks(recent.value).slice(0, limit),
    topArtists: normalizeTopArtists(artists.value).slice(0, Math.min(limit, 30))
  });
}

async function proxyTokenRequest(
  cfg: BrokerConfig,
  payload: URLSearchParams,
  headers: Record<string, string> = {}
): Promise<Response> {
  let upstream: Response;

  try {
    upstream = await fetch(cfg.tokenURL, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded",
        ...headers
      },
      body: payload
    });
  } catch {
    return json({ error: "upstream_unavailable" }, 502);
  }

  const textResult = await readLimitedText(upstream.body, MAX_UPSTREAM_JSON_BYTES);
  if (!textResult.ok) {
    return json({ error: "upstream_response_too_large" }, 502);
  }
  const text = textResult.value;
  let responseBody = text;

  try {
    JSON.parse(text);
  } catch {
    responseBody = JSON.stringify({ error: "upstream_non_json" });
  }

  return new Response(responseBody, {
    status: upstream.status,
    headers: {
      "Content-Type": "application/json"
    }
  });
}

async function proxyLastFMRequest(cfg: LastFMConfig, params: Record<string, string>): Promise<Response> {
  const payload = new URLSearchParams({
    ...params,
    format: "json"
  });

  let upstream: Response;
  try {
    upstream = await fetch(cfg.apiURL, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded"
      },
      body: payload
    });
  } catch {
    return json({ error: "upstream_unavailable" }, 502);
  }

  const textResult = await readLimitedText(upstream.body, MAX_UPSTREAM_JSON_BYTES);
  if (!textResult.ok) {
    return json({ error: "upstream_response_too_large" }, 502);
  }
  const text = textResult.value;
  let responseBody = text;

  try {
    JSON.parse(text);
  } catch {
    responseBody = JSON.stringify({ error: "upstream_non_json" });
  }

  return new Response(responseBody, {
    status: upstream.status,
    headers: {
      "Content-Type": "application/json"
    }
  });
}

type LastFMJSONResult =
  | { ok: true; value: unknown }
  | { ok: false; status: number; payload: unknown };

async function fetchLastFMJSON(cfg: LastFMConfig, params: Record<string, string>): Promise<LastFMJSONResult> {
  const payload = new URLSearchParams({
    ...params,
    format: "json"
  });

  let upstream: Response;
  try {
    upstream = await fetch(cfg.apiURL, {
      method: "POST",
      headers: {
        Accept: "application/json",
        "Content-Type": "application/x-www-form-urlencoded"
      },
      body: payload
    });
  } catch {
    return { ok: false, status: 502, payload: { error: "upstream_unavailable" } };
  }

  const textResult = await readLimitedText(upstream.body, MAX_UPSTREAM_JSON_BYTES);
  if (!textResult.ok) {
    return { ok: false, status: 502, payload: { error: "upstream_response_too_large" } };
  }
  const text = textResult.value;
  let value: unknown;
  try {
    value = JSON.parse(text);
  } catch {
    return { ok: false, status: 502, payload: { error: "upstream_non_json" } };
  }

  if (!upstream.ok) {
    return { ok: false, status: upstream.status, payload: value };
  }

  if (isLastFMError(value)) {
    return { ok: false, status: 400, payload: value };
  }

  return { ok: true, value };
}

function normalizeRecentTracks(value: unknown): Array<{ artist: string; name: string }> {
  const tracks = readArray(readRecord(readRecord(value).recenttracks).track);
  return tracks.flatMap((raw) => {
    const record = readRecord(raw);
    const name = readString(record.name);
    const artist = readString(readRecord(record.artist)["#text"]);
    if (!artist || !name) {
      return [];
    }
    return [{ artist, name }];
  });
}

function normalizeTopArtists(value: unknown): Array<{ name: string; playcount: number }> {
  const artists = readArray(readRecord(readRecord(value).topartists).artist);
  return artists.flatMap((raw) => {
    const record = readRecord(raw);
    const name = readString(record.name);
    const playcount = readNumber(record.playcount);
    if (!name) {
      return [];
    }
    return [{ name, playcount }];
  });
}

type Result<T> = { ok: true; value: T } | { ok: false; error: string };

interface BrokerConfig {
  clientID: string;
  clientSecret: string;
  tokenURL: string;
}

interface LastFMConfig {
  apiKey: string;
  apiSecret: string;
  apiURL: string;
}

function loadConfig(env: Env): Result<BrokerConfig> {
  if (!env.SOUNDCLOUD_CLIENT_ID) {
    return { ok: false, error: "missing_soundcloud_client_id" };
  }

  if (!env.SOUNDCLOUD_CLIENT_SECRET) {
    return { ok: false, error: "missing_soundcloud_client_secret" };
  }

  const tokenURL = env.SOUNDCLOUD_TOKEN_URL || "https://secure.soundcloud.com/oauth/token";
  if (!isValidHTTPURL(tokenURL)) {
    return { ok: false, error: "invalid_soundcloud_token_url" };
  }

  return {
    ok: true,
    value: {
      clientID: env.SOUNDCLOUD_CLIENT_ID,
      clientSecret: env.SOUNDCLOUD_CLIENT_SECRET,
      tokenURL
    }
  };
}

function loadLastFMConfig(env: Env): Result<LastFMConfig> {
  if (!env.LASTFM_API_KEY) {
    return { ok: false, error: "missing_lastfm_api_key" };
  }

  if (!env.LASTFM_API_SECRET) {
    return { ok: false, error: "missing_lastfm_api_secret" };
  }

  const apiURL = env.LASTFM_API_URL || "https://ws.audioscrobbler.com/2.0/";
  if (!isValidHTTPURL(apiURL)) {
    return { ok: false, error: "invalid_lastfm_api_url" };
  }

  return {
    ok: true,
    value: {
      apiKey: env.LASTFM_API_KEY,
      apiSecret: env.LASTFM_API_SECRET,
      apiURL
    }
  };
}

function isValidHTTPURL(raw: string): boolean {
  try {
    const url = new URL(raw);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

function signLastFM(params: Record<string, string>, apiSecret: string): string {
  const payload = Object.entries(params)
    .filter(([key]) => key !== "format" && key !== "callback" && key !== "api_sig")
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value]) => `${key}${value}`)
    .join("") + apiSecret;

  return md5(payload);
}

async function parseJSON<T>(request: Request): Promise<Result<T>> {
  const contentLength = Number(request.headers.get("Content-Length"));
  if (Number.isFinite(contentLength) && contentLength > MAX_JSON_BODY_BYTES) {
    return { ok: false, error: "request_too_large" };
  }

  try {
    const text = await readLimitedText(request.body, MAX_JSON_BODY_BYTES);
    if (!text.ok) {
      return { ok: false, error: "request_too_large" };
    }
    return { ok: true, value: JSON.parse(text.value) as T };
  } catch {
    return { ok: false, error: "invalid_json" };
  }
}

function jsonParseError(error: string): Response {
  return json({ error }, error === "request_too_large" ? 413 : 400);
}

async function readLimitedText(
  stream: ReadableStream<Uint8Array> | null,
  maxBytes: number
): Promise<Result<string>> {
  if (!stream) {
    return { ok: true, value: "" };
  }

  const reader = stream.getReader();
  const chunks: Uint8Array[] = [];
  let receivedBytes = 0;

  while (true) {
    const { done, value } = await reader.read();
    if (done) {
      break;
    }
    if (!value) {
      continue;
    }

    receivedBytes += value.byteLength;
    if (receivedBytes > maxBytes) {
      await reader.cancel();
      return { ok: false, error: "request_too_large" };
    }
    chunks.push(value);
  }

  const buffer = new Uint8Array(receivedBytes);
  let offset = 0;
  for (const chunk of chunks) {
    buffer.set(chunk, offset);
    offset += chunk.byteLength;
  }

  return { ok: true, value: new TextDecoder().decode(buffer) };
}

function json(payload: unknown, status = 200, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(payload), {
    status,
    headers: {
      "Content-Type": "application/json",
      ...headers
    }
  });
}

function clampLimit(value: number | undefined, fallback: number, max: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return fallback;
  }

  return Math.min(max, Math.max(1, Math.floor(value)));
}

function readRecord(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }
  return value as Record<string, unknown>;
}

function readArray(value: unknown): unknown[] {
  if (Array.isArray(value)) {
    return value;
  }
  if (value && typeof value === "object") {
    return [value];
  }
  return [];
}

function readString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

function readNumber(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string") {
    const parsed = Number(value.trim());
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

function isLastFMError(value: unknown): boolean {
  const record = readRecord(value);
  return typeof record.error === "number"
    || (typeof record.message === "string" && typeof record.error !== "undefined");
}

interface RateLimitConfig {
  maxRequests: number;
  windowSeconds: number;
}

type RateLimitResult =
  | { ok: true }
  | { ok: false; retryAfterSeconds: number };

async function checkRateLimit(request: Request, env: Env, url: URL): Promise<RateLimitResult> {
  if (request.method === "GET" && (url.pathname === "/healthz" || url.pathname === "/version")) {
    return { ok: true };
  }

  const cfg = loadRateLimitConfig(env);
  if (cfg.maxRequests <= 0 || cfg.windowSeconds <= 0) {
    return { ok: true };
  }

  const key = await rateLimitKey(request);
  const now = Date.now();
  const windowMs = cfg.windowSeconds * 1_000;
  const existing = rateLimitBuckets.get(key);

  if (!existing || existing.resetAt <= now) {
    rateLimitBuckets.set(key, { count: 1, resetAt: now + windowMs });
    cleanupRateLimitBuckets(now);
    return { ok: true };
  }

  if (existing.count >= cfg.maxRequests) {
    return {
      ok: false,
      retryAfterSeconds: Math.max(1, Math.ceil((existing.resetAt - now) / 1_000))
    };
  }

  existing.count += 1;
  return { ok: true };
}

function loadRateLimitConfig(env: Env): RateLimitConfig {
  return {
    maxRequests: parsePositiveInt(env.RATE_LIMIT_PER_MINUTE, 90),
    windowSeconds: parsePositiveInt(env.RATE_LIMIT_WINDOW_SECONDS, 60)
  };
}

function parsePositiveInt(raw: string | undefined, fallback: number): number {
  if (!raw) {
    return fallback;
  }

  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

async function rateLimitKey(request: Request): Promise<string> {
  const fingerprint = [
    request.headers.get("CF-Connecting-IP") || "unknown-ip",
    request.headers.get("User-Agent") || "unknown-agent"
  ].join("|");
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(fingerprint));
  return [...new Uint8Array(digest)]
    .slice(0, 12)
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

function cleanupRateLimitBuckets(now: number): void {
  if (rateLimitBuckets.size < 1_000) {
    return;
  }

  for (const [key, bucket] of rateLimitBuckets) {
    if (bucket.resetAt <= now) {
      rateLimitBuckets.delete(key);
    }
  }
}

function withCORS(env: Env, response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set("Access-Control-Allow-Origin", env.ALLOWED_ORIGIN || "*");
  headers.set("Access-Control-Allow-Headers", "Content-Type, Authorization");
  headers.set("Access-Control-Allow-Methods", "GET, POST, OPTIONS");

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers
  });
}

function withSecurityHeaders(response: Response): Response {
  const headers = new Headers(response.headers);
  headers.set("X-Content-Type-Options", "nosniff");
  headers.set("Referrer-Policy", "no-referrer");
  headers.set("Cache-Control", "no-store");

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers
  });
}

function withRequestID(response: Response, requestID: string): Response {
  const headers = new Headers(response.headers);
  headers.set("X-Request-ID", requestID);

  return new Response(response.body, {
    status: response.status,
    statusText: response.statusText,
    headers
  });
}

async function logRequest(
  request: Request,
  url: URL,
  response: Response,
  startedAt: number,
  requestID: string
): Promise<void> {
  const cf = (request as RequestWithCF).cf;
  console.log(JSON.stringify({
    type: "request",
    requestID,
    method: request.method,
    path: url.pathname,
    status: response.status,
    durationMs: Date.now() - startedAt,
    colo: cf?.colo || null
  }));
}

async function logWorkerError(requestID: string, url: URL, error: unknown): Promise<void> {
  console.error(JSON.stringify({
    type: "error",
    requestID,
    path: url.pathname,
    message: error instanceof Error ? error.message : "unknown_error"
  }));
}
