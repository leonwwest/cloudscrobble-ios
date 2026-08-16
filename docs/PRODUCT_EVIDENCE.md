# Product evidence

The screenshots in `docs/screenshots/` are captured from the real SwiftUI app
on an iPhone Simulator. The UI test switches the app to its local demo catalog,
so the capture does not require SoundCloud or Last.fm credentials and does not
contain private account data.

## Evidence map

| File | What it demonstrates |
| --- | --- |
| `demo/cloudscrobble-demo.mp4` | Credential-free onboarding, local demo feed, settings and scrobble diagnostics in the real iOS app |
| `demo/cloudscrobble-demo-poster.png` | Still preview used to link the product demo from the repository front page |
| `screenshots/demo-home.png` | Native navigation, connection state, personalized demo feed, mix and track cards |
| `screenshots/scrobble-diagnostics.png` | Demo-mode boundary, Last.fm readiness, pending queue count and local scrobble history |
| `../ios/CloudScrobbleiOSUITests/CloudScrobbleiOSUITests.swift` | Automated path that opens onboarding, activates Demo Preview and reaches diagnostics |

## Reproduce the capture

1. Run the UI test on an available iPhone Simulator:

   ```bash
   xcodebuild test \
     -project ios/CloudScrobbleiOS.xcodeproj \
     -scheme CloudScrobbleiOS \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
     -only-testing:CloudScrobbleiOSUITests \
     -resultBundlePath /tmp/cloudscrobble-evidence.xcresult \
     CODE_SIGNING_ALLOWED=NO
   ```

2. Export the named `XCTAttachment` screenshots:

   ```bash
   xcrun xcresulttool export attachments \
     --path /tmp/cloudscrobble-evidence.xcresult \
     --output-path /tmp/cloudscrobble-evidence-attachments
   ```

The committed captures were produced on 2026-08-15 with an iPhone 17 Pro
Simulator running iOS 26.5. The UI flow passed with no test failures.
