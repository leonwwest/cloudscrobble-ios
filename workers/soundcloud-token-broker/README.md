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
```

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
{"status":"ok"}
```

Current iOS builds default to the deployed Worker URL. If `SOUNDCLOUD_TOKEN_BROKER_BASE_URL` is set to a localhost, LAN, or other private URL, the app replaces it with the deployed Worker at startup.
