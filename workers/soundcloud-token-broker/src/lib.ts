import { md5 } from "js-md5";

export const APP_API_KEY_HEADER = "X-API-Key";

export interface Env {
  SOUNDCLOUD_CLIENT_ID?: string;
  SOUNDCLOUD_CLIENT_SECRET?: string;
  SOUNDCLOUD_TOKEN_URL?: string;
  LASTFM_API_KEY?: string;
  LASTFM_API_SECRET?: string;
  LASTFM_API_URL?: string;
  ALLOWED_ORIGIN?: string;
  RATE_LIMIT_PER_MINUTE?: string;
  RATE_LIMIT_WINDOW_SECONDS?: string;
  RATE_LIMIT_FAIL_CLOSED?: string;
  REQUIRE_APP_API_KEY?: string;
  UPSTREAM_TIMEOUT_MS?: string;
  // Shared secret gating all non-public routes. Set via `wrangler secret put APP_API_KEY`.
  // When unset, routes fail closed unless local smoke explicitly opts out.
  APP_API_KEY?: string;
  // Optional KV namespace binding. When bound, enables per-fingerprint rate limiting.
  // KV is eventually consistent, so this is defense-in-depth behind the API-key gate.
  RATE_LIMIT?: KVNamespace;
}

export type Result<T> = { ok: true; value: T } | { ok: false; error: string };

export interface BrokerConfig {
  clientID: string;
  clientSecret: string;
  tokenURL: string;
}

export interface LastFMConfig {
  apiKey: string;
  apiSecret: string;
  apiURL: string;
}

export interface RateLimitConfig {
  maxRequests: number;
  windowSeconds: number;
}

export type RateLimitResult =
  | { ok: true }
  | { ok: false; reason: "limited" | "unavailable"; retryAfterSeconds: number };

export type AppAPIKeyResult = { ok: true } | { ok: false };

export interface LastFMTasteTrack {
  artist: string;
  name: string;
}

export interface LastFMTasteArtist {
  name: string;
  playcount: number;
}

export function loadConfig(env: Env): Result<BrokerConfig> {
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

export function loadLastFMConfig(env: Env): Result<LastFMConfig> {
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

export function loadRateLimitConfig(env: Env): RateLimitConfig {
  return {
    maxRequests: parsePositiveInt(env.RATE_LIMIT_PER_MINUTE, 90),
    windowSeconds: parsePositiveInt(env.RATE_LIMIT_WINDOW_SECONDS, 60)
  };
}

export function loadBoolean(raw: string | undefined, fallback: boolean): boolean {
  if (!raw) {
    return fallback;
  }

  switch (raw.trim().toLowerCase()) {
    case "1":
    case "true":
    case "yes":
    case "on":
      return true;
    case "0":
    case "false":
    case "no":
    case "off":
      return false;
    default:
      return fallback;
  }
}

export function isAppAPIKeyRequired(env: Env): boolean {
  return loadBoolean(env.REQUIRE_APP_API_KEY, true);
}

export function isRateLimitFailClosed(env: Env): boolean {
  return loadBoolean(env.RATE_LIMIT_FAIL_CLOSED, true);
}

export function loadUpstreamTimeoutMs(env: Env): number {
  const fallback = 10_000;
  const parsed = Number.parseInt(env.UPSTREAM_TIMEOUT_MS || "", 10);
  if (!Number.isFinite(parsed)) {
    return fallback;
  }
  return Math.min(30_000, Math.max(1_000, parsed));
}

export function parsePositiveInt(raw: string | undefined, fallback: number): number {
  if (!raw) {
    return fallback;
  }

  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed >= 0 ? parsed : fallback;
}

export function isValidHTTPURL(raw: string): boolean {
  try {
    const url = new URL(raw);
    return url.protocol === "http:" || url.protocol === "https:";
  } catch {
    return false;
  }
}

export function signLastFM(params: Record<string, string>, apiSecret: string): string {
  const payload = Object.entries(params)
    .filter(([key]) => key !== "format" && key !== "callback" && key !== "api_sig")
    .sort(([left], [right]) => left.localeCompare(right))
    .map(([key, value]) => `${key}${value}`)
    .join("") + apiSecret;

  return md5(payload);
}

export function clampLimit(value: number | undefined, fallback: number, max: number): number {
  if (typeof value !== "number" || !Number.isFinite(value)) {
    return fallback;
  }

  return Math.min(max, Math.max(1, Math.floor(value)));
}

export function readRecord(value: unknown): Record<string, unknown> {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return {};
  }
  return value as Record<string, unknown>;
}

export function readArray(value: unknown): unknown[] {
  if (Array.isArray(value)) {
    return value;
  }
  if (value && typeof value === "object") {
    return [value];
  }
  return [];
}

export function readString(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

export function readNumber(value: unknown): number {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string") {
    const parsed = Number(value.trim());
    return Number.isFinite(parsed) ? parsed : 0;
  }
  return 0;
}

export function isLastFMError(value: unknown): boolean {
  const record = readRecord(value);
  return typeof record.error === "number"
    || (typeof record.message === "string" && typeof record.error !== "undefined");
}

export function normalizeRecentTracks(value: unknown): LastFMTasteTrack[] {
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

export function normalizeTopArtists(value: unknown): LastFMTasteArtist[] {
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

export function requireAppAPIKey(request: Request, env: Env): AppAPIKeyResult {
  const expected = env.APP_API_KEY;
  if (!expected) {
    // Production-safe default: a missing secret keeps protected routes closed.
    // Local smoke environments can explicitly set REQUIRE_APP_API_KEY=false.
    return { ok: !isAppAPIKeyRequired(env) };
  }
  const provided = request.headers.get(APP_API_KEY_HEADER);
  if (!provided || provided !== expected) {
    return { ok: false };
  }
  return { ok: true };
}

export async function rateLimitKey(request: Request): Promise<string> {
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
