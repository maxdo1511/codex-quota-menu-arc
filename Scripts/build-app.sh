#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

swift build -c release

app_dir="$project_dir/dist/CodexQuotaMenu.app"
mkdir -p "$app_dir/Contents/MacOS"
mkdir -p "$app_dir/Contents/Resources"
cp "Resources/Info.plist" "$app_dir/Contents/Info.plist"
cp "Resources/AppIcon.icns" "$app_dir/Contents/Resources/AppIcon.icns"
cp ".build/release/CodexQuotaMenu" "$app_dir/Contents/MacOS/CodexQuotaMenu"
signing_identity="${CODE_SIGN_IDENTITY:--}"
codesign --force --sign "$signing_identity" --identifier local.codex.quota-menu "$app_dir"

echo "Built $app_dir"
