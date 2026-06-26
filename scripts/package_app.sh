#!/usr/bin/env bash
set -euo pipefail

swift build -c release --arch arm64 --arch x86_64

app_name="Codex Usage Bar.app"
dist_dir="dist"
app_dir="${dist_dir}/${app_name}"
contents_dir="${app_dir}/Contents"
macos_dir="${contents_dir}/MacOS"
resources_dir="${contents_dir}/Resources"
frameworks_dir="${contents_dir}/Frameworks"
sparkle_framework=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"

rm -rf "${app_dir}"
mkdir -p "${macos_dir}" "${resources_dir}" "${frameworks_dir}"

cp ".build/apple/Products/Release/CodexUsageBar" "${macos_dir}/CodexUsageBar"
cp "Resources/Info.plist" "${contents_dir}/Info.plist"
cp "codex.png" "${resources_dir}/codex.png"
cp -R "${sparkle_framework}" "${frameworks_dir}/Sparkle.framework"

chmod +x "${macos_dir}/CodexUsageBar"
install_name_tool -add_rpath "@executable_path/../Frameworks" "${macos_dir}/CodexUsageBar" 2>/dev/null || true
xattr -cr "${app_dir}"
codesign --force --deep --sign - "${app_dir}"

echo "Built ${app_dir}"
