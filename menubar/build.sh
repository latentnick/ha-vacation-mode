#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release

# Assemble and sign the bundle in a local (non-synced) temp dir. If the repo
# lives under iCloud/file-provider sync, that sync continuously stamps
# com.apple.FinderInfo onto directories, which makes `codesign` fail with
# "resource fork, Finder information, or similar detritus not allowed". Building
# in $TMPDIR (always local) sidesteps the race; we move the signed app back at
# the end.
WORK="$(mktemp -d "${TMPDIR:-/tmp}/lights-menubar.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/LightsMenubar.app"
RES="$APP/Contents/Resources"
mkdir -p "$APP/Contents/MacOS" "$RES"
cp ".build/release/LightsMenubar" "$APP/Contents/MacOS/LightsMenubar"
cp "Resources/Info.plist" "$APP/Contents/Info.plist"

# --- Bundle the virtual HomeKit switch daemon (Node.js + hap-nodejs) ---
# Vendor index.js plus a FLAT node_modules (npm, not pnpm — pnpm's symlink
# store would break when copied into the bundle). The dependency tree is pure
# JS, so node_modules is architecture-independent.
SWITCH_SRC="../switch"
SWITCH_DST="$RES/switch"
STAGE="$WORK/switch-stage"
mkdir -p "$STAGE"
cp "$SWITCH_SRC/index.js" "$SWITCH_SRC/package.json" "$STAGE/"
( cd "$STAGE" && npm install --omit=dev --no-audit --no-fund --silent )
mkdir -p "$SWITCH_DST"
cp "$STAGE/index.js" "$SWITCH_DST/index.js"
cp -R "$STAGE/node_modules" "$SWITCH_DST/node_modules"

# --- Bundle a pinned Node 22 LTS runtime (per build arch) ---
scripts/vendor-node.sh "$RES/node"

# Ad-hoc sign the nested Node binary BEFORE signing the app, so the bundle's
# signature covers a sealed inner executable (otherwise codesign of the app
# rejects the unsigned Mach-O resource).
codesign --force --sign - "$RES/node/bin/node"

# Ad-hoc sign with entitlements so the data-protection keychain
# (kSecUseDataProtectionKeychain) is accessible without per-launch
# user prompts. Without a stable signing identity + keychain-access-groups
# entitlement, the legacy keychain ACL re-prompts on every rebuild.
codesign --force --sign - "$APP"

# Move the finished, signed bundle into ./build. A FinderInfo xattr re-stamped
# on the .app root by sync after this point is harmless — it does not invalidate
# the seal over Contents/.
DEST="build/LightsMenubar.app"
mkdir -p build
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "Built $DEST"
