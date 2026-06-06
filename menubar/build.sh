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

# --- Code signing ---
# The Keychain item that holds our credentials carries a per-app ACL bound to
# the app's *designated requirement*. A Developer ID Application identity has a
# requirement (Apple anchor + team ID + leaf) that is byte-for-byte identical on
# every rebuild, so once you "Always Allow" the access it sticks. Ad-hoc signing
# (-) changes the requirement every build, which is what forced macOS to
# re-prompt — and, run unattended at 4 AM, that prompt fails and the schedule
# generation 401s.
#
# Auto-detect the Developer ID Application identity; override with SIGN_IDENTITY
# if you have more than one.
SIGN_IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning \
  | awk -F'"' '/Developer ID Application/ {print $2; exit}')}"

if [ -z "$SIGN_IDENTITY" ]; then
  echo "WARNING: no 'Developer ID Application' identity found in your keychain." >&2
  echo "         Falling back to ad-hoc signing, which re-prompts for Keychain" >&2
  echo "         access after every rebuild. To fix permanently, import your" >&2
  echo "         Developer ID cert *with its private key* (a .p12 exported from" >&2
  echo "         the machine that has it) into login.keychain, or set" >&2
  echo "         SIGN_IDENTITY=<identity name>." >&2
  SIGN_IDENTITY="-"
else
  echo "Signing with: $SIGN_IDENTITY"
fi

# Sign the nested Node binary BEFORE the app, so the bundle's signature covers a
# sealed inner executable (otherwise codesign of the app rejects the unsigned
# Mach-O resource). No hardened runtime: it would block V8's JIT in the bundled
# Node unless we also added allow-jit entitlements, and it isn't needed for ACL
# stability — a stable identity alone is what keeps the requirement constant.
codesign --force --sign "$SIGN_IDENTITY" "$RES/node/bin/node"
codesign --force --sign "$SIGN_IDENTITY" "$APP"

# Verify the seal here in $WORK, before the move below — $TMPDIR is local, so no
# file-provider sync has had a chance to stamp a com.apple.FinderInfo xattr onto
# the bundle root yet (that xattr trips --verify but doesn't affect the seal
# over Contents/, which is why we check now rather than after the ditto).
codesign --verify --deep --strict --verbose=2 "$APP"
if [ "$SIGN_IDENTITY" != "-" ]; then
  # A stable Developer ID requirement is the whole point of signing here, so
  # confirm the bundle actually satisfies one rather than ad-hoc.
  codesign --display --requirements - "$APP" 2>&1 | grep -q "anchor apple generic" \
    || { echo "ERROR: signed bundle lacks a stable designated requirement" >&2; exit 1; }
fi

# Move the finished, signed bundle into ./build. A FinderInfo xattr re-stamped
# on the .app root by sync after this point is harmless — it does not invalidate
# the seal over Contents/.
DEST="build/LightsMenubar.app"
mkdir -p build
rm -rf "$DEST"
ditto "$APP" "$DEST"

echo "Built $DEST"
