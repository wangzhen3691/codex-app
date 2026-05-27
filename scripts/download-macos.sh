#!/usr/bin/env bash
set -euo pipefail

out_dir="${1:-dist}"
manifest_path="${2:-}"
mkdir -p "$out_dir"

arm_url=""
x64_url=""
arm_expected_size=""
x64_expected_size=""
curl_retry_args=(
  --retry 5
  --retry-delay 2
  --retry-max-time 900
  --connect-timeout 20
  --retry-all-errors
)

file_size() {
  local file="$1"
  if stat -f '%z' "$file" >/dev/null 2>&1; then
    stat -f '%z' "$file"
  else
    stat -c '%s' "$file"
  fi
}

validate_size() {
  local file="$1"
  local expected="$2"
  local actual

  if [[ -z "$expected" || "$expected" == "null" || "$expected" == "0" ]]; then
    return 0
  fi

  actual="$(file_size "$file")"
  if [[ "$actual" != "$expected" ]]; then
    echo "Downloaded size mismatch for $file: expected $expected bytes, got $actual bytes." >&2
    exit 1
  fi
}

download_file() {
  local label="$1"
  local url="$2"
  local output="$3"

  echo "Downloading $label: $url" >&2
  curl -fL "${curl_retry_args[@]}" \
    -o "$output" \
    "$url"
}

if [[ -n "$manifest_path" ]]; then
  if ! command -v jq >/dev/null 2>&1; then
    echo "jq is required when a probe manifest is provided." >&2
    exit 1
  fi

  if [[ ! -f "$manifest_path" ]]; then
    echo "Probe manifest not found: $manifest_path" >&2
    exit 1
  fi

  arm_url="$(jq -r '.sources.macos.arm64.url' "$manifest_path")"
  x64_url="$(jq -r '.sources.macos.x64.url' "$manifest_path")"
  arm_expected_size="$(jq -r '.sources.macos.arm64.contentLength' "$manifest_path")"
  x64_expected_size="$(jq -r '.sources.macos.x64.contentLength' "$manifest_path")"
else
  arm_url="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
  x64_url="https://persistent.oaistatic.com/codex-app-prod/Codex-latest-x64.dmg"
fi

download_file "macOS arm64 DMG" "$arm_url" "$out_dir/Codex-mac-arm64.dmg"
validate_size "$out_dir/Codex-mac-arm64.dmg" "$arm_expected_size"

download_file "macOS x64 DMG" "$x64_url" "$out_dir/Codex-mac-x64.dmg"
validate_size "$out_dir/Codex-mac-x64.dmg" "$x64_expected_size"

(
  cd "$out_dir"
  shasum -a 256 Codex-mac-arm64.dmg Codex-mac-x64.dmg > SHA256SUMS-macos.txt
)
