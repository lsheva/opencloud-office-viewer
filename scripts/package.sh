#!/usr/bin/env sh
# Builds the app and assembles the installable archive.
#
#   release/office-viewer-<version>.zip   ← versioned asset
#   release/office-viewer.zip             ← stable name for "latest" URLs
#
# The zip contains a top-level `office-viewer/` folder, which is what
# scripts/install.sh (and admins) copy into $OC_DATA_DIR/web/assets/apps.
set -eu

cd "$(dirname "$0")/.."

version=$(node -p "require('./package.json').version")
app_dir=release/office-viewer

pnpm build

rm -rf release
mkdir -p "$app_dir"
cp -a dist/. "$app_dir/"

(cd release && zip -qr "office-viewer-${version}.zip" office-viewer)
cp "release/office-viewer-${version}.zip" release/office-viewer.zip

echo "created release/office-viewer-${version}.zip and release/office-viewer.zip"
