# CloudScrobble

[![CI](https://github.com/leonwwest/cloudscrobble-ios/actions/workflows/ci.yml/badge.svg)](https://github.com/leonwwest/cloudscrobble-ios/actions/workflows/ci.yml)

A public native iOS client that plays SoundCloud tracks and scrobbles them to
Last.fm through a server-side token broker. The repository spans a SwiftUI app,
a testable Swift core, a local Go broker and a deployable Cloudflare Worker.

## 60-second recruiter view

| Area | Evidence in this repository |
| --- | --- |
| Product | Native SwiftUI search, library, queue and playback flows with Last.fm now-playing updates and scrobbling |
| Security | SoundCloud OAuth with PKCE and state validation, session tokens in Keychain and provider secrets kept behind a broker boundary |
| Reliability | Persisted offline scrobble queue, deduplication, batching, token refresh, bounded retries and stream-resolution fallback |
| Architecture | `CloudScrobbleCore` isolates domain and integration logic; the app depends on protocols; hosted and local brokers share the same API contract |
| CI | GitHub Actions runs Swift tests and a release build, an iOS Simulator release build, Go tests, Worker type-checking/tests and shell-script validation |
| Release evidence | Reproducible release-mode builds plus documented security and E2E checks; App Store/TestFlight distribution is outside this public repository |

Start with the [scrobble timing engine](Sources/CloudScrobbleCore/Playback/ScrobbleEngine.swift),
[OAuth implementation](Sources/CloudScrobbleCore/SoundCloud/SoundCloudAuthService.swift),
[security notes](docs/SECURITY.md), [test suite](Tests/CloudScrobbleCoreTests),
[CI workflow](.github/workflows/ci.yml) and
[end-to-end test guide](docs/E2E_TESTING.md).

## What is implemented

- `CloudScrobbleCore` (Swift package target)
  - SoundCloud OAuth token handling via token broker
  - SoundCloud API client (search, profile, playlists, me, streams)
  - Playback URL resolver with `/streams` then `/stream` fallback
  - Last.fm mobile auth + `updateNowPlaying` + `scrobble`
  - Offline scrobble queue persisted locally with one-time migration from the legacy Keychain store
  - Batched Last.fm scrobble flush (`track.scrobble` with up to 50 items/request)
  - Metadata mapping + scrobble timing engine
  - AVPlayer controller with queue and scrobble dispatch
- `CloudScrobbleApp` (SwiftUI executable target)
  - Tabs: Search / Library / Player
  - Connect SoundCloud and Last.fm
  - Demo Mode: local mock SoundCloud catalog without audio playback
  - SoundCloud login via system browser + callback deep-link
  - Search tracks/playlists/users
  - Open public user profiles
  - Load and play playlist tracks
  - My library from `/me` endpoints
- `backend/` (Go token broker)
  - Local development and smoke-test broker; production app builds use the Cloudflare Worker
  - `POST /oauth/soundcloud/exchange`
  - `POST /oauth/soundcloud/refresh`
  - `POST /oauth/soundcloud/client-credentials`
  - `GET /healthz`
- `workers/soundcloud-token-broker/` (Cloudflare Worker)
  - Production token broker used by current iOS builds
  - SoundCloud OAuth + Last.fm session/scrobble/taste proxy endpoints

## Repo structure
- `/Sources/CloudScrobbleCore` - protocols, models, services
- `/Sources/CloudScrobbleApp` - SwiftUI app and view models
- `/Tests/CloudScrobbleCoreTests` - unit tests for core logic
- `/workers/soundcloud-token-broker` - production Cloudflare Worker token broker
- `/backend` - local Go token broker used for development and smoke tests
- `/ios` - generated Xcode iOS app project (`CloudScrobbleiOS.xcodeproj`)

## Environment variables (app)
Set these in the project-root `.env` before running the app target:

```bash
export SOUNDCLOUD_CLIENT_ID="..."
export SOUNDCLOUD_REDIRECT_URI="cloudscrobble://oauth"
export SOUNDCLOUD_TOKEN_BROKER_BASE_URL="https://broker.example"
export CS_APP_API_KEY="..."
```

`SOUNDCLOUD_TOKEN_BROKER_BASE_URL` is optional for current app builds. Release builds accept only HTTPS. Debug builds additionally allow HTTP for localhost and private-network brokers; other invalid or insecure values fall back to the deployed Worker URL above.

Do not put `SOUNDCLOUD_CLIENT_SECRET`, `LASTFM_API_KEY`, or `LASTFM_API_SECRET` in the app `.env` or Xcode scheme. They belong only in Cloudflare Worker secrets or `backend/.env`, because the iOS app talks to the token broker instead of sending upstream credentials from the app.

## Token broker roles
- Production path: `workers/soundcloud-token-broker` on Cloudflare Workers.
- Local path: `backend` for fast local development and mocked broker smoke tests.
- Keep endpoint behavior aligned when changing auth or Last.fm proxy contracts.

## Run backend
```bash
cd backend
cp .env.example .env
export $(grep -v '^#' .env | xargs)
go run .
```

## Run tests
```bash
swift test
cd backend && go test ./...
cd workers/soundcloud-token-broker && npm run check
cd workers/soundcloud-token-broker && npm test
```

Optional live integration tests:
```bash
SOUNDCLOUD_LIVE_TESTS=1 swift test --filter SoundCloudLiveIntegrationTests
LASTFM_LIVE_TESTS=1 swift test --filter LastFMLiveIntegrationTests
```

## Run iOS app (Xcode target)
```bash
open ios/CloudScrobbleiOS.xcodeproj
```

In Xcode:
1. Select scheme `CloudScrobbleiOS`.
2. Choose an iOS Simulator.
3. Set run environment variables from `.env` in Scheme > Run > Arguments.
4. Run.

One-click alternative:
```bash
./scripts/open_ios_with_env.sh
```

This syncs `.env` to the Xcode scheme and opens the iOS project.
The helper writes env vars to an untracked user scheme under `xcuserdata`, not the shared scheme committed to the repo.

## SoundCloud OAuth checklist
If "Connect SoundCloud" fails in-app, verify:
1. SoundCloud app redirect URI is exactly `cloudscrobble://oauth`.
2. The deployed Worker is healthy: `curl https://broker.example/healthz`.
3. Xcode scheme env vars are synced (run `./scripts/sync_env_to_xcode_scheme.sh`).
4. iOS URL scheme `cloudscrobble` is present in `ios/project.yml` (generated into Info.plist).
5. In SoundCloud app settings (`https://soundcloud.com/you/apps`) click `Speichern` after entering redirect URI.
6. Validate broker credentials quickly:
   `curl -X POST https://broker.example/oauth/soundcloud/client-credentials -H 'Content-Type: application/json' -d '{}'`
   If this returns `{"error":"invalid_client"}`, your `SOUNDCLOUD_CLIENT_ID` / `SOUNDCLOUD_CLIENT_SECRET` pair is wrong.
7. If SoundCloud auth opens as a blank white page, disable system Auto Proxy / WPAD on macOS network settings and restart Simulator.
8. Fallback for testing:
   - `Use SoundCloud Public Mode` (real API token, `/me` library disabled)
   - `Use Demo Mode` (no SoundCloud API required; mock catalog only, no audio playback)

## End-to-end checks
- Automated smoke: `./scripts/e2e_smoke.sh`
- Optional Simulator UI smoke: `RUN_IOS_UI_TESTS=1 ./scripts/e2e_smoke.sh`
- Full manual E2E guide: `docs/E2E_TESTING.md`

## Notes
- The app intentionally does not implement offline download/storage.
- Playback flow prefers AAC HLS streams.
- For production/public release, keep OAuth secrets only in backend.
