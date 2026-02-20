# CloudScrobble Token Broker

Minimal backend for SoundCloud OAuth token exchange/refresh.

## Endpoints
- `POST /oauth/soundcloud/exchange`
- `POST /oauth/soundcloud/refresh`
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
