# CloudScrobble

Private iOS MVP to play SoundCloud tracks and scrobble to Last.fm.

## What is implemented
- `CloudScrobbleCore` (Swift package target)
  - SoundCloud OAuth token handling via token broker
  - SoundCloud API client (search, profile, playlists, me, streams)
  - Playback URL resolver with `/streams` then `/stream` fallback
  - Last.fm mobile auth + `updateNowPlaying` + `scrobble`
  - Offline scrobble queue persisted in Keychain
  - Batched Last.fm scrobble flush (`track.scrobble` with up to 50 items/request)
  - Metadata mapping + scrobble timing engine
  - AVPlayer controller with queue and scrobble dispatch
- `CloudScrobbleApp` (SwiftUI executable target)
  - Tabs: Search / Library / Player
  - Connect SoundCloud and Last.fm
  - Demo Mode: local mock SoundCloud catalog + test HLS stream (works without SoundCloud API)
  - SoundCloud login via system browser + callback deep-link
  - Search tracks/playlists/users
  - Open public user profiles
  - Load and play playlist tracks
  - My library from `/me` endpoints
- `backend/` (Go token broker)
  - `POST /oauth/soundcloud/exchange`
  - `POST /oauth/soundcloud/refresh`
  - `POST /oauth/soundcloud/client-credentials`
  - `GET /healthz`

## Repo structure
- `/Sources/CloudScrobbleCore` - protocols, models, services
- `/Sources/CloudScrobbleApp` - SwiftUI app and view models
- `/Tests/CloudScrobbleCoreTests` - unit tests for core logic
- `/backend` - SoundCloud token broker backend
- `/ios` - generated Xcode iOS app project (`CloudScrobbleiOS.xcodeproj`)

## Environment variables (app)
Set these in the project-root `.env` before running the app target:

```bash
export SOUNDCLOUD_CLIENT_ID="..."
export SOUNDCLOUD_REDIRECT_URI="cloudscrobble://oauth"
export SOUNDCLOUD_TOKEN_BROKER_BASE_URL="http://localhost:8787"
export LASTFM_API_KEY="..."
export LASTFM_API_SECRET="..."
```

Do not put `SOUNDCLOUD_CLIENT_SECRET` in the app `.env` or Xcode scheme. It belongs only in `backend/.env`, because the iOS app talks to the local token broker instead of sending the SoundCloud secret from the app.

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
2. Backend token broker is running on the same URL as `SOUNDCLOUD_TOKEN_BROKER_BASE_URL`.
3. Xcode scheme env vars are synced (run `./scripts/sync_env_to_xcode_scheme.sh`).
4. iOS URL scheme `cloudscrobble` is present in `ios/project.yml` (generated into Info.plist).
5. In SoundCloud app settings (`https://soundcloud.com/you/apps`) click `Speichern` after entering redirect URI.
6. Validate broker credentials quickly:
   `curl -X POST http://127.0.0.1:8787/oauth/soundcloud/client-credentials -H 'Content-Type: application/json' -d '{}'`
   If this returns `{"error":"invalid_client"}`, your `SOUNDCLOUD_CLIENT_ID` / `SOUNDCLOUD_CLIENT_SECRET` pair is wrong.
7. If SoundCloud auth opens as a blank white page, disable system Auto Proxy / WPAD on macOS network settings and restart Simulator.
8. Fallback for testing:
   - `Use SoundCloud Public Mode` (real API token, `/me` library disabled)
   - `Use Demo Mode` (no SoundCloud API required; mock catalog + test stream)

## End-to-end checks
- Automated smoke: `./scripts/e2e_smoke.sh`
- Full manual E2E guide: `docs/E2E_TESTING.md`

## Notes
- The app intentionally does not implement offline download/storage.
- Playback flow prefers AAC HLS streams.
- For production/public release, keep OAuth secrets only in backend.
