# CloudScrobble Local Token Broker

Local Go backend for SoundCloud OAuth token exchange/refresh and Last.fm proxy development.

Production iOS builds use the Cloudflare Worker in `workers/soundcloud-token-broker`. Keep this Go service as a local dev and smoke-test mirror, not as the primary deployment target.

## Endpoints
- `POST /oauth/soundcloud/exchange`
- `POST /oauth/soundcloud/refresh`
- `POST /oauth/soundcloud/client-credentials`
- `GET /healthz`

## Run
```bash
cp .env.example .env
export $(grep -v '^#' .env | xargs)
go run .
```

## Test role
`scripts/e2e_smoke.sh` starts this service against a mocked SoundCloud token upstream to verify exchange, refresh, and client-credentials behavior without live credentials.

## Exchange payload
```json
{
  "code": "auth_code",
  "codeVerifier": "pkce_verifier",
  "redirectUri": "cloudscrobble://oauth"
}
```

## Refresh payload
```json
{
  "refreshToken": "refresh_token"
}
```

## Client credentials payload
No payload required (empty JSON body is fine).
The broker sends `grant_type=client_credentials` to SoundCloud and authenticates the app with HTTP Basic Auth using `SOUNDCLOUD_CLIENT_ID:SOUNDCLOUD_CLIENT_SECRET`.
