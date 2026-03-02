#!/bin/bash
set -e
cd "$(dirname "$0")/.."
VM_DIR="claw-vm"
IDENTITY="F44ZS9HT2P"

echo "[ClawHome] Building ClawVMManager and ClawVMRunner (release)..."
cd "$VM_DIR"
swift build -c release

ARCH=$(uname -m)
if [ "$ARCH" = "arm64" ]; then
  MANAGER=".build/arm64-apple-macosx/release/ClawVMManager"
  RUNNER=".build/arm64-apple-macosx/release/ClawVMRunner"
else
  MANAGER=".build/x86_64-apple-macosx/release/ClawVMManager"
  RUNNER=".build/x86_64-apple-macosx/release/ClawVMRunner"
fi

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
./scripts/copy-claw-vm.sh
echo "[ClawHome] ClawVMManager and ClawVMRunner built and copied"
