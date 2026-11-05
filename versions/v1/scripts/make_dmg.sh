#!/bin/bash
# Creates dist/PDF-Study.dmg from dist/PDF Study.app (run scripts/build.sh first).
set -euo pipefail
cd "$(dirname "$0")/.."
[ -d "dist/PDF Study.app" ] || { echo "Run scripts/build.sh first."; exit 1; }
rm -rf dist/dmg-root dist/PDF-Study.dmg
mkdir -p dist/dmg-root
cp -R "dist/PDF Study.app" dist/dmg-root/
ln -s /Applications dist/dmg-root/Applications
hdiutil create -volname "PDF Study" -srcfolder dist/dmg-root -ov -format UDZO dist/PDF-Study.dmg
rm -rf dist/dmg-root
echo "Created dist/PDF-Study.dmg"
