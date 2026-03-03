#!/bin/bash
# Build and package ClawHome for Apple ARM64 with code signing.
# Certificate: F44ZS9HT2P
# See launch.sh for dev build/run flow.
set -e
cd "$(dirname "$0")"

ARCH=$(uname -m)
if [ "$ARCH" != "arm64" ]; then
  echo "[build] ERROR: This script builds for Apple ARM64 only. Current arch: $ARCH"
  exit 1
fi

echo "[build] Building ClawHome for macOS arm64..."

echo "[build] Installing dependencies..."
npm install

echo "[build] Building Electron app..."
npm run electron:build

echo "[build] Building ClawVMManager and ClawVMRunner (release)..."
./scripts/build-claw-vm.sh

# Verify ClawVM binaries exist before packaging
for f in dist-electron/resources/ClawVMManager dist-electron/resources/ClawVMRunner dist-electron/resources/ClawVM; do
  if [ ! -f "$f" ]; then
    echo "[build] ERROR: Missing $f - build:clawvm must run before packaging"
    exit 1
  fi
done
echo "[build] ClawVM binaries verified in dist-electron/resources/"

echo "[build] Packaging with electron-builder (arm64, code signing)..."
CSC_NAME="F44ZS9HT2P" \
  npx electron-builder --mac --arm64 --config electron-builder.json5

VERSION=$(node -p "require('./package.json').version")
APP_RESOURCES="release/$VERSION/mac-arm64/ClawHome.app/Contents/Resources"
if [ -d "$APP_RESOURCES" ]; then
  echo "[build] Verifying Resources..."
  for f in ClawVMManager ClawVMRunner ClawVM; do
    if [ ! -f "$APP_RESOURCES/$f" ]; then
      echo "[build] WARNING: $f not found in built app at $APP_RESOURCES/"
    else
      echo "[build]   $f OK"
    fi
  done
fi
echo "[build] Done. Output in release/$VERSION/"
