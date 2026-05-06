#!/usr/bin/env bash
set -euo pipefail

product_id="9PLM9XGG6VKS"
architecture="x64"
arm_url="https://persistent.oaistatic.com/codex-app-prod/Codex.dmg"
x64_url="https://persistent.oaistatic.com/codex-app-prod/Codex-latest-x64.dmg"
force_release="${FORCE_RELEASE:-false}"
release_tag_input="${RELEASE_TAG:-}"
manifest_path="${MANIFEST_PATH:-release-manifest.json}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

header_value() {
  local url="$1"
  local name="$2"
  curl -fsSI -L --retry 3 --retry-delay 2 "$url" |
    tr -d '\r' |
    awk -v wanted="$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]')" '
      BEGIN { value = "" }
      {
        line = $0
        lower = tolower(line)
        if (index(lower, wanted ":") == 1) {
          sub("^[^:]+:[[:space:]]*", "", line)
          value = line
        }
      }
      END { print value }
    '
}

json_number() {
  local value="$1"
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s' "$value"
  else
    printf '0'
  fi
}

asset_size() {
  local assets_json="$1"
  local asset_name="$2"
  jq -r --arg name "$asset_name" '.[] | select(.name == $name) | .size' <<<"$assets_json" | head -n 1
}

manifest_key() {
  jq -S -c '{
    windows: {
      packageMoniker: .sources.windows.packageMoniker,
      contentLength: .sources.windows.contentLength
    },
    macos: {
      arm64: {
        contentLength: .sources.macos.arm64.contentLength,
        etag: .sources.macos.arm64.etag,
        lastModified: .sources.macos.arm64.lastModified
      },
      x64: {
        contentLength: .sources.macos.x64.contentLength,
        etag: .sources.macos.x64.etag,
        lastModified: .sources.macos.x64.lastModified
      }
    }
  }' "$1"
}

require curl
require dotnet
require gh
require jq

link_line="$(dotnet run --project scripts/store-link -- "$product_id" "$architecture" |
  awk '/^OpenAI\.Codex_/ { print; exit }')"

if [[ -z "$link_line" ]]; then
  echo "No Microsoft Store package link was resolved." >&2
  exit 1
fi

windows_package="${link_line%%$'\t'*}"
windows_url="${link_line#*$'\t'}"
windows_content_length="$(header_value "$windows_url" "content-length")"
windows_last_modified="$(header_value "$windows_url" "last-modified")"
windows_etag="$(header_value "$windows_url" "etag")"

arm_content_length="$(header_value "$arm_url" "content-length")"
arm_last_modified="$(header_value "$arm_url" "last-modified")"
arm_etag="$(header_value "$arm_url" "etag")"

x64_content_length="$(header_value "$x64_url" "content-length")"
x64_last_modified="$(header_value "$x64_url" "last-modified")"
x64_etag="$(header_value "$x64_url" "etag")"

jq -n \
  --arg generatedAt "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --arg productId "$product_id" \
  --arg architecture "$architecture" \
  --arg windowsPackage "$windows_package" \
  --arg windowsUrlHost "$(printf '%s' "$windows_url" | sed -E 's#^(https?://[^/]+).*#\1#')" \
  --argjson windowsContentLength "$(json_number "$windows_content_length")" \
  --arg windowsLastModified "$windows_last_modified" \
  --arg windowsEtag "$windows_etag" \
  --arg armUrl "$arm_url" \
  --argjson armContentLength "$(json_number "$arm_content_length")" \
  --arg armLastModified "$arm_last_modified" \
  --arg armEtag "$arm_etag" \
  --arg x64Url "$x64_url" \
  --argjson x64ContentLength "$(json_number "$x64_content_length")" \
  --arg x64LastModified "$x64_last_modified" \
  --arg x64Etag "$x64_etag" \
  '{
    schemaVersion: 1,
    generatedAt: $generatedAt,
    sources: {
      windows: {
        productId: $productId,
        architecture: $architecture,
        packageMoniker: $windowsPackage,
        urlHost: $windowsUrlHost,
        contentLength: $windowsContentLength,
        lastModified: $windowsLastModified,
        etag: $windowsEtag
      },
      macos: {
        arm64: {
          url: $armUrl,
          contentLength: $armContentLength,
          lastModified: $armLastModified,
          etag: $armEtag
        },
        x64: {
          url: $x64Url,
          contentLength: $x64ContentLength,
          lastModified: $x64LastModified,
          etag: $x64Etag
        }
      }
    }
  }' > "$manifest_path"

should_release="true"
skip_reason=""
latest_tag=""
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

if [[ "$force_release" == "true" ]]; then
  skip_reason="force_release=true"
else
  latest_tag="$(gh release list --limit 1 --exclude-drafts --exclude-pre-releases --json tagName --jq '.[0].tagName // ""')"
  if [[ -n "$latest_tag" ]]; then
    if gh release download "$latest_tag" -p release-manifest.json -D "$tmp_dir" --clobber >/dev/null 2>&1; then
      current_key="$(manifest_key "$manifest_path")"
      previous_key="$(manifest_key "$tmp_dir/release-manifest.json")"
      if [[ "$current_key" == "$previous_key" ]]; then
        should_release="false"
        skip_reason="manifest matches latest release $latest_tag"
      fi
    else
      assets_json="$(gh release view "$latest_tag" --json assets --jq '.assets')"
      windows_asset_size="$(asset_size "$assets_json" "$windows_package.Msix")"
      arm_asset_size="$(asset_size "$assets_json" "Codex-mac-arm64.dmg")"
      x64_asset_size="$(asset_size "$assets_json" "Codex-mac-x64.dmg")"
      if [[ "$windows_asset_size" == "$windows_content_length" &&
            "$arm_asset_size" == "$arm_content_length" &&
            "$x64_asset_size" == "$x64_content_length" ]]; then
        should_release="false"
        skip_reason="asset names and sizes match latest release $latest_tag"
      fi
    fi
  fi
fi

if [[ -n "$release_tag_input" ]]; then
  release_tag="$release_tag_input"
else
  release_tag="codex-app-$(date -u +'%Y%m%d-%H%M%S')"
fi

version_summary="windows=$windows_package; mac-arm64=$arm_etag/$arm_content_length; mac-x64=$x64_etag/$x64_content_length"

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "should_release=$should_release"
    echo "release_tag=$release_tag"
    echo "latest_tag=$latest_tag"
    echo "skip_reason=$skip_reason"
    echo "version_summary=$version_summary"
    echo "manifest<<EOF"
    cat "$manifest_path"
    echo "EOF"
  } >> "$GITHUB_OUTPUT"
fi

echo "should_release=$should_release"
echo "release_tag=$release_tag"
echo "latest_tag=$latest_tag"
echo "skip_reason=$skip_reason"
echo "version_summary=$version_summary"
