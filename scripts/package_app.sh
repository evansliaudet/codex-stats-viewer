#!/usr/bin/env bash
set -euo pipefail

swift build -c release --arch arm64 --arch x86_64

app_name="Codex Usage Bar.app"
dist_dir="dist"
app_dir="${dist_dir}/${app_name}"
contents_dir="${app_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"

rm -rf "${app_dir}"
mkdir -p "${macos_dir}" "${resources_dir}"

cp ".build/apple/Products/Release/CodexUsageBar" "${macos_dir}/CodexUsageBar"
cp "Resources/Info.plist" "${contents_dir}/Info.plist"
cp "codex.png" "${resources_dir}/codex.png"

chmod +x "${macos_dir}/CodexUsageBar"
xattr -cr "${app_dir}"
codesign --force --deep --sign - "${app_dir}"

echo "Built ${app_dir}"
