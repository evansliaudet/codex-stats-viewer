#!/usr/bin/env bash
set -euo pipefail

swift build -c release

app_name="Codex Usage Bar.app"
dist_dir="dist"
app_dir="${dist_dir}/${app_name}"
contents_dir="${app_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"

rm -rf "${app_dir}"
mkdir -p "${macos_dir}" "${resources_dir}"

cp ".build/release/CodexUsageBar" "${macos_dir}/CodexUsageBar"
cp "Resources/Info.plist" "${contents_dir}/Info.plist"
cp "codex.png" "${resources_dir}/codex.png"

chmod +x "${macos_dir}/CodexUsageBar"

echo "Built ${app_dir}"
