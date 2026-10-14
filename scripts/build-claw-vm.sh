#!/bin/bash
set -e
cd "$(dirname "$0")/.."
VM_DIR="claw-vm"
IDENTITY="F44ZS9HT2P"

echo "[ClawHome] Building ClawVMManager and ClawVMRunner (release)..."
cd "$VM_DIR"
swift build -c release
BIN=$(swift build -c release --show-bin-path)
MANAGER="$BIN/ClawVMManager"
RUNNER="$BIN/ClawVMRunner"

if [ ! -f "$MANAGER" ] || [ ! -f "$RUNNER" ]; then
  echo "[ClawHome] ClawVMManager or ClawVMRunner not found"
  exit 1
fi

# Sign with Developer ID and virtualization entitlement (same as ai-employee build-houston-vm.sh)
ENTITLEMENTS="ClawVM.entitlements"
if [ -f "$ENTITLEMENTS" ]; then
  echo "[ClawHome] Signing binaries with Developer ID and virtualization entitlement..."
  codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$MANAGER" || { echo "[ClawHome] ERROR: Failed to sign ClawVMManager"; exit 1; }
  codesign --force --sign "$IDENTITY" --entitlements "$ENTITLEMENTS" "$RUNNER" || { echo "[ClawHome] ERROR: Failed to sign ClawVMRunner"; exit 1; }
fi

cd ..
mkdir -p dist-electron/resources
CLAWHOME_SWIFT_CONFIG=release ./scripts/copy-claw-vm.sh
echo "[ClawHome] ClawVMManager and ClawVMRunner built and copied"
