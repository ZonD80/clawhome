#!/usr/bin/env bash
# Build ClawHome for Apple Silicon, notarize the DMG, and optionally publish
# a GitHub release. Combines build.sh and notarize_and_staple.sh.
#
# Usage:
#   ./release.sh                 # build when newer than GitHub, then notarize
#   ./release.sh --no-notarize   # build artifacts only
#   ./release.sh --release       # build what changed, notarize, publish
#   ./release.sh --release-only  # upload the existing DMG (no rebuild)
#   ./release.sh --force         # rebuild even if GitHub already has this version
#
# Credentials (repo-root .env):
#   APPLE_ID
#   APPLE_APP_SPECIFIC_PASSWORD  (APP_PASSWORD is also accepted)
#   APPLE_TEAM_ID                (optional; default F44ZS9HT2P)
#   CODESIGN_IDENTITY            (optional; default F44ZS9HT2P)
#   RELEASE_REPO                 (optional; default ZonD80/clawhome)
#   RELEASE_GH_USER              (optional; default ZonD80)
#
# Artifact: release/<version>/ClawHome-Mac-<version>-arm64.dmg

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$REPO_ROOT"

DEFAULT_TEAM_ID="F44ZS9HT2P"
DEFAULT_CODESIGN_IDENTITY="F44ZS9HT2P"
DEFAULT_RELEASE_REPO="ZonD80/clawhome"
DEFAULT_RELEASE_GH_USER="ZonD80"

NOTARIZE=1
DO_RELEASE=0
RELEASE_ONLY=0
FORCE=0
PUBLISHED=0
PUB_VERSION=""

usage() {
  cat <<'EOF'
Build ClawHome (arm64 DMG), notarize and staple it, and optionally publish
a GitHub release.

Usage:
  ./release.sh [options]

Compares package.json to the latest GitHub release tag and builds only when
the local version is newer.

Options:
  --notarize       Submit the DMG to Apple and staple it (default)
  --no-notarize    Skip notarization and stapling
  --release        Publish to GitHub after a successful build
                   (implies notarization unless --no-notarize is also passed)
  --release-only   Skip build and notarize; upload release/<version>/ClawHome-Mac-<version>-arm64.dmg
  --force          Rebuild and replace the GitHub release even if that version is already published
  -h, --help       Show this help

Environment (.env at the repo root):
  APPLE_ID                     Apple ID email (required for notarization)
  APPLE_APP_SPECIFIC_PASSWORD  App-specific password (required for notarization)
  APP_PASSWORD                 Accepted in place of APPLE_APP_SPECIFIC_PASSWORD
  APPLE_TEAM_ID                Team ID (default: F44ZS9HT2P)
  CODESIGN_IDENTITY            codesign / electron-builder identity (default: F44ZS9HT2P)
  RELEASE_REPO                 GitHub repo (default: ZonD80/clawhome)
  RELEASE_GH_USER              gh account to switch to (default: ZonD80)

Artifact:
  release/<version>/ClawHome-Mac-<version>-arm64.dmg

--release / --release-only require GitHub CLI (`gh`) authenticated as RELEASE_GH_USER.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --notarize) NOTARIZE=1; shift ;;
    --no-notarize|--skip-notarize) NOTARIZE=0; shift ;;
    --release) DO_RELEASE=1; shift ;;
    --release-only) DO_RELEASE=1; RELEASE_ONLY=1; NOTARIZE=0; shift ;;
    --force) FORCE=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

load_env() {
  local file="$1"
  if [[ -f "$file" ]]; then
    echo "Loading env: $file"
    set -a
    # shellcheck disable=SC1090
    source "$file"
    set +a
  fi
}

load_env "$REPO_ROOT/.env"

APPLE_TEAM_ID="${APPLE_TEAM_ID:-$DEFAULT_TEAM_ID}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:-$DEFAULT_CODESIGN_IDENTITY}"
RELEASE_REPO="${RELEASE_REPO:-$DEFAULT_RELEASE_REPO}"
RELEASE_GH_USER="${RELEASE_GH_USER:-$DEFAULT_RELEASE_GH_USER}"
APP_PASSWORD="${APPLE_APP_SPECIFIC_PASSWORD:-${APP_PASSWORD:-}}"

require_arm64() {
  local arch
  arch="$(uname -m)"
  if [[ "$arch" != "arm64" ]]; then
    echo "error: this script builds for Apple Silicon only (current arch: $arch)" >&2
    exit 1
  fi
}

require_notarize_credentials() {
  local missing=0
  if [[ -z "${APPLE_ID:-}" ]]; then
    echo "error: APPLE_ID is not set in .env" >&2
    missing=1
  fi
  if [[ -z "${APP_PASSWORD:-}" ]]; then
    echo "error: APPLE_APP_SPECIFIC_PASSWORD is not set in .env" >&2
    missing=1
  fi
  if [[ "$missing" -ne 0 ]]; then
    exit 1
  fi
}

require_gh() {
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: GitHub CLI (gh) is required for --release" >&2
    exit 1
  fi
}

ensure_gh_account() {
  require_gh
  local active=""
  active="$(gh api user -q .login 2>/dev/null || true)"
  if [[ "$active" == "$RELEASE_GH_USER" ]]; then
    echo "    gh account: $RELEASE_GH_USER"
    return
  fi
  echo "==> Switching gh account to $RELEASE_GH_USER"
  if ! gh auth switch -u "$RELEASE_GH_USER" >/dev/null 2>&1; then
    echo "error: could not switch gh to '$RELEASE_GH_USER'." >&2
    echo "  Run: gh auth login -h github.com -p https -w" >&2
    echo "  Then: gh auth switch -u $RELEASE_GH_USER" >&2
    exit 1
  fi
  active="$(gh api user -q .login 2>/dev/null || true)"
  if [[ "$active" != "$RELEASE_GH_USER" ]]; then
    echo "error: active gh account is '${active:-unknown}', expected '$RELEASE_GH_USER'" >&2
    exit 1
  fi
  echo "    gh account: $RELEASE_GH_USER"
}

read_local_version() {
  node -p "require('./package.json').version"
}

dmg_name_for() {
  echo "ClawHome-Mac-${1}-arm64.dmg"
}

dmg_path_for() {
  local version="$1"
  echo "$REPO_ROOT/release/${version}/$(dmg_name_for "$version")"
}

# Prints -1 if a < b, 0 if equal, 1 if a > b.
version_cmp() {
  /usr/bin/python3 - "$1" "$2" <<'PY'
import sys

def parts(v):
    out = []
    for piece in v.replace("-", ".").replace("+", ".").lstrip("v").split("."):
        if piece.isdigit():
            out.append(int(piece))
        else:
            break
    return out

left, right = parts(sys.argv[1]), parts(sys.argv[2])
n = max(len(left), len(right))
left += [0] * (n - len(left))
right += [0] * (n - len(right))
print((left > right) - (left < right))
PY
}

fetch_published_version() {
  PUBLISHED=0
  PUB_VERSION=""
  local url="https://github.com/${RELEASE_REPO}/releases/latest"
  local loc=""
  loc="$(curl -sI -A "ClawHome-release.sh" "$url" | awk 'tolower($1)=="location:" { print $2 }' | tr -d '\r' | tail -1 || true)"
  if [[ -z "$loc" ]]; then
    echo "==> No published release on $RELEASE_REPO"
    return 0
  fi
  if [[ "$loc" =~ /tag/v?([0-9]+(\.[0-9]+)*) ]]; then
    PUB_VERSION="${BASH_REMATCH[1]}"
    PUBLISHED=1
    echo "==> GitHub latest: $PUB_VERSION"
    return 0
  fi
  echo "==> Could not read a version from $loc"
}

changelog_notes() {
  local version="$1"
  /usr/bin/python3 - "$version" <<'PY'
import sys
version = sys.argv[1]
try:
    lines = open("CHANGELOG.md", encoding="utf-8").read().splitlines()
except FileNotFoundError:
    print(f"ClawHome {version}")
    raise SystemExit
start = None
for i, line in enumerate(lines):
    if line.startswith(f"## [{version}]"):
        start = i + 1
        break
if start is None:
    print(f"ClawHome {version}")
    raise SystemExit
body = []
for line in lines[start:]:
    if line.startswith("## "):
        break
    body.append(line)
text = "\n".join(body).strip()
print(text or f"ClawHome {version}")
PY
}

build_app() {
  echo "==> Building ClawHome ${VERSION} for macOS arm64"
  echo "    identity: $CODESIGN_IDENTITY"
  npm install
  npm run electron:build
  ./scripts/build-claw-vm.sh
  for f in dist-electron/resources/ClawVMManager dist-electron/resources/ClawVMRunner dist-electron/resources/ClawVM; do
    if [[ ! -f "$f" ]]; then
      echo "error: missing $f" >&2
      exit 1
    fi
  done
  echo "==> Packaging DMG"
  CSC_NAME="$CODESIGN_IDENTITY" \
    npx electron-builder --mac --arm64 --config electron-builder.json5
  local app_resources="release/${VERSION}/mac-arm64/ClawHome.app/Contents/Resources"
  if [[ -d "$app_resources" ]]; then
    for f in ClawVMManager ClawVMRunner ClawVM; do
      if [[ ! -f "$app_resources/$f" ]]; then
        echo "error: $f not found in $app_resources" >&2
        exit 1
      fi
    done
  fi
  if [[ ! -f "$DMG_PATH" ]]; then
    echo "error: DMG not found at $DMG_PATH" >&2
    exit 1
  fi
  echo "    dmg: $DMG_PATH"
}

notarize_dmg() {
  echo "==> Submitting $(basename "$DMG_PATH") for notarization"
  xcrun notarytool submit "$DMG_PATH" \
    --apple-id "$APPLE_ID" \
    --password "$APP_PASSWORD" \
    --team-id "$APPLE_TEAM_ID" \
    --wait
  echo "==> Stapling notarization ticket"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
}

publish_github_release() {
  local tag="v${VERSION}"
  local notes
  notes="$(changelog_notes "$VERSION")"
  ensure_gh_account
  local yml="release/${VERSION}/latest-mac.yml"
  local assets=("$DMG_PATH")
  if [[ -f "$yml" ]]; then
    assets+=("$yml")
  fi
  if gh release view "$tag" --repo "$RELEASE_REPO" >/dev/null 2>&1; then
    if [[ "$FORCE" -eq 0 ]]; then
      echo "error: release $tag already exists on $RELEASE_REPO" >&2
      echo "  Bump package.json, or pass --force to replace this release." >&2
      exit 1
    fi
    echo "==> Replacing assets on $tag"
    gh release upload "$tag" "${assets[@]}" --repo "$RELEASE_REPO" --clobber
    gh release edit "$tag" --repo "$RELEASE_REPO" --notes "$notes" >/dev/null
  else
    echo "==> Creating GitHub release $tag on $RELEASE_REPO"
    gh release create "$tag" \
      --repo "$RELEASE_REPO" \
      --title "ClawHome ${VERSION}" \
      --notes "$notes" \
      "${assets[@]}"
  fi
  echo "    release: https://github.com/${RELEASE_REPO}/releases/tag/${tag}"
  echo "    dmg:     https://github.com/${RELEASE_REPO}/releases/download/${tag}/$(basename "$DMG_PATH")"
}

require_arm64

VERSION="$(read_local_version)"
DMG_PATH="$(dmg_path_for "$VERSION")"

if [[ "$RELEASE_ONLY" -eq 1 ]]; then
  echo "==> Release-only mode"
  if [[ ! -f "$DMG_PATH" ]]; then
    echo "error: missing $DMG_PATH (run ./release.sh first)" >&2
    exit 1
  fi
  echo "    version: $VERSION"
  echo "    dmg:     $DMG_PATH"
  publish_github_release
  echo
  echo "Done."
  echo "  Release: https://github.com/${RELEASE_REPO}/releases/tag/v${VERSION}"
  exit 0
fi

fetch_published_version
if [[ "$PUBLISHED" -eq 1 ]]; then
  cmp="$(version_cmp "$VERSION" "$PUB_VERSION")"
  if [[ "$cmp" -lt 0 ]]; then
    echo "error: local $VERSION is older than GitHub $PUB_VERSION" >&2
    exit 1
  fi
  if [[ "$cmp" -eq 0 && "$FORCE" -eq 0 ]]; then
    echo "==> GitHub already has $VERSION"
    echo "    pass --force to rebuild"
    exit 0
  fi
fi

if [[ "$NOTARIZE" -eq 1 ]]; then
  require_notarize_credentials
fi
if [[ "$DO_RELEASE" -eq 1 ]]; then
  ensure_gh_account
fi

build_app

if [[ "$NOTARIZE" -eq 1 ]]; then
  notarize_dmg
else
  echo "==> Skipping notarization (--no-notarize)"
fi

if [[ "$DO_RELEASE" -eq 1 ]]; then
  if [[ "$NOTARIZE" -ne 1 ]]; then
    echo "warning: publishing without notarization (--no-notarize)" >&2
  fi
  publish_github_release
fi

echo
echo "Done."
echo "  DMG: $DMG_PATH"
echo "  Ver: $VERSION"
if [[ "$NOTARIZE" -eq 1 ]]; then
  echo "  Notarization: stapled"
fi
if [[ "$DO_RELEASE" -eq 1 ]]; then
  echo "  Release: https://github.com/${RELEASE_REPO}/releases/tag/v${VERSION}"
fi
