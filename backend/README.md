# CloudScrobble Token Broker

Minimal backend for SoundCloud OAuth token exchange/refresh.

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
