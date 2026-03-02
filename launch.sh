#!/bin/bash
set -e
cd "$(dirname "$0")"

# Build and run ClawHome
echo "Building ClawHome..."
npm install

# Build ClawVM Manager + Runner (copy-claw-vm.sh copies to dist-electron/resources)
echo "Building ClawVM Manager and Runner..."
(cd claw-vm && swift build)

npm run electron:build

# Copy ClawVMManager and ClawVMRunner after electron:build so they aren't wiped
./scripts/copy-claw-vm.sh

echo "Launching ClawHome..."
exec npx electron .
