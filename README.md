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
  - Search tracks/playlists/users
  - Open public user profiles
  - Load and play playlist tracks
  - My library from `/me` endpoints
- `backend/` (Go token broker)
  - `POST /oauth/soundcloud/exchange`
  - `POST /oauth/soundcloud/refresh`
  - `GET /healthz`

## Repo structure
- `/Sources/CloudScrobbleCore` - protocols, models, services
- `/Sources/CloudScrobbleApp` - SwiftUI app and view models
- `/Tests/CloudScrobbleCoreTests` - unit tests for core logic
- `/backend` - SoundCloud token broker backend
- `/ios` - generated Xcode iOS app project (`CloudScrobbleiOS.xcodeproj`)

## Environment variables (app)
Set these before running the app target:

```bash
export SOUNDCLOUD_CLIENT_ID="..."
export SOUNDCLOUD_REDIRECT_URI="cloudscrobble://oauth"
export SOUNDCLOUD_TOKEN_BROKER_BASE_URL="http://localhost:8787"
export LASTFM_API_KEY="..."
export LASTFM_API_SECRET="..."
```

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

## SoundCloud OAuth checklist
If "Connect SoundCloud" fails in-app, verify:
1. SoundCloud app redirect URI is exactly `cloudscrobble://oauth`.
2. Backend token broker is running on the same URL as `SOUNDCLOUD_TOKEN_BROKER_BASE_URL`.
3. Xcode scheme env vars are synced (run `./scripts/sync_env_to_xcode_scheme.sh`).
4. iOS URL scheme `cloudscrobble` is present in `ios/project.yml` (generated into Info.plist).
5. If SoundCloud auth opens as a blank white page, disable system Auto Proxy / WPAD on macOS network settings and restart Simulator.
6. Current app flow opens SoundCloud login in the system browser and returns to app via `cloudscrobble://oauth`.

## End-to-end checks
- Automated smoke: `./scripts/e2e_smoke.sh`
- Full manual E2E guide: `docs/E2E_TESTING.md`

## Notes
- The app intentionally does not implement offline download/storage.
- Playback flow prefers AAC HLS streams.
- For production/public release, keep OAuth secrets only in backend.
