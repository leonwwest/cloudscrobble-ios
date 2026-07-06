import { describe, it, expect, beforeAll, afterAll } from "vitest";
import { unstable_dev, type Unstable_DevWorker } from "wrangler";

describe("broker router (unstable_dev)", () => {
  let worker: Unstable_DevWorker;

  beforeAll(async () => {
    worker = await unstable_dev("src/index.ts", {
      config: "./wrangler.jsonc",
      persist: false,
      vars: {
        APP_API_KEY: "test-key",
        SOUNDCLOUD_CLIENT_ID: "id",
        SOUNDCLOUD_CLIENT_SECRET: "secret",
        LASTFM_API_KEY: "key",
        LASTFM_API_SECRET: "secret"
      }
    });
  });

  afterAll(async () => {
    await worker?.stop();
  });

  it("responds to GET /healthz without an API key", async () => {
    const response = await worker.fetch("/healthz");
    expect(response.status).toBe(200);
    const body = await response.json() as { status: string; appAPIKeyConfigured: boolean };
    expect(body.status).toBe("ok");
    expect(body.appAPIKeyConfigured).toBe(true);
  });

  it("responds to GET /version without an API key", async () => {
    const response = await worker.fetch("/version");
    expect(response.status).toBe(200);
    const body = await response.json() as { version: string };
    expect(body.version).toBe("2026.06.13.1");
  });

  it("rejects protected routes without X-API-Key with 401", async () => {
    const response = await worker.fetch("/oauth/soundcloud/exchange", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({})
    });
    expect(response.status).toBe(401);
    const body = await response.json() as { error: string };
    expect(body.error).toBe("unauthorized_api_key");
  });

  it("rejects protected routes with a mismatched X-API-Key", async () => {
    const response = await worker.fetch("/oauth/soundcloud/exchange", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-Key": "wrong" },
      body: JSON.stringify({})
    });
    expect(response.status).toBe(401);
  });

  it("passes the gate with a valid X-API-Key and reports missing fields (400)", async () => {
    const response = await worker.fetch("/oauth/soundcloud/exchange", {
      method: "POST",
      headers: { "Content-Type": "application/json", "X-API-Key": "test-key" },
      body: JSON.stringify({})
    });
    expect(response.status).toBe(400);
    const body = await response.json() as { error: string };
    expect(body.error).toBe("missing_required_fields");
  });

  it("returns 404 for unknown routes", async () => {
    const response = await worker.fetch("/nope", {
      headers: { "X-API-Key": "test-key" }
    });
    expect(response.status).toBe(404);
  });
});
