/**
 * Before electron-builder signs the app, sign nested binaries with Developer ID.
 * Nested binaries must be signed first; signing them in afterSign invalidates the main app signature.
 * ClawVM binaries need com.apple.security.virtualization for Apple's Virtualization framework.
 */
const { execFileSync } = require("child_process");
const path = require("path");
const fs = require("fs");

const IDENTITY = "F44ZS9HT2P";

function signBinary(binaryPath, entitlementsPath = null) {
  if (!fs.existsSync(binaryPath)) {
    console.warn("[afterPack] Binary not found:", binaryPath);
    return;
  }
  const args = ["-f", "-s", IDENTITY, "--options", "runtime"];
  if (entitlementsPath && fs.existsSync(entitlementsPath)) {
    args.push("--entitlements", entitlementsPath);
  }
  args.push(binaryPath);
  execFileSync("codesign", args, { stdio: "inherit" });
}

module.exports = async function (context) {
  if (context.electronPlatformName !== "darwin") return;

  const resourcesDir = context.packager.getMacOsResourcesDir(context.appOutDir);
  const projectDir = context.packager.projectDir;
  // Use VM-specific entitlements (virtualization only) - same as ai-employee HoustonVM.entitlements
  const clawVmEntitlements = path.join(projectDir, "claw-vm", "ClawVM.entitlements");

  const binaries = ["ClawVMManager", "ClawVMRunner", "ClawVM"];
  for (const name of binaries) {
    const binaryPath = path.join(resourcesDir, name);
    if (fs.existsSync(binaryPath)) {
      console.log("[afterPack] Signing", name, "with virtualization entitlement...");
      signBinary(binaryPath, clawVmEntitlements);
      console.log("[afterPack]", name, "signed");
    }
  }
};
