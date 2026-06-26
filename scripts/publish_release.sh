#!/usr/bin/env bash
set -euo pipefail

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: scripts/publish_release.sh <version> [release-notes]" >&2
  exit 1
fi

version="$1"
release_notes="${2:-Release ${version}}"
repo="evansliaudet/codex-stats-viewer"
tag="v${version}"
zip_name="CodexUsageBar-${version}.zip"
zip_path="releases/${zip_name}"
appcast_url_prefix="https://raw.githubusercontent.com/${repo}/main/releases/"
sparkle_account="codex-usage-bar"

require_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

require_command git
require_command gh
require_command plutil

current_branch="$(git branch --show-current)"
if [[ "${current_branch}" != "main" ]]; then
  echo "Release must be run from main. Current branch: ${current_branch}" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "GitHub CLI is not authenticated. Run: gh auth login" >&2
  exit 1
fi

if git rev-parse "${tag}" >/dev/null 2>&1 || gh release view "${tag}" --repo "${repo}" >/dev/null 2>&1; then
  echo "Release ${tag} already exists." >&2
  exit 1
fi

current_version="$(plutil -extract CFBundleShortVersionString raw Resources/Info.plist)"
current_build="$(plutil -extract CFBundleVersion raw Resources/Info.plist)"
if [[ ! "${current_build}" =~ ^[0-9]+$ ]]; then
  echo "CFBundleVersion must be numeric. Current value: ${current_build}" >&2
  exit 1
fi

latest_released_build="$(
  if [[ -f releases/appcast.xml ]]; then
    /usr/bin/grep -o '<sparkle:version>[0-9][0-9]*</sparkle:version>' releases/appcast.xml \
      | /usr/bin/sed -E 's/.*>([0-9]+)<.*/\1/' \
      | /usr/bin/sort -n \
      | /usr/bin/tail -n 1
  fi
)"
latest_released_build="${latest_released_build:-0}"

if [[ "${current_version}" == "${version}" && "${current_build}" -gt "${latest_released_build}" ]]; then
  next_build="${current_build}"
else
  next_build="$((current_build + 1))"
fi

plutil -replace CFBundleShortVersionString -string "${version}" Resources/Info.plist
plutil -replace CFBundleVersion -string "${next_build}" Resources/Info.plist

scripts/release_zip.sh

mkdir -p releases
cp "dist/Codex Usage Bar.zip" "${zip_path}"

.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
  --account "${sparkle_account}" \
  --download-url-prefix "${appcast_url_prefix}" \
  releases

git add -A

if ! git diff --cached --quiet; then
  git commit -m "Release ${version}"
fi

git tag "${tag}"
git push origin main
git push origin "${tag}"

gh release create "${tag}" \
  "dist/Codex Usage Bar.zip#Codex Usage Bar.zip" \
  "${zip_path}#${zip_name}" \
  --repo "${repo}" \
  --title "Codex Usage Bar ${version}" \
  --notes "${release_notes}"

echo "Published ${tag}"
