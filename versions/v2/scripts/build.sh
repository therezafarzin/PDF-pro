#!/bin/bash
# Build PDF Study for Apple Silicon. Usage: scripts/build.sh [test|release|run]
set -euo pipefail
cd "$(dirname "$0")/.."

command -v xcodebuild >/dev/null || { echo "Xcode is required (App Store). Then run: sudo xcode-select -s /Applications/Xcode.app"; exit 1; }
if ! command -v xcodegen >/dev/null; then
  command -v brew >/dev/null || { echo "Install Homebrew (https://brew.sh) or XcodeGen manually."; exit 1; }
  brew install xcodegen
fi

xcodegen generate

case "${1:-release}" in
  test)
    xcodebuild test -project PDFStudy.xcodeproj -scheme PDFStudy -destination 'platform=macOS,arch=arm64' | xcpretty 2>/dev/null || \
    xcodebuild test -project PDFStudy.xcodeproj -scheme PDFStudy -destination 'platform=macOS,arch=arm64'
    ;;
  run)
    xcodebuild -project PDFStudy.xcodeproj -scheme PDFStudy -configuration Debug -derivedDataPath build build
    open "build/Build/Products/Debug/PDF Study.app"
    ;;
  release)
    xcodebuild -project PDFStudy.xcodeproj -scheme PDFStudy -configuration Release -derivedDataPath build \
      CODE_SIGN_IDENTITY="-" CODE_SIGNING_ALLOWED=YES build
    mkdir -p dist && rm -rf "dist/PDF Study.app"
    cp -R "build/Build/Products/Release/PDF Study.app" dist/
    echo "Built: $(pwd)/dist/PDF Study.app"
    echo "Copy it to /Applications. First launch: right-click > Open (ad-hoc signed, not notarized)."
    ;;
esac
