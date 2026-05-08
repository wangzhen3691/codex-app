#!/usr/bin/env bash
set -euo pipefail

probe_manifest="${1:-probe-manifest.json}"
macos_metadata="${2:-artifacts/codex-macos/macos-metadata.json}"
artifacts_dir="${3:-artifacts}"
r2_public_base_url="${4:-https://codexapp.agentsmirror.com}"
release_tag_override="${5:-}"

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

major_minor() {
  awk -F. '{ if (NF >= 2) print $1 "." $2; else print $0 }' <<<"$1"
}

sanitize_tag_part() {
  tr -cs 'A-Za-z0-9._-' '-' <<<"$1" | sed -E 's/^-+//; s/-+$//'
}

require find
require jq
require sha256sum

tmp_manifest="$(mktemp)"
cleanup() {
  rm -f "$tmp_manifest"
}
trap cleanup EXIT

if [[ ! -f "$probe_manifest" ]]; then
  echo "Missing probe manifest: $probe_manifest" >&2
  exit 1
fi

if [[ ! -f "$macos_metadata" ]]; then
  echo "Missing macOS metadata: $macos_metadata" >&2
  exit 1
fi

windows_package="$(jq -r '.sources.windows.packageMoniker' "$probe_manifest")"
windows_version="$(jq -r '.sources.windows.version // empty' "$probe_manifest")"
if [[ -z "$windows_version" || "$windows_version" == "null" ]]; then
  windows_version="$(sed -E 's/^OpenAI\.Codex_([^_]+)_.*/\1/' <<<"$windows_package")"
fi

mac_arm_version="$(jq -r '.macos.arm64.bundleShortVersion' "$macos_metadata")"
mac_arm_build="$(jq -r '.macos.arm64.bundleVersion' "$macos_metadata")"
mac_x64_version="$(jq -r '.macos.x64.bundleShortVersion' "$macos_metadata")"
mac_x64_build="$(jq -r '.macos.x64.bundleVersion' "$macos_metadata")"
mac_common_version="$(jq -r '.commonShortVersion // empty' "$macos_metadata")"
mac_common_build="$(jq -r '.commonBundleVersion // empty' "$macos_metadata")"

if [[ -z "$windows_version" || -z "$mac_arm_version" || -z "$mac_arm_build" || -z "$mac_x64_version" || -z "$mac_x64_build" ]]; then
  echo "Missing version metadata." >&2
  exit 1
fi

if [[ -n "$release_tag_override" ]]; then
  tag="$release_tag_override"
else
  windows_tag="$(sanitize_tag_part "$windows_version")"
  if [[ -n "$mac_common_version" && -n "$mac_common_build" ]]; then
    mac_tag="mac-$(sanitize_tag_part "$mac_common_version")-b$(sanitize_tag_part "$mac_common_build")"
  else
    mac_tag="mac-arm64-$(sanitize_tag_part "$mac_arm_version")-b$(sanitize_tag_part "$mac_arm_build")-x64-$(sanitize_tag_part "$mac_x64_version")-b$(sanitize_tag_part "$mac_x64_build")"
  fi
  tag="codex-app-win-${windows_tag}-${mac_tag}"
fi

windows_major_minor="$(major_minor "$windows_version")"
mac_major_minor="$(major_minor "${mac_common_version:-$mac_arm_version}")"
if [[ -n "$windows_major_minor" && "$windows_major_minor" == "$mac_major_minor" ]]; then
  title="Codex App Mirror $windows_major_minor"
else
  title="Codex App Mirror Windows $windows_major_minor macOS $mac_major_minor"
fi

jq \
  --slurpfile mac "$macos_metadata" \
  --arg windowsVersion "$windows_version" \
  '
  .schemaVersion = 2
  | .sources.windows.version = $windowsVersion
  | .sources.macos.arm64.bundleShortVersion = $mac[0].macos.arm64.bundleShortVersion
  | .sources.macos.arm64.bundleVersion = $mac[0].macos.arm64.bundleVersion
  | .sources.macos.arm64.bundleIdentifier = $mac[0].macos.arm64.bundleIdentifier
  | .sources.macos.arm64.minimumSystemVersion = $mac[0].macos.arm64.minimumSystemVersion
  | .sources.macos.arm64.sha256 = $mac[0].macos.arm64.sha256
  | .sources.macos.x64.bundleShortVersion = $mac[0].macos.x64.bundleShortVersion
  | .sources.macos.x64.bundleVersion = $mac[0].macos.x64.bundleVersion
  | .sources.macos.x64.bundleIdentifier = $mac[0].macos.x64.bundleIdentifier
  | .sources.macos.x64.minimumSystemVersion = $mac[0].macos.x64.minimumSystemVersion
  | .sources.macos.x64.sha256 = $mac[0].macos.x64.sha256
  | .derived = {
      windowsVersion: $windowsVersion,
      macosCommonShortVersion: $mac[0].commonShortVersion,
      macosCommonBundleVersion: $mac[0].commonBundleVersion,
      macosVersionsMatch: $mac[0].versionsMatch
    }
  ' "$probe_manifest" > "$tmp_manifest"
mv "$tmp_manifest" release-manifest.json

find "$artifacts_dir" -type f ! -name macos-metadata.json -print0 |
  sort -z |
  xargs -0 sha256sum > SHA256SUMS.txt
sha256sum release-manifest.json >> SHA256SUMS.txt

windows_content_length="$(jq -r '.sources.windows.contentLength' release-manifest.json)"
windows_etag="$(jq -r '.sources.windows.etag // empty' release-manifest.json)"
mac_arm_content_length="$(jq -r '.sources.macos.arm64.contentLength' release-manifest.json)"
mac_arm_etag="$(jq -r '.sources.macos.arm64.etag // empty' release-manifest.json)"
mac_x64_content_length="$(jq -r '.sources.macos.x64.contentLength' release-manifest.json)"
mac_x64_etag="$(jq -r '.sources.macos.x64.etag // empty' release-manifest.json)"

{
  echo "Official Codex desktop app installer mirror."
  echo
  echo "Detected versions:"
  echo "- Windows x64 MSIX: ${windows_version} (${windows_package}.Msix)"
  echo "- macOS Apple Silicon: ${mac_arm_version} (build ${mac_arm_build})"
  echo "- macOS Intel: ${mac_x64_version} (build ${mac_x64_build})"
  echo
  echo "R2 latest downloads:"
  echo "- Apple Silicon Mac: ${r2_public_base_url}/latest/mac-arm64"
  echo "- Intel Mac: ${r2_public_base_url}/latest/mac-intel"
  echo "- Windows x64: ${r2_public_base_url}/latest/win"
  echo "- Checksums: ${r2_public_base_url}/latest/checksums"
  echo "- Manifest: ${r2_public_base_url}/latest/manifest"
  echo
  echo "Source fingerprints:"
  echo "- Windows size: ${windows_content_length} bytes, ETag: ${windows_etag}"
  echo "- macOS Apple Silicon size: ${mac_arm_content_length} bytes, ETag: ${mac_arm_etag}"
  echo "- macOS Intel size: ${mac_x64_content_length} bytes, ETag: ${mac_x64_etag}"
  echo
  echo "Checksums are attached in SHA256SUMS.txt. The enriched probe manifest is attached in release-manifest.json."
} > release-notes.md

if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
  {
    echo "tag=$tag"
    echo "title=$title"
  } >> "$GITHUB_OUTPUT"
fi

echo "tag=$tag"
echo "title=$title"
