# End-to-End Testing Guide

## 1) One-time setup

### SoundCloud app
1. Regenerate your `client_secret` if it was exposed.
2. In SoundCloud app settings, set redirect URI exactly to:
   - `cloudscrobble://oauth`
3. Keep these values ready:
   - `SOUNDCLOUD_CLIENT_ID`
   - `SOUNDCLOUD_CLIENT_SECRET`

### Last.fm API
1. Create an API account/app:
   - https://www.last.fm/api/account/create
2. Manage keys here:
   - https://www.last.fm/api/accounts
3. Keep ready:
   - `LASTFM_API_KEY`
   - `LASTFM_API_SECRET`

## 2) Configure env files

### `/backend/.env`
```env
ADDR=:8787
SOUNDCLOUD_CLIENT_ID=...
SOUNDCLOUD_CLIENT_SECRET=...
SOUNDCLOUD_TOKEN_URL=https://secure.soundcloud.com/oauth/token
ALLOWED_ORIGIN=*
```

### root run env
Use values from `.env.example` in project root:
```env
SOUNDCLOUD_CLIENT_ID=...
SOUNDCLOUD_REDIRECT_URI=cloudscrobble://oauth
SOUNDCLOUD_TOKEN_BROKER_BASE_URL=http://localhost:8787
LASTFM_API_KEY=...
LASTFM_API_SECRET=...
```

## 3) Automated smoke checks

Run:
```bash
./scripts/e2e_smoke.sh
```

This validates:
- Swift core build + tests
- Go backend build/tests
- Token broker health and OAuth exchange/refresh path (mocked SoundCloud token upstream)

## 4) Real API run (manual E2E)

### Start token broker
```bash
cd backend
export $(grep -v '^#' .env | xargs)
go run .
```

### Start app
Preferred: run the iOS Xcode target.

```bash
open ios/CloudScrobbleiOS.xcodeproj
```

Then in Xcode set env vars from root `.env` under:
- Scheme > Run > Arguments > Environment Variables

One-click helper:
```bash
./scripts/open_ios_with_env.sh
```
This command syncs `.env` into `CloudScrobbleiOS` scheme env vars and opens the project.

Alternative (desktop SwiftPM executable):
- `swift run CloudScrobbleApp`

## 5) Manual acceptance checklist

1. Connect SoundCloud in app.
   - If login stays white, use `Use SoundCloud Public Mode` to continue testing search/playback.
2. Search tracks.
3. Open public profile + playlists.
4. Play track (AVPlayer starts HLS stream).
5. Connect Last.fm.
6. Start playback and verify debug status shows `Now Playing sent`.
7. Keep playing past scrobble threshold (`min(50%, 240s)`, and >30s track).
8. Verify debug status shows scrobble sent or queued.
9. Simulate offline (disable network), play past threshold, verify `Scrobble queued`.
10. Re-enable network and reconnect Last.fm, queue should flush automatically.

## 6) Verify at Last.fm

Check your recent tracks on profile page. You should see:
- current track as Now Playing
- scrobbled tracks after threshold

## 7) Common issues

- `SoundCloud login failed`: redirect URI mismatch between app and SoundCloud settings.
- `401` on SoundCloud API: expired token, broker refresh path, or wrong credentials.
- `Last.fm error 9`: invalid/missing Last.fm session; reconnect Last.fm.
- No scrobble for short track: tracks under 30s are intentionally not scrobbled.
