# Security notes

This document describes the CloudScrobble token broker's protections and the
operational steps required to keep credentials safe.

## Broker authentication (APP_API_KEY)

All non-public broker routes (`/oauth/*`, `/lastfm/*`) require an `X-API-Key`
header whose value matches the broker's `APP_API_KEY` secret. `/healthz` and
`/version` remain public for smoke checks.

- **Worker (production):** set the secret with
  `cd workers/soundcloud-token-broker && wrangler secret put APP_API_KEY`.
  When the secret is absent the gate is disabled (local dev / smoke only); the
  deployed worker **must** have it set.
- **Go backend (local dev):** set `APP_API_KEY` in `backend/.env` or the
  environment. When unset, the gate is disabled so existing local flows keep
  working.
- **App:** set `CS_APP_API_KEY` in the root `.env` (synced into the Xcode
  scheme via `scripts/sync_env_to_xcode_scheme.sh`) to the same value as the
  broker's `APP_API_KEY`. The app sends it as the `X-API-Key` header on every
  broker request.

Note: a static API key shipped in an app binary is extractable. It is a
defense-in-depth layer that raises the bar against casual abuse; it is **not**
a substitute for keeping the SoundCloud client secret and Last.fm secret
server-side only (which the broker design already enforces).

## CORS

`ALLOWED_ORIGIN` defaults to empty in `wrangler.jsonc`, so browsers receive no
`Access-Control-Allow-Origin` header and cannot call the broker cross-origin.
The iOS app uses `URLSession` (not a browser) and does not rely on CORS. To
permit a specific browser origin (e.g. for ad-hoc testing), set
`ALLOWED_ORIGIN` to that origin in `wrangler.jsonc` or via
`wrangler secret put ALLOWED_ORIGIN`.

## Rate limiting (KV)

When the `RATE_LIMIT` KV namespace is bound, the broker enforces a per-IP
fixed-window counter (`RATE_LIMIT_PER_MINUTE` / `RATE_LIMIT_WINDOW_SECONDS`).
KV is eventually consistent, so this is best-effort defense-in-depth behind the
API-key gate; it is not a precise abuse counter.

To enable:

```bash
cd workers/soundcloud-token-broker
wrangler kv namespace create RATE_LIMIT
# Copy the returned id into wrangler.jsonc under kv_namespaces, then:
wrangler deploy
```

Add to `wrangler.jsonc`:

```jsonc
"kv_namespaces": [
  { "binding": "RATE_LIMIT", "id": "<id-from-create>" }
]
```

When the binding is absent (local `wrangler dev`, smoke tests), rate limiting
is skipped and the API-key gate is the sole protection.

## Credential rotation

If any secret is exposed (committed, shared, or observed by a third party),
rotate it:

- **Last.fm API key/secret:** create a new app at
  https://www.last.fm/api/accounts, update the Worker (`wrangler secret put
  LASTFM_API_KEY` and `wrangler secret put LASTFM_API_SECRET`) and the Go
  backend `backend/.env`.
- **SoundCloud client secret:** rotate in the SoundCloud app settings, then
  update the Worker (`wrangler secret put SOUNDCLOUD_CLIENT_SECRET`) and
  `backend/.env`.
- **APP_API_KEY:** generate a new value and replace it on the Worker
  (`wrangler secret put APP_API_KEY`), the Go backend (`backend/.env`), and the
  app `.env` (`CS_APP_API_KEY`).

Local `.env` and `backend/.env` are gitignored and must never be committed.
Never place `SOUNDCLOUD_CLIENT_SECRET` or `LASTFM_API_SECRET` in the app `.env`
or Xcode scheme; they belong only in the broker.
