#!/usr/bin/env bash
set -euo pipefail

scripts/package_app.sh
ditto --norsrc --noextattr -c -k --keepParent "dist/Codex Usage Bar.app" "dist/Codex Usage Bar.zip"

echo "Built dist/Codex Usage Bar.zip"
