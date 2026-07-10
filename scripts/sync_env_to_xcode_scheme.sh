#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ENV_FILE="${1:-$ROOT_DIR/.env}"
PROJECT_DIR="$ROOT_DIR/ios/CloudScrobbleiOS.xcodeproj"
SHARED_SCHEME_FILE="$PROJECT_DIR/xcshareddata/xcschemes/CloudScrobbleiOS.xcscheme"
USER_SCHEME_DIR="$PROJECT_DIR/xcuserdata/${USER:-local}.xcuserdatad/xcschemes"
SCHEME_FILE="${2:-$USER_SCHEME_DIR/CloudScrobbleiOS.xcscheme}"

if pgrep -x "Xcode" >/dev/null 2>&1; then
  echo "Xcode is running. Please close Xcode before syncing env vars, otherwise scheme changes may be overwritten." >&2
  exit 1
fi

if [[ ! -f "$ENV_FILE" ]]; then
  echo "Missing env file: $ENV_FILE" >&2
  exit 1
fi

if [[ ! -f "$SCHEME_FILE" ]]; then
  if [[ ! -f "$SHARED_SCHEME_FILE" ]]; then
    echo "Missing shared scheme template: $SHARED_SCHEME_FILE" >&2
    exit 1
  fi
  mkdir -p "$(dirname "$SCHEME_FILE")"
  cp "$SHARED_SCHEME_FILE" "$SCHEME_FILE"
fi

python3 - "$ENV_FILE" "$SCHEME_FILE" <<'PY'
import os
import re
import sys
import xml.etree.ElementTree as ET

env_path, scheme_path = sys.argv[1], sys.argv[2]
allowed_keys = {
    "SOUNDCLOUD_CLIENT_ID",
    "SOUNDCLOUD_REDIRECT_URI",
    "SOUNDCLOUD_TOKEN_BROKER_BASE_URL",
    "CS_APP_API_KEY",
}

parsed = {}
with open(env_path, "r", encoding="utf-8") as fh:
    for raw in fh:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue

        if line.startswith("export "):
            line = line[len("export "):].strip()

        if "=" not in line:
            continue

        key, value = line.split("=", 1)
        key = key.strip()
        value = value.strip()

        if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", key):
            continue

        if len(value) >= 2 and ((value[0] == '"' and value[-1] == '"') or (value[0] == "'" and value[-1] == "'")):
            value = value[1:-1]

        if key in allowed_keys:
            parsed[key] = value

if not parsed:
    raise SystemExit(f"No valid app key=value pairs found in {env_path}")

tree = ET.parse(scheme_path)
root = tree.getroot()
launch_action = root.find("LaunchAction")
if launch_action is None:
    raise SystemExit("LaunchAction missing in scheme")

env_vars = launch_action.find("EnvironmentVariables")
if env_vars is None:
    env_vars = ET.SubElement(launch_action, "EnvironmentVariables")

for child in list(env_vars):
    env_vars.remove(child)

for key in sorted(parsed.keys()):
    ET.SubElement(env_vars, "EnvironmentVariable", key=key, value=parsed[key], isEnabled="YES")

tree.write(scheme_path, encoding="UTF-8", xml_declaration=True)
print(f"Synced {len(parsed)} app vars from {env_path} -> {scheme_path}")
PY
