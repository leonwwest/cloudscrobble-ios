import { afterAll, beforeAll, describe, expect, it } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";
import { createServer, type Server } from "node:http";
import type { AddressInfo } from "node:net";

describe("worker security smoke", () => {
  let protectedWorker: Unstable_DevWorker;
  let localOptOutWorker: Unstable_DevWorker;
  let timeoutWorker: Unstable_DevWorker;
  let hangingUpstream: Server;

  beforeAll(async () => {
    hangingUpstream = createServer(() => {
      // Deliberately never send headers; the Worker must abort this request.
    });
    await new Promise<void>((resolve) => hangingUpstream.listen(0, "127.0.0.1", resolve));
    const upstreamAddress = hangingUpstream.address() as AddressInfo;

    protectedWorker = await unstable_dev("src/index.ts", {
      config: "./wrangler.jsonc",
      persist: false,
      vars: {
        REQUIRE_APP_API_KEY: "true",
        SOUNDCLOUD_CLIENT_ID: "id",
        SOUNDCLOUD_CLIENT_SECRET: "secret",
        LASTFM_API_KEY: "key",
        LASTFM_API_SECRET: "secret",
        ALLOWED_ORIGIN: "https://app.example"
      }
    });
    localOptOutWorker = await unstable_dev("src/index.ts", {
      config: "./wrangler.jsonc",
      persist: false,
      vars: {
        REQUIRE_APP_API_KEY: "false",
        SOUNDCLOUD_CLIENT_ID: "id",
        SOUNDCLOUD_CLIENT_SECRET: "secret",
        LASTFM_API_KEY: "key",
        LASTFM_API_SECRET: "secret"
      }
    });
    timeoutWorker = await unstable_dev("src/index.ts", {
      config: "./wrangler.jsonc",
      persist: false,
      vars: {
        APP_API_KEY: "timeout-key",
        SOUNDCLOUD_CLIENT_ID: "id",
        SOUNDCLOUD_CLIENT_SECRET: "secret",
        SOUNDCLOUD_TOKEN_URL: `http://127.0.0.1:${upstreamAddress.port}/oauth/token`,
        LASTFM_API_KEY: "key",
        LASTFM_API_SECRET: "secret",
        UPSTREAM_TIMEOUT_MS: "1000"
      }
    });
  });

  afterAll(async () => {
    await Promise.all([protectedWorker?.stop(), localOptOutWorker?.stop(), timeoutWorker?.stop()]);
    hangingUpstream?.closeAllConnections();
    await new Promise<void>((resolve, reject) => {
      hangingUpstream?.close((error) => error ? reject(error) : resolve());
    });
  });

  it("fails closed when the required API-key secret is missing", async () => {
    const response = await protectedWorker.fetch("/oauth/soundcloud/exchange", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({})
    });

    expect(response.status).toBe(401);
    expect(await response.json()).toMatchObject({ error: "unauthorized_api_key" });
  });

  it("allows CORS preflight without authentication or rate-limit state", async () => {
    const response = await protectedWorker.fetch("/oauth/soundcloud/exchange", {
      method: "OPTIONS",
      headers: {
        Origin: "https://app.example",
        "Access-Control-Request-Method": "POST"
      }
    });

    expect(response.status).toBe(204);
    expect(response.headers.get("Access-Control-Allow-Origin")).toBe("https://app.example");
    expect(response.headers.get("Access-Control-Allow-Headers")).toContain("X-API-Key");
    expect(response.headers.get("X-Request-ID")).toBeTruthy();
  });

  it("reports degraded readiness and the active protection mode", async () => {
    const response = await protectedWorker.fetch("/healthz");
    const body = await response.json() as {
      status: string;
      ready: boolean;
      security: { appAPIKeyRequired: boolean; appAPIKeyConfigured: boolean };
      rateLimit: { requested: boolean; enabled: boolean; bindingConfigured: boolean };
    };

    expect(response.status).toBe(200);
    expect(body.status).toBe("degraded");
    expect(body.ready).toBe(false);
    expect(body.security).toMatchObject({
      appAPIKeyRequired: true,
      appAPIKeyConfigured: false
    });
    expect(body.rateLimit).toMatchObject({
      requested: true,
      enabled: true,
      bindingConfigured: true
    });
  });

  it("supports an explicit unauthenticated local smoke mode", async () => {
    const response = await localOptOutWorker.fetch("/oauth/soundcloud/exchange", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({})
    });

    expect(response.status).toBe(400);
    expect(await response.json()).toMatchObject({ error: "missing_required_fields" });
  });

  it("aborts a hanging upstream request at the configured deadline", async () => {
    const startedAt = Date.now();
    const response = await timeoutWorker.fetch("/oauth/soundcloud/client-credentials", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-API-Key": "timeout-key"
      },
      body: JSON.stringify({})
    });

    expect(response.status).toBe(504);
    expect(await response.json()).toMatchObject({ error: "upstream_timeout" });
    expect(Date.now() - startedAt).toBeLessThan(5_000);
  });
});
