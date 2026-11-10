#!/usr/bin/env sh
# Builds the app and assembles the installable archives.
#
#   release/office-viewer-<version>.tar.gz   ← versioned
#   release/office-viewer.tar.gz             ← stable name for "latest" URLs
#   release/office-viewer-<version>.zip
#   release/office-viewer.zip
#
# Each archive contains a top-level `office-viewer/` folder, which is what
# scripts/install.sh (and admins) copy into $OC_DATA_DIR/web/assets/apps.
# tar.gz is the primary format because tar is available everywhere; zip is kept
# for the documented "unzip into the apps directory" flow.
set -eu

cd "$(dirname "$0")/.."

version=$(node -p "require('./package.json').version")
app_dir=release/office-viewer

pnpm build

rm -rf release
mkdir -p "$app_dir"
cp -a dist/. "$app_dir/"

(cd release && tar -czf "office-viewer-${version}.tar.gz" office-viewer)
(cd release && zip -qr "office-viewer-${version}.zip" office-viewer)
cp "release/office-viewer-${version}.tar.gz" release/office-viewer.tar.gz
cp "release/office-viewer-${version}.zip" release/office-viewer.zip

echo "created release/office-viewer.tar.gz and release/office-viewer.zip (v${version})"
