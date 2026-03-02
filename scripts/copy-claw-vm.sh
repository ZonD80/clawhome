#!/bin/bash
set -e
cd "$(dirname "$0")/.."

ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  MANAGER="claw-vm/.build/arm64-apple-macosx/debug/ClawVMManager"
  [ -f "$MANAGER" ] || MANAGER="claw-vm/.build/arm64-apple-macosx/release/ClawVMManager"
  RUNNER="claw-vm/.build/arm64-apple-macosx/debug/ClawVMRunner"
  [ -f "$RUNNER" ] || RUNNER="claw-vm/.build/arm64-apple-macosx/release/ClawVMRunner"
else
  MANAGER="claw-vm/.build/x86_64-apple-macosx/debug/ClawVMManager"
  [ -f "$MANAGER" ] || MANAGER="claw-vm/.build/x86_64-apple-macosx/release/ClawVMManager"
  RUNNER="claw-vm/.build/x86_64-apple-macosx/debug/ClawVMRunner"
  [ -f "$RUNNER" ] || RUNNER="claw-vm/.build/x86_64-apple-macosx/release/ClawVMRunner"
fi

if [ ! -f "$MANAGER" ]; then
  echo "[ClawHome] ClawVMManager not found at $MANAGER, run: cd claw-vm && swift build"
  exit 1
fi
if [ ! -f "$RUNNER" ]; then
  echo "[ClawHome] ClawVMRunner not found at $RUNNER, run: cd claw-vm && swift build"
  exit 1
fi

ENTITLEMENTS="claw-vm/ClawVM.entitlements"
if [ ! -f "$ENTITLEMENTS" ]; then
  echo "[ClawHome] ERROR: Entitlements file not found at $ENTITLEMENTS"
  exit 1
fi

mkdir -p dist-electron/resources
cp "$MANAGER" dist-electron/resources/ClawVMManager
cp "$RUNNER" dist-electron/resources/ClawVMRunner
cp "$MANAGER" dist-electron/resources/ClawVM

# Sign with Developer ID (afterPack will re-sign in app bundle; this keeps dist-electron consistent)
IDENTITY="F44ZS9HT2P"
echo "[ClawHome] Signing with Developer ID and virtualization entitlement..."
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" dist-electron/resources/ClawVMManager || { echo "[ClawHome] ERROR: Failed to sign ClawVMManager"; exit 1; }
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" dist-electron/resources/ClawVMRunner || { echo "[ClawHome] ERROR: Failed to sign ClawVMRunner"; exit 1; }
codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" dist-electron/resources/ClawVM || { echo "[ClawHome] ERROR: Failed to sign ClawVM"; exit 1; }

# Verify Runner has virtualization entitlement (required for VM display)
if ! codesign -d --entitlements - dist-electron/resources/ClawVMRunner 2>/dev/null | grep -q "com.apple.security.virtualization"; then
  echo "[ClawHome] WARNING: ClawVMRunner may not have virtualization entitlement - VM display may be black"
fi
echo "[ClawHome] Copied and signed ClawVMManager, ClawVMRunner, ClawVM"
