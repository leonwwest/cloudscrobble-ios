#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_PATH="$ROOT_DIR/ios/CloudScrobbleiOS.xcodeproj"

"$ROOT_DIR/scripts/sync_env_to_xcode_scheme.sh" "$ROOT_DIR/.env"
open "$PROJECT_PATH"

echo "Opened Xcode project with synced scheme env vars."
