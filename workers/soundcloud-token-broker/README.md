# CloudScrobble SoundCloud Token Broker Worker

Cloudflare Workers version of the SoundCloud and Last.fm token broker used by production iOS app builds.

The Go service in `../../backend` is kept as a local development and smoke-test mirror. Use this Worker as the primary deployment target.

## Endpoints

- `GET /healthz`
- `POST /oauth/soundcloud/exchange`
- `POST /oauth/soundcloud/refresh`
- `POST /oauth/soundcloud/client-credentials`
- `POST /oauth/lastfm/mobile-session`
- `POST /lastfm/now-playing`
- `POST /lastfm/scrobble`
- `POST /lastfm/taste`

## Setup

```bash
cd workers/soundcloud-token-broker
npm install
npx wrangler login
```

Set the SoundCloud credentials as encrypted Worker secrets:

```bash
npx wrangler secret put SOUNDCLOUD_CLIENT_ID
npx wrangler secret put SOUNDCLOUD_CLIENT_SECRET
npx wrangler secret put LASTFM_API_KEY
npx wrangler secret put LASTFM_API_SECRET
npx wrangler secret put APP_API_KEY
```

Protected routes fail closed when `APP_API_KEY` is missing. Only local smoke
environments should opt out explicitly with `REQUIRE_APP_API_KEY=false`.
Upstream calls have a bounded timeout controlled by `UPSTREAM_TIMEOUT_MS`
(default 10 seconds, accepted range 1–30 seconds).

Deploy:

```bash
npm run deploy
```

Test the deployed Worker:

```bash
curl https://broker.example/healthz
```

Expected:

```json
{"status":"ok","ready":true}
```

The complete health payload reports upstream credential readiness, API-key
enforcement, rate-limit binding state, failure mode, and upstream timeout
without exposing secret values.

Current iOS builds default to the deployed Worker URL. Release builds use only
HTTPS broker URLs; Debug builds may additionally use HTTP localhost or private
network brokers.
