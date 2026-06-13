# CloudScrobble SoundCloud Token Broker Worker

Cloudflare Workers version of the SoundCloud token broker used by the iOS app.

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
curl https://cloudscrobble-token-broker.<your-subdomain>.workers.dev/healthz
```

Expected:

```json
{"status":"ok"}
```

After deploy, set the iOS app's `SOUNDCLOUD_TOKEN_BROKER_BASE_URL` to the Worker URL and rebuild the app.
