#!/bin/zsh
set -euo pipefail

project_dir=${0:A:h:h}
cd "$project_dir"

version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Resources/Info.plist)
archive_dir="$project_dir/release"
archive="$archive_dir/CodexQuotaMenu-${version}-macos.zip"

if [[ -e "$archive" ]]; then
  echo "Refusing to overwrite existing archive: $archive" >&2
  exit 1
fi

./Scripts/build-app.sh
mkdir -p "$archive_dir"
ditto -c -k --sequesterRsrc --keepParent dist/CodexQuotaMenu.app "$archive"
shasum -a 256 "$archive"
