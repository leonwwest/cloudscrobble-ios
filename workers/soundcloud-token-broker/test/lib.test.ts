import { describe, it, expect } from "vitest";
import {
  signLastFM,
  clampLimit,
  parsePositiveInt,
  loadRateLimitConfig,
  loadBoolean,
  isAppAPIKeyRequired,
  isRateLimitFailClosed,
  loadUpstreamTimeoutMs,
  loadConfig,
  loadLastFMConfig,
  isValidHTTPURL,
  readRecord,
  readArray,
  readString,
  readNumber,
  isLastFMError,
  normalizeRecentTracks,
  normalizeTopArtists,
  requireAppAPIKey,
  type Env
} from "../src/lib";

describe("signLastFM", () => {
  it("matches the known Last.fm signature for a mobile-session request", () => {
    const params = {
      method: "auth.getMobileSession",
      username: "westf5",
      password: "pw",
      api_key: "lastfm-key"
    };
    expect(signLastFM(params, "lastfm-secret")).toBe("5563af7c78d4ef3742d341f8b7cc83f6");
  });

  it("matches the known signature for a batched scrobble request with indexed keys", () => {
    const params = {
      method: "track.scrobble",
      api_key: "key",
      sk: "session",
      "artist[0]": "A",
      "track[0]": "T",
      "timestamp[0]": "1700000000"
    };
    expect(signLastFM(params, "secret")).toBe("3b965f921c236c6ad1992b6d9bb941c4");
  });

  it("matches the known signature for a now-playing request", () => {
    const params = {
      method: "track.updateNowPlaying",
      api_key: "key",
      sk: "session",
      artist: "A",
      track: "T",
      duration: "120"
    };
    expect(signLastFM(params, "secret")).toBe("e8c97ace37eba3ac30a8cd639e3c99d6");
  });

  it("excludes format, callback, and api_sig from the signature payload", () => {
    const base = { method: "track.scrobble", api_key: "key", sk: "session" };
    const withIgnored = {
      ...base,
      format: "json",
      callback: "cb",
      api_sig: "should-be-ignored"
    };
    expect(signLastFM(withIgnored, "secret")).toBe(signLastFM(base, "secret"));
  });
});

describe("clampLimit", () => {
  it("returns the fallback for non-finite input", () => {
    expect(clampLimit(undefined, 50, 100)).toBe(50);
    expect(clampLimit(NaN, 50, 100)).toBe(50);
  });

  it("clamps to [1, max] and floors", () => {
    expect(clampLimit(0, 50, 100)).toBe(1);
    expect(clampLimit(150, 50, 100)).toBe(100);
    expect(clampLimit(42.9, 50, 100)).toBe(42);
  });
});

describe("parsePositiveInt", () => {
  it("falls back for empty or invalid input", () => {
    expect(parsePositiveInt(undefined, 90)).toBe(90);
    expect(parsePositiveInt("", 90)).toBe(90);
    expect(parsePositiveInt("nope", 90)).toBe(90);
  });

  it("parses non-negative integers", () => {
    expect(parsePositiveInt("5", 90)).toBe(5);
    expect(parsePositiveInt("0", 90)).toBe(0);
  });
});

describe("loadRateLimitConfig", () => {
  it("applies defaults when env vars are missing", () => {
    expect(loadRateLimitConfig({} as Env)).toEqual({ maxRequests: 90, windowSeconds: 60 });
  });

  it("reads overridden values", () => {
    expect(
      loadRateLimitConfig({ RATE_LIMIT_PER_MINUTE: "10", RATE_LIMIT_WINDOW_SECONDS: "30" } as Env)
    ).toEqual({ maxRequests: 10, windowSeconds: 30 });
  });
});

describe("security and timeout configuration", () => {
  it("uses fail-closed production defaults", () => {
    expect(isAppAPIKeyRequired({} as Env)).toBe(true);
    expect(isRateLimitFailClosed({} as Env)).toBe(true);
    expect(loadUpstreamTimeoutMs({} as Env)).toBe(10_000);
  });

  it("supports explicit local overrides and bounds upstream timeouts", () => {
    expect(loadBoolean("off", true)).toBe(false);
    expect(isAppAPIKeyRequired({ REQUIRE_APP_API_KEY: "false" } as Env)).toBe(false);
    expect(isRateLimitFailClosed({ RATE_LIMIT_FAIL_CLOSED: "0" } as Env)).toBe(false);
    expect(loadUpstreamTimeoutMs({ UPSTREAM_TIMEOUT_MS: "100" } as Env)).toBe(1_000);
    expect(loadUpstreamTimeoutMs({ UPSTREAM_TIMEOUT_MS: "999999" } as Env)).toBe(30_000);
  });
});

describe("loadConfig / loadLastFMConfig", () => {
  it("reports missing soundcloud credentials", () => {
    expect(loadConfig({} as Env)).toEqual({ ok: false, error: "missing_soundcloud_client_id" });
    expect(loadConfig({ SOUNDCLOUD_CLIENT_ID: "id" } as Env)).toEqual({
      ok: false,
      error: "missing_soundcloud_client_secret"
    });
  });

  it("rejects invalid token URLs", () => {
    const result = loadConfig({
      SOUNDCLOUD_CLIENT_ID: "id",
      SOUNDCLOUD_CLIENT_SECRET: "secret",
      SOUNDCLOUD_TOKEN_URL: "ftp://bad"
    } as Env);
    expect(result).toEqual({ ok: false, error: "invalid_soundcloud_token_url" });
  });

  it("reports missing lastfm credentials", () => {
    expect(loadLastFMConfig({} as Env)).toEqual({ ok: false, error: "missing_lastfm_api_key" });
  });
});

describe("isValidHTTPURL", () => {
  it("accepts http(s) URLs with a host", () => {
    expect(isValidHTTPURL("https://example.com")).toBe(true);
    expect(isValidHTTPURL("http://localhost:8787")).toBe(true);
  });

  it("rejects non-http schemes and garbage", () => {
    expect(isValidHTTPURL("ftp://example.com")).toBe(false);
    expect(isValidHTTPURL("not-a-url")).toBe(false);
  });
});

describe("readers", () => {
  it("readRecord returns empty object for non-records", () => {
    expect(readRecord(null)).toEqual({});
    expect(readRecord([])).toEqual({});
    expect(readRecord({ a: 1 })).toEqual({ a: 1 });
  });

  it("readArray coerces single objects to arrays", () => {
    expect(readArray({ a: 1 })).toEqual([{ a: 1 }]);
    expect(readArray([1, 2])).toEqual([1, 2]);
    expect(readArray("x")).toEqual([]);
  });

  it("readString trims", () => {
    expect(readString("  hi  ")).toBe("hi");
    expect(readString(123)).toBe("");
  });

  it("readNumber parses strings and numbers", () => {
    expect(readNumber("42")).toBe(42);
    expect(readNumber(3.5)).toBe(3.5);
    expect(readNumber("nope")).toBe(0);
  });
});

describe("isLastFMError", () => {
  it("detects numeric error codes", () => {
    expect(isLastFMError({ error: 9, message: "Invalid session" })).toBe(true);
  });

  it("returns false for clean payloads", () => {
    expect(isLastFMError({ session: { key: "k" } })).toBe(false);
  });
});

describe("normalizeRecentTracks / normalizeTopArtists", () => {
  it("normalizes recent tracks, dropping incomplete entries", () => {
    const value = {
      recenttracks: {
        track: [
          { name: "Song A", artist: { "#text": "Artist A" } },
          { name: "", artist: { "#text": "Artist B" } },
          { name: "Song C", artist: { "#text": "" } }
        ]
      }
    };
    expect(normalizeRecentTracks(value)).toEqual([
      { artist: "Artist A", name: "Song A" }
    ]);
  });

  it("normalizes top artists with playcounts", () => {
    const value = {
      topartists: {
        artist: [
          { name: "Artist A", playcount: "42" },
          { name: "Artist B", playcount: 7 }
        ]
      }
    };
    expect(normalizeTopArtists(value)).toEqual([
      { name: "Artist A", playcount: 42 },
      { name: "Artist B", playcount: 7 }
    ]);
  });
});

describe("requireAppAPIKey", () => {
  const makeRequest = (header?: string) => {
    const req = new Request("https://broker.example/oauth/soundcloud/exchange", {
      method: "POST"
    });
    if (header !== undefined) {
      req.headers.set("X-API-Key", header);
    }
    return req;
  };

  it("fails closed when APP_API_KEY is unset by default", () => {
    expect(requireAppAPIKey(makeRequest("anything"), {} as Env)).toEqual({ ok: false });
    expect(requireAppAPIKey(makeRequest(), {} as Env)).toEqual({ ok: false });
  });

  it("can be explicitly disabled for local smoke environments", () => {
    const env = { REQUIRE_APP_API_KEY: "false" } as Env;
    expect(requireAppAPIKey(makeRequest(), env)).toEqual({ ok: true });
  });

  it("rejects missing or mismatched keys", () => {
    const env = { APP_API_KEY: "secret" } as Env;
    expect(requireAppAPIKey(makeRequest(), env)).toEqual({ ok: false });
    expect(requireAppAPIKey(makeRequest("wrong"), env)).toEqual({ ok: false });
  });

  it("accepts a matching key", () => {
    const env = { APP_API_KEY: "secret" } as Env;
    expect(requireAppAPIKey(makeRequest("secret"), env)).toEqual({ ok: true });
  });
});
